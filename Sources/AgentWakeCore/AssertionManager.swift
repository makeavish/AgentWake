import Foundation

public struct HeldPowerAssertion: Equatable, Sendable {
    public var type: PowerAssertionType
    public var id: PowerAssertionID

    public init(type: PowerAssertionType, id: PowerAssertionID) {
        self.type = type
        self.id = id
    }
}

public struct AssertionManagerSnapshot: Equatable, Sendable {
    public var runState: ComponentRunState
    public var desiredShouldHold: Bool
    public var heldAssertions: [HeldPowerAssertion]
    public var lastErrorDescription: String?

    public init(
        runState: ComponentRunState,
        desiredShouldHold: Bool,
        heldAssertions: [HeldPowerAssertion],
        lastErrorDescription: String? = nil
    ) {
        self.runState = runState
        self.desiredShouldHold = desiredShouldHold
        self.heldAssertions = heldAssertions
        self.lastErrorDescription = lastErrorDescription
    }

    public var isHolding: Bool {
        !heldAssertions.isEmpty
    }
}

public final class AssertionManager: @unchecked Sendable, AppLifecycleComponent {
    public let componentName = "AssertionManager"
    public let reconcileInterval: TimeInterval

    public var runState: ComponentRunState {
        queue.sync {
            storedRunState
        }
    }

    public var snapshot: AssertionManagerSnapshot {
        queue.sync {
            snapshotOnQueue()
        }
    }

    private let controller: PowerAssertionControlling
    private let policy: NormalPowerAssertionPolicy
    private let holdStateProvider: () -> AgentAggregateHoldState
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var storedRunState: ComponentRunState = .stopped
    private var stopRequested = false
    private var storedDesiredShouldHold = false
    private var activeAssertions: [PowerAssertionType: PowerAssertionID] = [:]
    private var storedLastErrorDescription: String?

    public init(
        controller: PowerAssertionControlling = IOPMPowerAssertionController(),
        policy: NormalPowerAssertionPolicy = .validatedDefault,
        holdStateProvider: @escaping () -> AgentAggregateHoldState = {
            AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
        },
        reconcileInterval: TimeInterval = 5,
        queue: DispatchQueue = DispatchQueue(label: "wtf.vishal.agentwake.assertion-manager")
    ) {
        self.controller = controller
        self.policy = policy
        self.holdStateProvider = holdStateProvider
        self.reconcileInterval = reconcileInterval
        self.queue = queue
    }

    public func start() {
        queue.sync {
            if storedRunState == .started, stopRequested {
                stopRequested = false
                storedDesiredShouldHold = holdStateProvider().shouldHold
                ensureTimerOnQueue()
                reconcileOnQueue()
                return
            }

            guard storedRunState == .stopped else {
                return
            }

            storedRunState = .started
            stopRequested = false
            reconcileOnQueue()
            ensureTimerOnQueue()
        }
    }

    public func stop() {
        queue.sync {
            stopRequested = true
            storedDesiredShouldHold = false
            let releaseErrors = releaseAssertionsOnQueue()
            storeErrorMessages(releaseErrors)

            if activeAssertions.isEmpty {
                completeStopOnQueue()
            } else {
                ensureTimerOnQueue()
            }
        }
    }

    public func reconcile() {
        queue.sync {
            guard storedRunState == .started else {
                let releaseErrors = releaseAssertionsOnQueue()
                storeErrorMessages(releaseErrors)
                return
            }

            if stopRequested {
                let releaseErrors = releaseAssertionsOnQueue()
                storeErrorMessages(releaseErrors)

                if activeAssertions.isEmpty {
                    completeStopOnQueue()
                }
                return
            }

            reconcileOnQueue()
        }
    }

    private func reconcileOnQueue() {
        let holdState = holdStateProvider()
        storedDesiredShouldHold = holdState.shouldHold

        if holdState.shouldHold {
            let desiredTypes = Set(policy.assertionTypes)
            let releaseErrors = releaseAssertionsOnQueue { !desiredTypes.contains($0) }
            let createErrors = acquireMissingAssertionsOnQueue(desiredTypes: policy.assertionTypes)
            storeErrorMessages(releaseErrors + createErrors)
        } else {
            let releaseErrors = releaseAssertionsOnQueue()
            storeErrorMessages(releaseErrors)
        }
    }

    private func acquireMissingAssertionsOnQueue(desiredTypes: [PowerAssertionType]) -> [String] {
        var errorMessages: [String] = []

        for type in desiredTypes where activeAssertions[type] == nil {
            do {
                activeAssertions[type] = try controller.createAssertion(type: type, reason: policy.reason)
            } catch {
                errorMessages.append(error.localizedDescription)
            }
        }

        return errorMessages
    }

    private func releaseAssertionsOnQueue(
        where shouldRelease: (PowerAssertionType) -> Bool = { _ in true }
    ) -> [String] {
        guard !activeAssertions.isEmpty else {
            return []
        }

        let assertionsToRelease = activeAssertions.filter { shouldRelease($0.key) }
        var errorMessages: [String] = []

        for (type, assertionID) in assertionsToRelease {
            do {
                try controller.releaseAssertion(assertionID)
                activeAssertions.removeValue(forKey: type)
            } catch {
                errorMessages.append(error.localizedDescription)
            }
        }

        return errorMessages
    }

    private func ensureTimerOnQueue() {
        guard timer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + reconcileInterval, repeating: reconcileInterval)
        timer.setEventHandler { [weak self] in
            self?.timerFiredOnQueue()
        }
        timer.resume()
        self.timer = timer
    }

    private func timerFiredOnQueue() {
        if stopRequested {
            let releaseErrors = releaseAssertionsOnQueue()
            storeErrorMessages(releaseErrors)

            if activeAssertions.isEmpty {
                completeStopOnQueue()
            }
            return
        }

        reconcileOnQueue()
    }

    private func completeStopOnQueue() {
        timer?.cancel()
        timer = nil
        stopRequested = false
        storedRunState = .stopped
    }

    private func storeErrorMessages(_ messages: [String]) {
        storedLastErrorDescription = messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private func snapshotOnQueue() -> AssertionManagerSnapshot {
        AssertionManagerSnapshot(
            runState: storedRunState,
            desiredShouldHold: storedDesiredShouldHold,
            heldAssertions: activeAssertions
                .map { HeldPowerAssertion(type: $0.key, id: $0.value) }
                .sorted { $0.type.rawValue < $1.type.rawValue },
            lastErrorDescription: storedLastErrorDescription
        )
    }
}
