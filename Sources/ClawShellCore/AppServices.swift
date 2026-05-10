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

public final class AssertionManager: StubLifecycleComponent {
    public init() {
        super.init(componentName: "AssertionManager")
    }
}

public final class IntegrationManager: StubLifecycleComponent {
    public init() {
        super.init(componentName: "IntegrationManager")
    }
}

public final class ClawShellServices {
    public let agentMonitor: AgentMonitor
    public let assertionManager: AssertionManager
    public let integrationManager: IntegrationManager
    public let settingsStore: SettingsStore
    public let logStore: LogStore

    public init(
        agentMonitor: AgentMonitor? = nil,
        assertionManager: AssertionManager = AssertionManager(),
        integrationManager: IntegrationManager = IntegrationManager(),
        settingsStore: SettingsStore? = nil,
        logStore: LogStore? = nil,
        paths: ClawShellPaths = .defaultPaths()
    ) {
        self.assertionManager = assertionManager
        self.integrationManager = integrationManager
        let resolvedLogStore = logStore ?? LogStore(paths: paths)
        self.logStore = resolvedLogStore
        let resolvedSettingsStore = settingsStore ?? SettingsStore(paths: paths, logStore: resolvedLogStore)
        self.settingsStore = resolvedSettingsStore
        self.agentMonitor = agentMonitor ?? AgentMonitor(settingsProvider: { resolvedSettingsStore.settings })
    }

    public var lifecycleComponents: [any AppLifecycleComponent] {
        [
            logStore,
            settingsStore,
            agentMonitor,
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
