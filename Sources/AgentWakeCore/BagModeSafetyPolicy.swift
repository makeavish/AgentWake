import Foundation

public enum BagModeSafetyMode: String, Equatable, Sendable {
    case normal
    case warning
    case cutoffLockedOut
    case rearmEligible
}

public enum BagModeSafetyCutoffReason: String, Equatable, Sendable {
    case temperature
    case battery
    case staleSensor
    case unavailableSensor
    case permissionDenied
    case parseFailed
    case helperCrashed
    case unsupportedHardware
    case timedOut
    case coverageInsufficient
    case batteryUnavailable
    case batteryInvalid
}

public struct BagModeSafetyState: Equatable, Sendable {
    public var mode: BagModeSafetyMode
    public var cutoffReason: BagModeSafetyCutoffReason?
    public var cutoffAt: Date?

    public init(
        mode: BagModeSafetyMode = .normal,
        cutoffReason: BagModeSafetyCutoffReason? = nil,
        cutoffAt: Date? = nil
    ) {
        self.mode = mode
        self.cutoffReason = cutoffReason
        self.cutoffAt = cutoffAt
    }
}

public enum BagModeSafetyAction: String, Equatable, Sendable {
    case allow
    case warn
    case failClosedBeforeArming
    case releaseIfArmed
}

public struct BagModeSafetyDecision: Equatable, Sendable {
    public var state: BagModeSafetyState
    public var action: BagModeSafetyAction

    public init(state: BagModeSafetyState, action: BagModeSafetyAction) {
        self.state = state
        self.action = action
    }

    public var canArmBagMode: Bool {
        state.mode == .normal || state.mode == .warning || state.mode == .rearmEligible
    }

    public var shouldReleaseIfArmed: Bool {
        action == .releaseIfArmed
    }
}

public struct BagModeTemperatureSample: Equatable, Sendable {
    public var celsius: Double
    public var capturedAt: Date
    public var coversClosedBagRisk: Bool

    public init(celsius: Double, capturedAt: Date, coversClosedBagRisk: Bool = true) {
        self.celsius = celsius
        self.capturedAt = capturedAt
        self.coversClosedBagRisk = coversClosedBagRisk
    }
}

public enum BagModeTemperatureReading: Equatable, Sendable {
    case sample(BagModeTemperatureSample)
    case unavailable
    case permissionDenied
    case parseFailed
    case helperCrashed
    case unsupportedHardware
    case timedOut
}

public enum BagModeAppThermalPressure: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct BagModeSafetyInput: Equatable, Sendable {
    public var temperature: BagModeTemperatureReading
    public var appThermalPressure: BagModeAppThermalPressure?
    public var batteryPercent: Int?
    public var now: Date

    public init(
        temperature: BagModeTemperatureReading,
        appThermalPressure: BagModeAppThermalPressure? = nil,
        batteryPercent: Int?,
        now: Date
    ) {
        self.temperature = temperature
        self.appThermalPressure = appThermalPressure
        self.batteryPercent = batteryPercent
        self.now = now
    }
}

public struct BagModeSafetyPolicy: Equatable, Sendable {
    public var settings: SafetySettings
    public var maxReadingAgeSeconds: TimeInterval
    public var temperatureHysteresisCelsius: Double
    public var batteryHysteresisPercent: Int

    public init(
        settings: SafetySettings = SafetySettings(),
        maxReadingAgeSeconds: TimeInterval = 10,
        temperatureHysteresisCelsius: Double = 10,
        batteryHysteresisPercent: Int = 5
    ) {
        self.settings = settings
        self.maxReadingAgeSeconds = maxReadingAgeSeconds
        self.temperatureHysteresisCelsius = temperatureHysteresisCelsius
        self.batteryHysteresisPercent = batteryHysteresisPercent
    }

    public func evaluate(
        previous state: BagModeSafetyState = BagModeSafetyState(),
        input: BagModeSafetyInput,
        isBagModeArmed: Bool
    ) -> BagModeSafetyDecision {
        if let failureReason = failureReason(for: input.temperature, at: input.now) {
            return locked(reason: failureReason, at: input.now, isBagModeArmed: isBagModeArmed)
        }

        guard let batteryPercent = input.batteryPercent else {
            return locked(reason: .batteryUnavailable, at: input.now, isBagModeArmed: isBagModeArmed)
        }
        guard (0...100).contains(batteryPercent) else {
            return locked(reason: .batteryInvalid, at: input.now, isBagModeArmed: isBagModeArmed)
        }

        let temperatureCelsius = sampleTemperature(from: input.temperature)
        if batteryPercent <= settings.batteryFloorPercent {
            return locked(reason: .battery, at: input.now, isBagModeArmed: isBagModeArmed)
        }

        if let temperatureCelsius,
           temperatureCelsius >= Double(settings.temperatureCutoffCelsius) {
            return locked(reason: .temperature, at: input.now, isBagModeArmed: isBagModeArmed)
        }

        if input.appThermalPressure == .critical {
            return locked(reason: .temperature, at: input.now, isBagModeArmed: isBagModeArmed)
        }

        if state.mode == .cutoffLockedOut {
            guard let temperatureCelsius,
                  temperatureCelsius <= Double(settings.temperatureCutoffCelsius) - temperatureHysteresisCelsius,
                  batteryPercent >= settings.batteryFloorPercent + batteryHysteresisPercent else {
                return BagModeSafetyDecision(
                    state: BagModeSafetyState(
                        mode: .cutoffLockedOut,
                        cutoffReason: state.cutoffReason,
                        cutoffAt: state.cutoffAt
                    ),
                    action: isBagModeArmed ? .releaseIfArmed : .failClosedBeforeArming
                )
            }

            if isBagModeArmed {
                return BagModeSafetyDecision(
                    state: BagModeSafetyState(
                        mode: .cutoffLockedOut,
                        cutoffReason: state.cutoffReason,
                        cutoffAt: state.cutoffAt
                    ),
                    action: .releaseIfArmed
                )
            }

            return BagModeSafetyDecision(
                state: BagModeSafetyState(mode: .rearmEligible),
                action: .allow
            )
        }

        if shouldWarn(temperatureCelsius: temperatureCelsius, thermalPressure: input.appThermalPressure) {
            return BagModeSafetyDecision(state: BagModeSafetyState(mode: .warning), action: .warn)
        }

        if state.mode == .rearmEligible, isBagModeArmed {
            return BagModeSafetyDecision(state: BagModeSafetyState(mode: .normal), action: .allow)
        }

        return BagModeSafetyDecision(state: BagModeSafetyState(mode: .normal), action: .allow)
    }

    private func failureReason(for reading: BagModeTemperatureReading, at now: Date) -> BagModeSafetyCutoffReason? {
        switch reading {
        case .sample(let sample):
            guard sample.celsius.isFinite else {
                return .parseFailed
            }

            let sampleAge = now.timeIntervalSince(sample.capturedAt)
            if sampleAge < 0 {
                return .parseFailed
            }
            if sampleAge > maxReadingAgeSeconds {
                return .staleSensor
            }
            if !sample.coversClosedBagRisk {
                return .coverageInsufficient
            }
            return nil
        case .unavailable:
            return .unavailableSensor
        case .permissionDenied:
            return .permissionDenied
        case .parseFailed:
            return .parseFailed
        case .helperCrashed:
            return .helperCrashed
        case .unsupportedHardware:
            return .unsupportedHardware
        case .timedOut:
            return .timedOut
        }
    }

    private func sampleTemperature(from reading: BagModeTemperatureReading) -> Double? {
        guard case .sample(let sample) = reading else {
            return nil
        }
        return sample.celsius
    }

    private func shouldWarn(
        temperatureCelsius: Double?,
        thermalPressure: BagModeAppThermalPressure?
    ) -> Bool {
        if let temperatureCelsius,
           temperatureCelsius >= Double(settings.temperatureWarningCelsius) {
            return true
        }

        switch thermalPressure {
        case .serious, .critical:
            return true
        case .nominal, .fair, .none:
            return false
        }
    }

    private func locked(
        reason: BagModeSafetyCutoffReason,
        at now: Date,
        isBagModeArmed: Bool
    ) -> BagModeSafetyDecision {
        BagModeSafetyDecision(
            state: BagModeSafetyState(mode: .cutoffLockedOut, cutoffReason: reason, cutoffAt: now),
            action: isBagModeArmed ? .releaseIfArmed : .failClosedBeforeArming
        )
    }
}
