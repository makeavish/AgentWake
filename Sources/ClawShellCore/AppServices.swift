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
    private let settingsProvider: () -> ClawShellSettings
    private let stateMachine: AgentSessionStateMachine
    private let now: () -> Date
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var storedRunState: ComponentRunState = .stopped
    private var storedScheduledPollInterval: TimeInterval?

    public init(
        snapshotProvider: ProcessSnapshotProviding = LibprocProcessSnapshotProvider(),
        settingsProvider: @escaping () -> ClawShellSettings = { ClawShellSettings() },
        stateMachine: AgentSessionStateMachine? = nil,
        pollInterval: TimeInterval = 2,
        now: @escaping () -> Date = Date.init,
        queue: DispatchQueue = DispatchQueue(label: "wtf.vishal.clawshell.agent-monitor")
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
            do {
                let snapshots = try snapshotProvider.snapshots()
                let settings = settingsProvider()
                stateMachine.graceInterval = TimeInterval(settings.defaultGraceSeconds)
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

        do {
            let snapshots = try snapshotProvider.snapshots()
            let settings = settingsProvider()
            stateMachine.graceInterval = TimeInterval(settings.defaultGraceSeconds)
            let detector = AgentProcessDetector(settings: settings)
            let observations = detector.observations(in: snapshots)
            stateMachine.applyProcessObservations(observations, at: timestamp)
            stateMachine.refreshExpirations(at: timestamp)
        } catch {
            stateMachine.refreshExpirations(at: timestamp)
        }
    }
}

public final class ClawShellServices {
    public let agentMonitor: AgentMonitor
    public let controlServer: ControlServerComponent
    public let assertionManager: AssertionManager
    public let integrationManager: IntegrationManager
    public let settingsStore: SettingsStore
    public let logStore: LogStore

    public init(
        agentMonitor: AgentMonitor? = nil,
        controlServer: ControlServerComponent? = nil,
        assertionManager: AssertionManager? = nil,
        integrationManager: IntegrationManager? = nil,
        settingsStore: SettingsStore? = nil,
        logStore: LogStore? = nil,
        paths: ClawShellPaths = .defaultPaths(),
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
                resolvedAgentMonitor.aggregateHoldState.shouldHold ? "ClawShell holding" : "ClawShell running"
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
                "Helper status unavailable: no helper is installed"
            }, helperRepairHandler: { _ in
                "Helper repair unavailable: no helper is installed"
            }, uninstallHandler: { removeHelper, removeIntegrations, receivedAt in
                var outcomes = ["Uninstall requested"]
                if removeIntegrations {
                    try resolvedIntegrationManager.removeAllIntegrations(at: receivedAt)
                    outcomes.append("integrations removed")
                } else {
                    outcomes.append("integrations unchanged")
                }

                if removeHelper {
                    outcomes.append("helper removal unavailable: no helper is installed")
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
        logStore.append(kind: .appStarted, message: "ClawShell started")
    }

    public func stopAll() {
        logStore.append(kind: .appStopped, message: "ClawShell stopped")
        lifecycleComponents.reversed().forEach { $0.stop() }
    }
}
