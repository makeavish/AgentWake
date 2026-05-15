import Foundation

public final class AgentMonitor: AppLifecycleComponent {
    public let componentName = "AgentMonitor"
    public var runState: ComponentRunState {
        queue.sync {
            storedRunState
        }
    }

    public let pollInterval: TimeInterval

    private let snapshotProvider: ProcessSnapshotProviding
    private let settingsProvider: () -> AgentWakeSettings
    private let stateMachine: AgentSessionStateMachine
    private let now: () -> Date
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var storedRunState: ComponentRunState = .stopped
    private var storedScheduledPollInterval: TimeInterval?

    public init(
        snapshotProvider: ProcessSnapshotProviding = LibprocProcessSnapshotProvider(),
        settingsProvider: @escaping () -> AgentWakeSettings = { AgentWakeSettings() },
        stateMachine: AgentSessionStateMachine? = nil,
        pollInterval: TimeInterval = 2,
        now: @escaping () -> Date = Date.init,
        queue: DispatchQueue = DispatchQueue(label: "wtf.vishal.agentwake.agent-monitor")
    ) {
        self.snapshotProvider = snapshotProvider
        self.settingsProvider = settingsProvider
        self.pollInterval = pollInterval
        self.now = now
        self.queue = queue
        self.stateMachine = stateMachine ?? AgentSessionStateMachine()
    }

    public var sessions: [AgentSession] {
        queue.sync {
            stateMachine.sessions
        }
    }

    public var visibleSessions: [AgentSession] {
        queue.sync {
            stateMachine.sessions.filter { $0.state != .finished }
        }
    }

    public var aggregateHoldState: AgentAggregateHoldState {
        queue.sync {
            stateMachine.aggregateHoldState(at: now())
        }
    }

    public var scheduledPollInterval: TimeInterval? {
        queue.sync {
            storedScheduledPollInterval
        }
    }

    public func start() {
        queue.sync {
            guard storedRunState == .stopped else {
                return
            }

            storedRunState = .started
            pollOnQueue()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            storedScheduledPollInterval = pollInterval
            timer.setEventHandler { [weak self] in
                self?.pollOnQueue()
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            storedScheduledPollInterval = nil
            storedRunState = .stopped
        }
    }

    public func poll() {
        queue.sync {
            pollOnQueue()
        }
    }

    public func pauseAll(until expiresAt: Date?) {
        queue.sync {
            stateMachine.pauseAll(until: expiresAt)
        }
    }

    public var protectableDetectedSessionCount: Int {
        queue.sync {
            stateMachine.sessions.filter { isProtectableDetectedSession($0) }.count
        }
    }

    @discardableResult
    public func protectDetectedSessions(at now: Date) -> Int {
        queue.sync {
            pollOnQueue()
            return stateMachine.protectDetectedProcessSessions(at: now)
        }
    }

    public func releaseHeldSessions(at now: Date) {
        queue.sync {
            let heldSessionIDs = stateMachine.sessions
                .filter { $0.contributesToHold(at: now) }
                .map(\.id)

            heldSessionIDs.forEach {
                stateMachine.applyTrustedEvent(.releaseNow, to: $0, at: now)
            }
        }
    }

    public func applyIntegrationEvent(_ event: HookAdapterEvent, at now: Date) {
        queue.sync {
            let settings = settingsProvider()
            stateMachine.graceInterval = TimeInterval(settings.defaultGraceSeconds)
            stateMachine.processDetectionHoldInterval = TimeInterval(settings.defaultGraceSeconds)
            stateMachine.applyManualOverrides(settings.manualOverrides, at: now)

            do {
                let snapshots = try snapshotProvider.snapshots()
                let detector = AgentProcessDetector(settings: settings)
                let observations = detector.observations(in: snapshots)
                stateMachine.applyIntegrationEvent(event, at: now, fallbackObservations: observations)
            } catch {
                stateMachine.applyIntegrationEvent(event, at: now)
            }
        }
    }

    private func pollOnQueue() {
        let timestamp = now()
        let settings = settingsProvider()
        stateMachine.graceInterval = TimeInterval(settings.defaultGraceSeconds)
        stateMachine.processDetectionHoldInterval = TimeInterval(settings.defaultGraceSeconds)
        stateMachine.applyManualOverrides(settings.manualOverrides, at: timestamp)

        do {
            let snapshots = try snapshotProvider.snapshots()
            let detector = AgentProcessDetector(settings: settings)
            let observations = detector.observations(in: snapshots)
            stateMachine.applyProcessObservations(observations, at: timestamp)
            stateMachine.refreshExpirations(at: timestamp)
        } catch {
            stateMachine.refreshExpirations(at: timestamp)
        }
    }

    public func sessionSummaryMessage() -> String {
        queue.sync {
            let activeSessions = stateMachine.sessions.filter { $0.state != .finished }
            guard !activeSessions.isEmpty else {
                return "Sessions: none seen"
            }

            let timestamp = now()
            let heldCount = activeSessions.filter { $0.contributesToHold(at: timestamp) }.count
            let detectedCount = activeSessions.count - heldCount
            if heldCount == activeSessions.count {
                return "Sessions: \(activeSessions.count) protecting"
            }

            if heldCount == 0 {
                return "Sessions: \(detectedCount) seen, none protecting"
            }

            var parts: [String] = []
            if heldCount > 0 {
                parts.append("\(heldCount) protecting")
            }
            if detectedCount > 0 {
                parts.append("\(detectedCount) seen")
            }

            return "Sessions: \(parts.joined(separator: ", "))"
        }
    }

    public func sessionListMessage() -> String {
        queue.sync {
            let activeSessions = stateMachine.sessions.filter { $0.state != .finished }
            guard !activeSessions.isEmpty else {
                return "No sessions seen"
            }

            return activeSessions
                .sorted { lhs, rhs in
                    if lhs.agent.displayName == rhs.agent.displayName {
                        return lhs.firstSeenAt < rhs.firstSeenAt
                    }

                    return lhs.agent.displayName < rhs.agent.displayName
                }
                .map { session in
                    var parts = [
                        "\(session.agent.displayName): \(sessionDisplayState(session, at: now()))",
                        "source=\(session.source.rawValue)"
                    ]
                    if let pid = session.key.pid {
                        parts.append("pid=\(pid)")
                    }
                    if let lastEvent = session.lastEvent {
                        parts.append("lastEvent=\(lastEvent.kind.rawValue)")
                    }
                    return parts.joined(separator: " ")
                }
                .joined(separator: "\n")
        }
    }

    private func sessionDisplayState(_ session: AgentSession, at now: Date) -> String {
        if isManuallyProtectedDetectedSession(session) {
            return "manually protecting"
        }

        if session.contributesToHold(at: now) {
            return sessionProtectingState(session)
        }

        if session.source == .processScan && session.state != .finished {
            return "seen"
        }

        return sessionProtectingState(session)
    }

    private func sessionProtectingState(_ session: AgentSession) -> String {
        switch session.state {
        case .active:
            return "protecting"
        case .standingBy:
            return "recently active"
        case .finished:
            return "finished"
        }
    }

    private func isProtectableDetectedSession(_ session: AgentSession) -> Bool {
        session.source == .processScan
            && session.state != .finished
            && !session.hasIntegratedEvidence
            && !session.holdWhileOpen
            && session.key.processRuntimeIdentity != nil
    }

    private func isManuallyProtectedDetectedSession(_ session: AgentSession) -> Bool {
        session.source == .processScan
            && session.holdWhileOpen
            && !session.hasIntegratedEvidence
            && session.state != .finished
    }
}

public final class AgentWakeServices {
    public let agentMonitor: AgentMonitor
    public let controlServer: ControlServerComponent
    public let assertionManager: AssertionManager
    public let integrationManager: IntegrationManager
    public let settingsStore: SettingsStore
    public let logStore: LogStore
    public let closedLidModeController: ClosedLidModeController

    public init(
        agentMonitor: AgentMonitor? = nil,
        controlServer: ControlServerComponent? = nil,
        assertionManager: AssertionManager? = nil,
        integrationManager: IntegrationManager? = nil,
        closedLidModeController: ClosedLidModeController? = nil,
        settingsStore: SettingsStore? = nil,
        logStore: LogStore? = nil,
        paths: AgentWakePaths = .defaultPaths(),
        autoInstallIntegrations: Bool = false
    ) {
        let resolvedLogStore = logStore ?? LogStore(paths: paths)
        self.logStore = resolvedLogStore
        let resolvedSettingsStore = settingsStore ?? SettingsStore(paths: paths, logStore: resolvedLogStore)
        self.settingsStore = resolvedSettingsStore
        let resolvedIntegrationManager = integrationManager ?? IntegrationManager(
            settingsStore: resolvedSettingsStore,
            logStore: resolvedLogStore,
            autoInstallOnStart: autoInstallIntegrations,
            installLocations: autoInstallIntegrations ? .defaultLocations() : nil
        )
        self.integrationManager = resolvedIntegrationManager
        let resolvedClosedLidModeController = closedLidModeController ?? ClosedLidModeController(paths: paths)
        self.closedLidModeController = resolvedClosedLidModeController
        let resolvedAgentMonitor = agentMonitor ?? AgentMonitor(settingsProvider: { resolvedSettingsStore.settings })
        self.agentMonitor = resolvedAgentMonitor
        let resolvedAssertionManager = assertionManager ?? AssertionManager(
            holdStateProvider: {
                resolvedAgentMonitor.aggregateHoldState
            }
        )
        self.assertionManager = resolvedAssertionManager
        self.controlServer = controlServer ?? ControlServerComponent(
            runtimeStore: ControlRuntimeStore(paths: paths),
            router: DefaultControlCommandRouter(statusProvider: {
                resolvedAgentMonitor.aggregateHoldState.shouldHold ? "AgentWake protecting" : "AgentWake running"
            }, listProvider: {
                resolvedAgentMonitor.sessionListMessage()
            }, pauseHandler: { duration, receivedAt in
                resolvedAgentMonitor.pauseAll(until: receivedAt.addingTimeInterval(duration))
                resolvedAssertionManager.reconcile()
            }, releaseNowHandler: { receivedAt in
                resolvedAgentMonitor.releaseHeldSessions(at: receivedAt)
                resolvedAssertionManager.reconcile()
            }, integrationsListProvider: {
                resolvedIntegrationManager.listMessage()
            }, integrationsStatusProvider: {
                resolvedIntegrationManager.statusMessage()
            }, integrationRemoveHandler: { agentID, receivedAt in
                try resolvedIntegrationManager.removeIntegration(agentID: agentID, at: receivedAt)
            }, integrationEnableAutoHandler: { agentID, _ in
                try resolvedIntegrationManager.enableAutoInstall(agentID: agentID)
            }, integrationEventHandler: { event, receivedAt in
                resolvedAgentMonitor.applyIntegrationEvent(event, at: receivedAt)
                resolvedAssertionManager.reconcile()
                return "Integration event accepted: \(event.agent.rawValue) \(event.event.rawValue)"
            }, helperStatusProvider: {
                "No production helper is installed. Use `agentwake closed-lid status` for local admin-approved Closed-Lid Mode."
            }, helperEnableBagModeHandler: { _ in
                "Production helper enable unavailable. Use `agentwake closed-lid enable` for local admin-approved Closed-Lid Mode."
            }, helperDisableBagModeHandler: { _ in
                "Production helper disable unavailable. Use `agentwake closed-lid disable` for local admin-approved Closed-Lid Mode."
            }, helperRepairHandler: { _ in
                "Production helper repair unavailable: no production helper is installed."
            }, helperUninstallHandler: { _ in
                "Production helper uninstall unavailable: no production helper is installed."
            }, closedLidStatusProvider: {
                resolvedClosedLidModeController.statusMessage()
            }, closedLidEnableHandler: { _ in
                try resolvedClosedLidModeController.enable()
            }, closedLidDisableHandler: { _ in
                try resolvedClosedLidModeController.disable()
            }, protectDetectedSessionsHandler: { receivedAt in
                let protectedCount = resolvedAgentMonitor.protectDetectedSessions(at: receivedAt)
                resolvedAssertionManager.reconcile()
                if protectedCount == 0 {
                    return "No detected sessions to protect"
                }
                return "Protecting \(protectedCount) detected session\(protectedCount == 1 ? "" : "s") until the process exits"
            }, uninstallHandler: { removeHelper, removeIntegrations, receivedAt in
                var outcomes = ["Uninstall requested"]
                if removeIntegrations {
                    try resolvedIntegrationManager.removeAllIntegrations(at: receivedAt)
                    outcomes.append("integrations removed")
                } else {
                    outcomes.append("integrations unchanged")
                }

                if removeHelper {
                    outcomes.append("helper removal unavailable: no production helper is installed")
                } else {
                    outcomes.append("helper unchanged")
                }

                return outcomes.joined(separator: "; ")
            })
        )
    }

    public var lifecycleComponents: [any AppLifecycleComponent] {
        [
            logStore,
            settingsStore,
            agentMonitor,
            controlServer,
            assertionManager,
            integrationManager
        ]
    }

    public func startAll() {
        lifecycleComponents.forEach { $0.start() }
        logStore.append(kind: .appStarted, message: "AgentWake started")
    }

    public func stopAll() {
        logStore.append(kind: .appStopped, message: "AgentWake stopped")
        lifecycleComponents.reversed().forEach { $0.stop() }
    }
}
