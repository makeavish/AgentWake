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

public protocol ClosedLidModeCommandRunning: Sendable {
    func currentDisablesleep() throws -> Int
    func setDisablesleep(_ value: Int) throws
}

public struct PmsetClosedLidModeCommandRunner: ClosedLidModeCommandRunning {
    public init() {}

    public func currentDisablesleep() throws -> Int {
        let output = try runProcess("/usr/bin/pmset", arguments: ["-g", "custom"])
        let pattern = #"\bdisablesleep\s+([01])\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            return Int(output[range]) ?? 0
        }

        // macOS omits disablesleep from pmset output until a non-default value is set.
        return 0
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

        if current == 1, let state, state.phase == .active {
            return "Closed-Lid Mode enabled\nSleepDisabled=1\nRestore value=\(state.previousDisablesleep)"
        }

        if current == 1, let state, state.phase == .pending {
            return "Closed-Lid Mode ownership pending\nSleepDisabled=1\nDisable is blocked until AgentWake confirms active ownership."
        }

        if current == 1 {
            return "Closed-Lid Mode enabled outside AgentWake\nSleepDisabled=1\nDisable is blocked until AgentWake owns a restore record."
        }

        return "Closed-Lid Mode off\nSleepDisabled=0"
    }

    public func currentDisablesleepValue() throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        return try commandRunner.currentDisablesleep()
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
            try saveState(ClosedLidModeState(previousDisablesleep: current, enabledAt: enabledAt, phase: .active))
        } catch {
            try? removeState()
            throw error
        }
        return "Closed-Lid Mode enabled\nSleepDisabled=1\nDisable from AgentWake to restore disablesleep=\(current)."
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
        try removeState()
        return "Closed-Lid Mode disabled\nSleepDisabled=\(restoreValue)"
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

    private func saveState(_ state: ClosedLidModeState) throws {
        let data = try encoder.encode(state)
        try AtomicFileWriter.write(data, to: paths.closedLidModeStateURL, fileManager: fileManager)
    }

    private func removeState() throws {
        guard fileManager.fileExists(atPath: paths.closedLidModeStateURL.path) else {
            return
        }
        try fileManager.removeItem(at: paths.closedLidModeStateURL)
    }
}
