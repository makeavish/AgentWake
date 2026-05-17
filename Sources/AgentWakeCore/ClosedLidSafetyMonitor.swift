import Foundation

public final class ClosedLidSafetyMonitor: AppLifecycleComponent {
    public let componentName = "ClosedLidSafetyMonitor"
    public var runState: ComponentRunState {
        queue.sync {
            storedRunState
        }
    }

    private let settingsProvider: () -> AgentWakeSettings
    private let closedLidModeController: ClosedLidModeController
    private let agentMonitor: AgentMonitor
    private let assertionManager: AssertionManager
    private let logStore: LogStore
    private let batteryPercentProvider: () -> Int?
    private let thermalPressureProvider: () -> BagModeAppThermalPressure?
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var storedRunState: ComponentRunState = .stopped
    private var safetyState = BagModeSafetyState()
    private var lastLoggedCutoffReason: BagModeSafetyCutoffReason?

    public init(
        settingsProvider: @escaping () -> AgentWakeSettings,
        closedLidModeController: ClosedLidModeController,
        agentMonitor: AgentMonitor,
        assertionManager: AssertionManager,
        logStore: LogStore,
        batteryPercentProvider: @escaping () -> Int? = PowerSourceReader.currentBatteryPercent,
        thermalPressureProvider: @escaping () -> BagModeAppThermalPressure? = ClosedLidSafetyMonitor.currentThermalPressure,
        now: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 15,
        queue: DispatchQueue = DispatchQueue(label: "wtf.vishal.agentwake.closed-lid-safety-monitor")
    ) {
        self.settingsProvider = settingsProvider
        self.closedLidModeController = closedLidModeController
        self.agentMonitor = agentMonitor
        self.assertionManager = assertionManager
        self.logStore = logStore
        self.batteryPercentProvider = batteryPercentProvider
        self.thermalPressureProvider = thermalPressureProvider
        self.now = now
        self.pollInterval = pollInterval
        self.queue = queue
    }

    public func start() {
        queue.sync {
            guard storedRunState == .stopped else {
                return
            }

            storedRunState = .started
            evaluateOnQueue()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in
                self?.evaluateOnQueue()
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            storedRunState = .stopped
        }
    }

    public func evaluateNow() {
        queue.sync {
            evaluateOnQueue()
        }
    }

    private func evaluateOnQueue() {
        let timestamp = now()
        let isArmed = closedLidModeController.isAgentWakeOwnedEnabled()
        let policy = BagModeSafetyPolicy(settings: settingsProvider().safety)
        let decision = policy.evaluate(
            previous: safetyState,
            input: BagModeSafetyInput(
                temperature: .sample(BagModeTemperatureSample(celsius: 0, capturedAt: timestamp)),
                appThermalPressure: thermalPressureProvider(),
                batteryPercent: batteryPercentProvider(),
                now: timestamp
            ),
            isBagModeArmed: isArmed
        )
        safetyState = decision.state

        let shouldSuppressProtection = decision.state.mode == .cutoffLockedOut
            && (isArmed || lastLoggedCutoffReason != nil)
        agentMonitor.setSafetyCutoffActive(shouldSuppressProtection)
        assertionManager.reconcile()

        guard decision.shouldReleaseIfArmed, isArmed else {
            return
        }

        do {
            let status = try closedLidModeController.disable()
            logCutoffIfNeeded(reason: decision.state.cutoffReason, status: status)
        } catch {
            logCutoffIfNeeded(reason: decision.state.cutoffReason, status: error.localizedDescription)
        }
    }

    private func logCutoffIfNeeded(reason: BagModeSafetyCutoffReason?, status: String) {
        guard lastLoggedCutoffReason != reason else {
            return
        }

        lastLoggedCutoffReason = reason
        logStore.append(
            kind: .safetyCutoff,
            metadata: [
                "cutoff": reason?.rawValue ?? "unknown",
                "status": status
            ]
        )
    }

    public static func currentThermalPressure() -> BagModeAppThermalPressure? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return nil
        }
    }
}
