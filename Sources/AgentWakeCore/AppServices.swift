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
    private var storedLastPollAt: Date?

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

    public var lastPollAt: Date? {
        queue.sync {
            storedLastPollAt
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

    public func setSafetyCutoffActive(_ isActive: Bool) {
        queue.sync {
            stateMachine.setSafetyCutoffActive(isActive)
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
            guard settings.agents.contains(where: { $0.id == event.agent.rawValue && $0.isEnabled }) else {
                return
            }

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
        storedLastPollAt = timestamp
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
                return "No sessions running"
            }

            let timestamp = now()
            let heldCount = activeSessions.filter { $0.contributesToHold(at: timestamp) }.count
            let detectedCount = activeSessions.count - heldCount
            if heldCount == activeSessions.count {
                return "\(countLabel(activeSessions.count, singular: "session", plural: "sessions")) kept awake"
            }

            if heldCount == 0 {
                return "\(countLabel(detectedCount, singular: "session", plural: "sessions")) detected"
            }

            return "\(countLabel(heldCount, singular: "session", plural: "sessions")) kept awake; \(countLabel(detectedCount, singular: "detected", plural: "detected"))"
        }
    }

    public func sessionListMessage() -> String {
        queue.sync {
            let activeSessions = stateMachine.sessions.filter { $0.state != .finished }
            guard !activeSessions.isEmpty else {
                return "No sessions"
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

    public func sessionOverviewMessage() -> String {
        queue.sync {
            let activeSessions = stateMachine.sessions.filter { $0.state != .finished }
            guard !activeSessions.isEmpty else {
                return "No sessions"
            }

            let timestamp = now()
            let grouped = Dictionary(grouping: activeSessions, by: \.agent)

            return grouped.keys.sorted { $0.displayName < $1.displayName }.compactMap { agent in
                guard let sessions = grouped[agent] else {
                    return nil
                }

                let states = Dictionary(grouping: sessions) { session in
                    sessionDisplayState(session, at: timestamp)
                }

                let labels = ["keeping awake", "releasing soon", "detected"].compactMap { state -> String? in
                    guard let count = states[state]?.count, count > 0 else {
                        return nil
                    }

                    return count == 1 ? state : "\(count) \(state)"
                }

                guard !labels.isEmpty else {
                    return nil
                }

                return "\(agent.displayName): \(labels.joined(separator: ", "))"
            }
            .joined(separator: "\n")
        }
    }

    public func sessionDetailMessage() -> String {
        queue.sync {
            let activeSessions = stateMachine.sessions.filter { $0.state != .finished }
            guard !activeSessions.isEmpty else {
                return "No sessions"
            }

            let timestamp = now()
            let grouped = Dictionary(grouping: activeSessions, by: \.agent)
            return grouped.keys.sorted { $0.displayName < $1.displayName }.compactMap { agent in
                guard let sessions = grouped[agent] else {
                    return nil
                }

                let header = "\(agent.displayName) (\(sessions.count))"
                let rows = sessions.sorted { $0.firstSeenAt < $1.firstSeenAt }.map { session in
                    let pid = session.key.pid.map(String.init) ?? "-"
                    let source = session.source.rawValue
                    let event = session.lastEvent.map { "\(relativeTime(from: $0.occurredAt, to: timestamp)) ago (\($0.kind.rawValue))" } ?? "-"
                    let heldSince = session.contributesToHold(at: timestamp) ? "\(relativeTime(from: session.firstSeenAt, to: timestamp)) ago" : "-"
                    return "  \(pid)  \(source)  \(event)  held \(heldSince)"
                }
                return ([header] + rows).joined(separator: "\n")
            }
            .joined(separator: "\n")
        }
    }

    private func sessionDisplayState(_ session: AgentSession, at now: Date) -> String {
        if isManuallyProtectedDetectedSession(session) {
            return "keeping awake"
        }

        if session.contributesToHold(at: now) {
            return sessionProtectingState(session)
        }

        if session.source == .processScan && session.state != .finished {
            return "detected"
        }

        return sessionProtectingState(session)
    }

    private func sessionProtectingState(_ session: AgentSession) -> String {
        switch session.state {
        case .active:
            return "keeping awake"
        case .standingBy:
            return "releasing soon"
        case .finished:
            return "finished"
        }
    }

    private func countLabel(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        return "\(hours / 24)d"
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

public enum ClosedLidModeSafetyError: Error, Equatable, LocalizedError {
    case blocked(BagModeSafetyDiagnostic)
    case noActiveProtection

    public var errorDescription: String? {
        switch self {
        case .blocked(let diagnostic):
            return [
                diagnostic.title,
                diagnostic.detail,
                diagnostic.recoveryAction
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case .noActiveProtection:
            return "Lid-Closed Awake needs active sleep protection. Start or protect an agent session, or use Keep Mac Active, before turning it on."
        }
    }
}

public final class AgentWakeServices: @unchecked Sendable {
    public let agentMonitor: AgentMonitor
    public let controlServer: ControlServerComponent
    public let assertionManager: AssertionManager
    public let integrationManager: IntegrationManager
    public let settingsStore: SettingsStore
    public let logStore: LogStore
    public let closedLidModeController: ClosedLidModeController
    public let closedLidSafetyMonitor: ClosedLidSafetyMonitor
    public let privilegedHelperManager: any AgentWakePrivilegedHelperManaging
    private let temperatureReadingProvider: (Date) -> BagModeTemperatureReading
    private let batteryPercentProvider: () -> Int?
    private let thermalPressureProvider: () -> BagModeAppThermalPressure?
    private let shouldAutoRepairClosedLidHelper: Bool

    public init(
        agentMonitor: AgentMonitor? = nil,
        controlServer: ControlServerComponent? = nil,
        assertionManager: AssertionManager? = nil,
        integrationManager: IntegrationManager? = nil,
        closedLidModeController: ClosedLidModeController? = nil,
        closedLidModeCommandRunner: ClosedLidModeCommandRunning? = nil,
        privilegedHelperManager: (any AgentWakePrivilegedHelperManaging)? = nil,
        settingsStore: SettingsStore? = nil,
        logStore: LogStore? = nil,
        temperatureReadingProvider: @escaping (Date) -> BagModeTemperatureReading = { timestamp in
            DirectTemperatureProvider().currentReading(capturedAt: timestamp)
        },
        batteryPercentProvider: @escaping () -> Int? = PowerSourceReader.currentBatteryPercent,
        thermalPressureProvider: @escaping () -> BagModeAppThermalPressure? = ClosedLidSafetyMonitor.currentThermalPressure,
        paths: AgentWakePaths = .defaultPaths(),
        autoInstallIntegrations: Bool = false
    ) {
        self.temperatureReadingProvider = temperatureReadingProvider
        self.batteryPercentProvider = batteryPercentProvider
        self.thermalPressureProvider = thermalPressureProvider
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
        let helperClient = AgentWakePrivilegedHelperClient(paths: paths)
        let helperManager = privilegedHelperManager ?? AgentWakePrivilegedHelperManager(client: helperClient)
        self.privilegedHelperManager = helperManager
        let shouldAutoRegisterHelper = closedLidModeController == nil
        self.shouldAutoRepairClosedLidHelper = shouldAutoRegisterHelper
        let resolvedClosedLidModeController = closedLidModeController ?? ClosedLidModeController(
            paths: paths,
            commandRunner: closedLidModeCommandRunner ?? HelperBackedClosedLidModeCommandRunner(helperClient: helperClient)
        )
        self.closedLidModeController = resolvedClosedLidModeController
        let resolvedAgentMonitor = agentMonitor ?? AgentMonitor(settingsProvider: { resolvedSettingsStore.settings })
        self.agentMonitor = resolvedAgentMonitor
        let resolvedAssertionManager = assertionManager ?? AssertionManager(
            holdStateProvider: {
                resolvedAgentMonitor.aggregateHoldState
            }
        )
        self.assertionManager = resolvedAssertionManager
        let resolvedClosedLidSafetyMonitor = ClosedLidSafetyMonitor(
            settingsProvider: { resolvedSettingsStore.settings },
            closedLidModeController: resolvedClosedLidModeController,
            agentMonitor: resolvedAgentMonitor,
            assertionManager: resolvedAssertionManager,
            logStore: resolvedLogStore,
            temperatureReadingProvider: temperatureReadingProvider,
            batteryPercentProvider: batteryPercentProvider,
            thermalPressureProvider: thermalPressureProvider
        )
        self.closedLidSafetyMonitor = resolvedClosedLidSafetyMonitor
        let closedLidEnableWithSafetyCheck: (Date) throws -> String = { receivedAt in
            try Self.validateHasActiveSleepProtection(resolvedAgentMonitor.aggregateHoldState)
            try Self.validateCanArmClosedLidMode(
                settings: resolvedSettingsStore.settings.safety,
                temperature: temperatureReadingProvider(receivedAt),
                batteryPercent: batteryPercentProvider(),
                thermalPressure: thermalPressureProvider(),
                at: receivedAt
            )
            if shouldAutoRegisterHelper {
                let helperStatus = try helperManager.repair()
                try Self.validateClosedLidHelperReady(helperStatus)
            }
            let message = try resolvedClosedLidModeController.enable()
            resolvedClosedLidSafetyMonitor.evaluateNow()
            return message
        }
        self.controlServer = controlServer ?? ControlServerComponent(
            runtimeStore: ControlRuntimeStore(paths: paths),
            router: DefaultControlCommandRouter(statusProvider: {
                resolvedAgentMonitor.aggregateHoldState.shouldHold ? "AgentWake keeping Mac awake" : "AgentWake running"
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
                helperManager.statusMessage()
            }, helperEnableBagModeHandler: { receivedAt in
                try closedLidEnableWithSafetyCheck(receivedAt)
            }, helperDisableBagModeHandler: { _ in
                try resolvedClosedLidModeController.disable()
            }, helperRepairHandler: { _ in
                try helperManager.repair()
            }, helperUninstallHandler: { _ in
                if resolvedClosedLidModeController.isAgentWakeOwnedEnabled() {
                    _ = try resolvedClosedLidModeController.disable()
                }
                return try helperManager.unregister()
            }, closedLidStatusProvider: {
                resolvedClosedLidModeController.statusMessage()
            }, closedLidEnableHandler: { receivedAt in
                try closedLidEnableWithSafetyCheck(receivedAt)
            }, closedLidDisableHandler: { _ in
                try resolvedClosedLidModeController.disable()
            }, protectDetectedSessionsHandler: { receivedAt in
                let protectedCount = resolvedAgentMonitor.protectDetectedSessions(at: receivedAt)
                resolvedAssertionManager.reconcile()
                if protectedCount == 0 {
                    return "No detected sessions to protect"
                }
                return "Keeping \(protectedCount) detected session\(protectedCount == 1 ? "" : "s") awake until the process exits"
            }, uninstallHandler: { removeHelper, removeIntegrations, removeSettings, receivedAt in
                var outcomes = ["Uninstall requested"]
                if removeIntegrations {
                    try resolvedIntegrationManager.removeAllIntegrations(at: receivedAt)
                    outcomes.append("integrations removed")
                } else {
                    outcomes.append("integrations unchanged")
                }

                if removeHelper {
                    if resolvedClosedLidModeController.isAgentWakeOwnedEnabled() {
                        _ = try resolvedClosedLidModeController.disable()
                    }
                    outcomes.append(try helperManager.unregister())
                } else {
                    outcomes.append("helper unchanged")
                }

                if removeSettings {
                    try resolvedSettingsStore.removeSavedSettingsForFreshInstall()
                    outcomes.append("saved settings removed")
                } else {
                    outcomes.append("saved settings kept")
                }

                return outcomes.joined(separator: "; ")
            }, doctorProvider: {
                AgentWakeServices.diagnosticInfo(
                    agentMonitor: resolvedAgentMonitor,
                    integrationManager: resolvedIntegrationManager,
                    closedLidModeController: resolvedClosedLidModeController,
                    logStore: resolvedLogStore
                )
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
            closedLidSafetyMonitor,
            integrationManager
        ]
    }

    public func startAll() {
        lifecycleComponents.forEach { $0.start() }
        logStore.append(kind: .appStarted, message: "AgentWake started")
    }

    public func stopAll() {
        logStore.append(kind: .appStopped, message: "AgentWake stopped")
        if closedLidModeController.isAgentWakeOwnedEnabled() {
            do {
                let message = try closedLidModeController.disable()
                logStore.append(
                    kind: .helperChange,
                    message: "Closed-Lid Mode restored during shutdown",
                    metadata: [
                        "operation": "shutdown-restore",
                        "result": message
                    ]
                )
            } catch {
                logStore.append(
                    kind: .helperChange,
                    message: "Closed-Lid Mode shutdown restore failed",
                    metadata: [
                        "operation": "shutdown-restore",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
        lifecycleComponents.reversed().forEach { $0.stop() }
    }

    public func enableClosedLidMode(at timestamp: Date = Date()) throws -> String {
        try Self.validateHasActiveSleepProtection(agentMonitor.aggregateHoldState)
        try Self.validateCanArmClosedLidMode(
            settings: settingsStore.settings.safety,
            temperature: temperatureReadingProvider(timestamp),
            batteryPercent: batteryPercentProvider(),
            thermalPressure: thermalPressureProvider(),
            at: timestamp
        )
        try repairClosedLidHelperIfNeeded()
        let message = try closedLidModeController.enable()
        closedLidSafetyMonitor.evaluateNow()
        return message
    }

    public func diagnosticInfo() -> String {
        Self.diagnosticInfo(
            agentMonitor: agentMonitor,
            integrationManager: integrationManager,
            closedLidModeController: closedLidModeController,
            logStore: logStore
        )
    }

    private static func diagnosticInfo(
        agentMonitor: AgentMonitor,
        integrationManager: IntegrationManager,
        closedLidModeController: ClosedLidModeController,
        logStore: LogStore
    ) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        let integrations = integrationManager.snapshots()
            .map { "\($0.displayName): \($0.status.displayTitle)" }
            .joined(separator: "\n")
        let events = logStore.events.suffix(50).map { event in
            let metadata = event.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return "\(event.timestamp) \(event.kind.rawValue) \(metadata)"
        }
        .joined(separator: "\n")

        return """
        AgentWake Diagnostic Info
        Version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        Status:
        \(agentMonitor.sessionSummaryMessage())

        Sessions:
        \(agentMonitor.sessionListMessage())

        Lid-Closed Awake:
        \(closedLidModeController.statusMessage())

        Direct temperature:
        \(directTemperatureStatusMessage())

        Integrations:
        \(integrations.isEmpty ? "No integration status" : integrations)

        pmset:
        \(runDiagnosticProcess("/usr/bin/pmset", arguments: ["-g"]))

        Last audit events:
        \(events.isEmpty ? "No audit events" : events)
        """
    }

    private static func runDiagnosticProcess(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.isEmpty ? error : output
    }

    private static func validateHasActiveSleepProtection(_ holdState: AgentAggregateHoldState) throws {
        guard holdState.shouldHold else {
            throw ClosedLidModeSafetyError.noActiveProtection
        }
    }

    private func repairClosedLidHelperIfNeeded() throws {
        guard shouldAutoRepairClosedLidHelper else {
            return
        }

        let helperStatus = try privilegedHelperManager.repair()
        try Self.validateClosedLidHelperReady(helperStatus)
    }

    private static func validateClosedLidHelperReady(_ helperStatus: String) throws {
        let normalized = helperStatus.localizedLowercase
        guard !normalized.contains("requires approval"),
              !normalized.contains("approval required") else {
            throw ClosedLidModeError.authorizationFailed(helperStatus)
        }
    }

    private static func validateCanArmClosedLidMode(
        settings: SafetySettings,
        temperature: BagModeTemperatureReading,
        batteryPercent: Int?,
        thermalPressure: BagModeAppThermalPressure?,
        at timestamp: Date
    ) throws {
        let decision = BagModeSafetyPolicy(settings: settings).evaluate(
            input: BagModeSafetyInput(
                temperature: temperature,
                appThermalPressure: thermalPressure,
                batteryPercent: batteryPercent,
                now: timestamp
            ),
            isBagModeArmed: false
        )

        guard decision.canArmBagMode else {
            let diagnostic = BagModeSafetyDiagnostic.userFacing(for: decision) ?? BagModeSafetyDiagnostic(
                title: "Closed-Lid Mode unavailable",
                detail: "AgentWake could not confirm that Closed-Lid Mode is safe to use right now.",
                recoveryAction: "Try again after the safety state refreshes."
            )
            throw ClosedLidModeSafetyError.blocked(diagnostic)
        }
    }

    private static func directTemperatureStatusMessage() -> String {
        let status = DirectTemperatureProvider().currentStatus()
        let sampleDetail = "source=\(status.source) samples=\(status.sampleCount) scaleVerified=\(status.scaleVerifiedCount)/\(status.sampleCount)"
        switch status.reading {
        case .sample(let sample):
            let signal = sample.coversClosedBagRisk ? "temperatureSignal=usable" : "temperatureSignal=sample-only"
            return "\(Int(sample.celsius.rounded())) C \(sampleDetail) \(signal)"
        case .unavailable:
            return "temperature provider unavailable \(sampleDetail) apiFailures=\(status.apiFailureCount)"
        case .permissionDenied:
            return "temperature provider permission denied \(sampleDetail)"
        case .parseFailed:
            return "temperature provider parse failed \(sampleDetail) invalidSamples=\(status.invalidSampleCount)"
        case .helperCrashed:
            return "temperature helper crashed \(sampleDetail)"
        case .unsupportedHardware:
            return "temperature provider unsupported on this Mac \(sampleDetail)"
        case .timedOut:
            return "temperature provider timed out \(sampleDetail)"
        }
    }
}
