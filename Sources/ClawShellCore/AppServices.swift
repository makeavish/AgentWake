import Foundation

public final class AgentMonitor: StubLifecycleComponent {
    public init() {
        super.init(componentName: "AgentMonitor")
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
        agentMonitor: AgentMonitor = AgentMonitor(),
        assertionManager: AssertionManager = AssertionManager(),
        integrationManager: IntegrationManager = IntegrationManager(),
        settingsStore: SettingsStore? = nil,
        logStore: LogStore? = nil,
        paths: ClawShellPaths = .defaultPaths()
    ) {
        self.agentMonitor = agentMonitor
        self.assertionManager = assertionManager
        self.integrationManager = integrationManager
        let resolvedLogStore = logStore ?? LogStore(paths: paths)
        self.logStore = resolvedLogStore
        self.settingsStore = settingsStore ?? SettingsStore(paths: paths, logStore: resolvedLogStore)
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
