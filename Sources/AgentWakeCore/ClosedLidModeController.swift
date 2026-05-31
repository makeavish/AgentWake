import Foundation

public enum ClosedLidModeError: Error, Equatable, LocalizedError {
    case invalidDisablesleepValue(String)
    case pmsetFailed(String)
    case authorizationFailed(String)
    case notAgentWakeOwned

    public var errorDescription: String? {
        switch self {
        case .invalidDisablesleepValue(let value):
            "Invalid disablesleep value: \(value)"
        case .pmsetFailed(let message):
            message
        case .authorizationFailed(let message):
            message
        case .notAgentWakeOwned:
            "Closed-Lid Mode is enabled outside AgentWake; refusing to change disablesleep without AgentWake-owned restore state."
        }
    }
}

public enum ClosedLidModeOwnershipPhase: String, Codable, Equatable, Sendable {
    case pending
    case active
}

public struct ClosedLidModeState: Codable, Equatable, Sendable {
    public var previousDisablesleep: Int
    public var enabledAt: Date
    public var phase: ClosedLidModeOwnershipPhase

    private enum CodingKeys: String, CodingKey {
        case previousDisablesleep
        case enabledAt
        case phase
    }

    public init(
        previousDisablesleep: Int,
        enabledAt: Date,
        phase: ClosedLidModeOwnershipPhase = .active
    ) {
        self.previousDisablesleep = previousDisablesleep
        self.enabledAt = enabledAt
        self.phase = phase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.previousDisablesleep = try container.decode(Int.self, forKey: .previousDisablesleep)
        self.enabledAt = try container.decode(Date.self, forKey: .enabledAt)
        self.phase = try container.decodeIfPresent(ClosedLidModeOwnershipPhase.self, forKey: .phase) ?? .active
    }
}

public enum ClosedLidStatus: Equatable, Sendable {
    case off
    case enabledByAgentWake
    case enabledByOther
    case ownershipPending
    case unknown(reason: String)
}

public protocol ClosedLidModeCommandRunning: Sendable {
    func currentDisablesleep() throws -> Int
    func setDisablesleep(_ value: Int) throws
}

public struct PmsetClosedLidModeCommandRunner: ClosedLidModeCommandRunning {
    public init() {}

    public func currentDisablesleep() throws -> Int {
        var liveReadError: Error?

        do {
            let liveOutput = try runProcess("/usr/bin/pmset", arguments: ["-g", "live"])
            if let value = Self.parseDisablesleepValue(from: liveOutput) {
                return value
            }
        } catch {
            liveReadError = error
        }

        do {
            let customOutput = try runProcess("/usr/bin/pmset", arguments: ["-g", "custom"])
            if let value = Self.parseDisablesleepValue(from: customOutput) {
                return value
            }
        } catch {
            if let liveReadError {
                throw liveReadError
            }
            throw error
        }

        // macOS can omit disablesleep from custom output when the effective
        // live value is the default/off state.
        return 0
    }

    public static func parseDisablesleepValue(from output: String) -> Int? {
        let pattern = #"\b(?:disablesleep|SleepDisabled)\s+([01])\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }

        return Int(output[range])
    }

    public func setDisablesleep(_ value: Int) throws {
        guard value == 0 || value == 1 else {
            throw ClosedLidModeError.invalidDisablesleepValue(String(value))
        }

        let script = "do shell script \"/usr/bin/pmset disablesleep \(value)\" with administrator privileges"
        _ = try runProcess("/usr/bin/osascript", arguments: ["-e", script])
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> String {
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
            throw ClosedLidModeError.pmsetFailed(error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = stderr.isEmpty ? output : stderr
            throw ClosedLidModeError.authorizationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }
}

public final class ClosedLidModeController: @unchecked Sendable {
    private let paths: AgentWakePaths
    private let commandRunner: ClosedLidModeCommandRunning
    private let fileManager: FileManager
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSRecursiveLock()

    public init(
        paths: AgentWakePaths = .defaultPaths(),
        commandRunner: ClosedLidModeCommandRunning = PmsetClosedLidModeCommandRunner(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func status() -> ClosedLidStatus {
        lock.lock()
        defer { lock.unlock() }

        let current: Int
        do {
            current = try commandRunner.currentDisablesleep()
        } catch {
            return .unknown(reason: error.localizedDescription)
        }
        let state = loadState()

        if current == 1, let state, state.phase == .active {
            return .enabledByAgentWake
        }

        if current == 1, let state, state.phase == .pending {
            return .ownershipPending
        }

        if current == 1 {
            return .enabledByOther
        }

        return .off
    }

    public func statusMessage() -> String {
        lock.lock()
        defer { lock.unlock() }

        let current: Int
        do {
            current = try commandRunner.currentDisablesleep()
        } catch {
            return "Closed-Lid Mode status unknown\n\(error.localizedDescription)"
        }
        let state = loadState()

        switch statusFor(current: current, state: state) {
        case .off:
            return "Closed-Lid Mode off\nSleepDisabled=0"
        case .enabledByAgentWake:
            return "Closed-Lid Mode enabled\nSleepDisabled=1\nWill turn off when AgentWake is no longer keeping this Mac awake.\nRestore value=\(state?.previousDisablesleep ?? 0)"
        case .enabledByOther:
            return "Lid-closed sleep is disabled by another tool\nSleepDisabled=1\nAgentWake left it alone so it can be restored cleanly when you turn that tool off."
        case .ownershipPending:
            return "Closed-Lid Mode ownership pending\nSleepDisabled=1\nDisable is blocked until AgentWake confirms active ownership."
        case .unknown(let reason):
            return "Closed-Lid Mode status unknown\n\(reason)"
        }
    }

    public func currentDisablesleepValue() throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        return try commandRunner.currentDisablesleep()
    }

    public func isAgentWakeOwnedEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let state = loadState(), state.phase == .active else {
            return false
        }

        return (try? commandRunner.currentDisablesleep()) == 1
    }

    public func enable() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let current = try commandRunner.currentDisablesleep()
        if current == 1 {
            return "Closed-Lid Mode already enabled\nSleepDisabled=1"
        }

        let enabledAt = now()
        try saveState(ClosedLidModeState(previousDisablesleep: current, enabledAt: enabledAt, phase: .pending))
        do {
            try commandRunner.setDisablesleep(1)
            try verifyDisablesleep(1)
            try saveState(ClosedLidModeState(previousDisablesleep: current, enabledAt: enabledAt, phase: .active))
        } catch {
            try? removeState()
            throw error
        }
        return "Closed-Lid Mode enabled\nSleepDisabled=1\nAgentWake will restore disablesleep=\(current) when current sleep protection ends."
    }

    public func disable() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let state = loadState() else {
            let current = try commandRunner.currentDisablesleep()
            if current == 0 {
                return "Closed-Lid Mode already off\nSleepDisabled=0"
            }
            throw ClosedLidModeError.notAgentWakeOwned
        }
        guard state.phase == .active else {
            let current = try commandRunner.currentDisablesleep()
            if current == 0 {
                try removeState()
                return "Closed-Lid Mode already off\nSleepDisabled=0"
            }
            throw ClosedLidModeError.notAgentWakeOwned
        }
        let restoreValue = state.previousDisablesleep
        let current = try commandRunner.currentDisablesleep()
        if current == restoreValue {
            try removeState()
            return "Closed-Lid Mode already disabled\nSleepDisabled=\(restoreValue)"
        }
        try commandRunner.setDisablesleep(restoreValue)
        try verifyDisablesleep(restoreValue)
        try removeState()
        return "Closed-Lid Mode disabled\nSleepDisabled=\(restoreValue)"
    }

    public func takeOwnership(restoreValue: Int = 0) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let current = try commandRunner.currentDisablesleep()
        guard current == 1 else {
            try removeState()
            return "Closed-Lid Mode off\nSleepDisabled=0"
        }

        try saveState(ClosedLidModeState(previousDisablesleep: restoreValue, enabledAt: now(), phase: .active))
        return "Closed-Lid Mode ownership adopted\nSleepDisabled=1\nAgentWake will restore disablesleep=\(restoreValue) when current sleep protection ends."
    }

    public func repair() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let current = try commandRunner.currentDisablesleep()
        if current == 0 {
            try removeState()
            return "Closed-Lid Mode repair complete\nSleepDisabled=0"
        }

        guard loadState() != nil else {
            return "Closed-Lid Mode repair found externally enabled SleepDisabled=\(current)\nAgentWake will not change it without AgentWake-owned restore state."
        }

        return "Closed-Lid Mode repair found SleepDisabled=\(current)\nRun `agentwake closed-lid disable` to restore AgentWake-owned state."
    }

    public func uninstall() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if loadState() == nil {
            return "Closed-Lid Mode unchanged\nNo AgentWake-owned state to remove."
        }
        return try disable()
    }

    private func loadState() -> ClosedLidModeState? {
        guard fileManager.fileExists(atPath: paths.closedLidModeStateURL.path),
              let data = try? Data(contentsOf: paths.closedLidModeStateURL) else {
            return nil
        }

        return try? decoder.decode(ClosedLidModeState.self, from: data)
    }

    private func statusFor(current: Int, state: ClosedLidModeState?) -> ClosedLidStatus {
        if current == 1, let state, state.phase == .active {
            return .enabledByAgentWake
        }
        if current == 1, let state, state.phase == .pending {
            return .ownershipPending
        }
        if current == 1 {
            return .enabledByOther
        }
        return .off
    }

    private func saveState(_ state: ClosedLidModeState) throws {
        let data = try encoder.encode(state)
        try AtomicFileWriter.write(data, to: paths.closedLidModeStateURL, fileManager: fileManager)
    }

    private func verifyDisablesleep(_ expected: Int) throws {
        let actual = try commandRunner.currentDisablesleep()
        guard actual == expected else {
            throw ClosedLidModeError.pmsetFailed("Expected SleepDisabled=\(expected), got \(actual)")
        }
    }

    private func removeState() throws {
        guard fileManager.fileExists(atPath: paths.closedLidModeStateURL.path) else {
            return
        }
        try fileManager.removeItem(at: paths.closedLidModeStateURL)
    }
}
