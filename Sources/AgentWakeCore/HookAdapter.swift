import CryptoKit
import Foundation

public enum HookAdapterEventKind: String, Codable, CaseIterable, Equatable, Sendable {
    case sessionStarted = "session_started"
    case turnStarted = "turn_started"
    case toolStarted = "tool_started"
    case toolFinishedContinuing = "tool_finished_continuing"
    case agentResumed = "agent_resumed"
    case turnFinished = "turn_finished"
    case sessionFinished = "session_finished"
}

public struct HookAdapterEvent: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var agent: AgentKind
    public var host: String
    public var event: HookAdapterEventKind
    public var pid: Int32?
    public var processStartTime: Date?
    public var integrationSessionId: String?
    public var cwdHash: String?
    public var eventID: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case agent
        case host
        case event
        case pid
        case processStartTime
        case integrationSessionId
        case cwdHash
        case eventID = "eventId"
    }

    public init(
        schemaVersion: Int = 1,
        agent: AgentKind,
        host: String,
        event: HookAdapterEventKind,
        pid: Int32? = nil,
        processStartTime: Date? = nil,
        integrationSessionId: String? = nil,
        cwdHash: String? = nil,
        eventID: String = UUID().uuidString
    ) {
        self.schemaVersion = schemaVersion
        self.agent = agent
        self.host = host
        self.event = event
        self.pid = pid
        self.processStartTime = processStartTime
        self.integrationSessionId = integrationSessionId
        self.cwdHash = cwdHash
        self.eventID = eventID
    }
}

public enum HookAdapterError: Error, Equatable, LocalizedError {
    case invalidPayload
    case unsupportedAgent(String)
    case unsupportedEvent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "Hook adapter payload was not valid JSON."
        case .unsupportedAgent(let agent):
            "Unsupported hook adapter agent: \(agent)."
        case .unsupportedEvent(let event):
            "Unsupported hook adapter event: \(event)."
        }
    }
}

public struct HookAdapterContext: Sendable {
    public var agent: AgentKind
    public var host: String
    public var processID: Int32?
    public var processStartTime: Date?
    public var cwdHashSalt: String?
    public var eventIDProvider: @Sendable () -> String

    public init(
        agent: AgentKind,
        host: String,
        processID: Int32? = Int32(ProcessInfo.processInfo.processIdentifier),
        processStartTime: Date? = nil,
        cwdHashSalt: String? = nil,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.agent = agent
        self.host = host
        self.processID = processID
        self.processStartTime = processStartTime
        self.cwdHashSalt = cwdHashSalt
        self.eventIDProvider = eventIDProvider
    }
}

public enum HookAdapterMapper {
    public static func claudeCodeEvent(
        from data: Data,
        context: HookAdapterContext
    ) throws -> HookAdapterEvent? {
        guard context.agent == .claudeCode else {
            throw HookAdapterError.unsupportedAgent(context.agent.rawValue)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookAdapterError.invalidPayload
        }

        guard let nativeEvent = payload["hook_event_name"] as? String else {
            throw HookAdapterError.invalidPayload
        }

        guard let event = claudeEventMap[nativeEvent] else {
            return nil
        }

        return HookAdapterEvent(
            agent: .claudeCode,
            host: context.host,
            event: event,
            pid: context.processID,
            processStartTime: context.processStartTime,
            integrationSessionId: payload["session_id"] as? String,
            cwdHash: cwdHash(from: payload, salt: context.cwdHashSalt),
            eventID: eventID(from: payload, salt: context.cwdHashSalt, fallback: context.eventIDProvider)
        )
    }

    public static func codexNotifyEvent(
        from notificationPayload: String,
        context: HookAdapterContext
    ) throws -> HookAdapterEvent? {
        guard context.agent == .codexCLI else {
            throw HookAdapterError.unsupportedAgent(context.agent.rawValue)
        }

        guard let data = notificationPayload.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookAdapterError.invalidPayload
        }

        let type = payload["type"] as? String
        guard type == "agent-turn-complete" else {
            return nil
        }

        let turnID = payload["turn-id"] as? String ?? payload["turn_id"] as? String
        return HookAdapterEvent(
            agent: .codexCLI,
            host: context.host,
            event: .turnFinished,
            pid: context.processID,
            processStartTime: context.processStartTime,
            integrationSessionId: turnID,
            eventID: turnID.map { "codex-\($0)" } ?? context.eventIDProvider()
        )
    }

    public static func codexHookEvent(
        from data: Data,
        context: HookAdapterContext
    ) throws -> HookAdapterEvent? {
        guard context.agent == .codexCLI else {
            throw HookAdapterError.unsupportedAgent(context.agent.rawValue)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookAdapterError.invalidPayload
        }

        guard let nativeEvent = payload["hook_event_name"] as? String else {
            throw HookAdapterError.invalidPayload
        }

        guard let event = codexHookEventMap[nativeEvent] else {
            return nil
        }

        return HookAdapterEvent(
            agent: .codexCLI,
            host: context.host,
            event: event,
            pid: context.processID,
            processStartTime: context.processStartTime,
            integrationSessionId: codexIntegrationSessionID(from: payload),
            cwdHash: cwdHash(from: payload, salt: context.cwdHashSalt),
            eventID: codexEventID(from: payload, salt: context.cwdHashSalt, fallback: context.eventIDProvider)
        )
    }

    private static let claudeEventMap: [String: HookAdapterEventKind] = [
        "SessionStart": .sessionStarted,
        "UserPromptSubmit": .turnStarted,
        "PreToolUse": .toolStarted,
        "PostToolUse": .toolFinishedContinuing,
        "Stop": .turnFinished,
        "SessionEnd": .sessionFinished
    ]

    private static let codexHookEventMap: [String: HookAdapterEventKind] = [
        "SessionStart": .sessionStarted,
        "UserPromptSubmit": .turnStarted,
        "PreToolUse": .toolStarted,
        "PostToolUse": .toolFinishedContinuing,
        "Stop": .turnFinished
    ]

    private static func eventID(
        from payload: [String: Any],
        salt: String?,
        fallback: @Sendable () -> String
    ) -> String {
        if let eventID = payload["event_id"] as? String, !eventID.isEmpty {
            return eventID
        }

        if let salt,
           !salt.isEmpty,
           let hookEvent = payload["hook_event_name"] as? String,
           let toolUseID = payload["tool_use_id"] as? String,
           !toolUseID.isEmpty {
            let sessionID = payload["session_id"] as? String ?? "unknown-session"
            return "claude-\(CWDHash.hmacSHA256("\(sessionID):\(hookEvent):\(toolUseID)", salt: salt))"
        }

        return fallback()
    }

    private static func codexIntegrationSessionID(from payload: [String: Any]) -> String? {
        payload["turn_id"] as? String
            ?? payload["turn-id"] as? String
            ?? payload["session_id"] as? String
    }

    private static func codexEventID(
        from payload: [String: Any],
        salt: String?,
        fallback: @Sendable () -> String
    ) -> String {
        guard let salt,
              !salt.isEmpty,
              let hookEvent = payload["hook_event_name"] as? String,
              !hookEvent.isEmpty else {
            return fallback()
        }

        let occurrenceFields = [
            ("event_id", payload["event_id"] as? String),
            ("session_id", payload["session_id"] as? String),
            ("turn_id", payload["turn_id"] as? String ?? payload["turn-id"] as? String),
            ("tool_use_id", payload["tool_use_id"] as? String),
            ("source", payload["source"] as? String)
        ]
        let occurrenceParts = occurrenceFields.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else {
                return nil
            }
            return "\(name)=\(value)"
        }

        guard !occurrenceParts.isEmpty else {
            return fallback()
        }

        let replayKey = ([hookEvent] + occurrenceParts).joined(separator: ":")
        return "codex-\(CWDHash.hmacSHA256(replayKey, salt: salt))"
    }

    private static func cwdHash(from payload: [String: Any], salt: String?) -> String? {
        guard let cwd = payload["cwd"] as? String, let salt else {
            return nil
        }

        return CWDHash.hmacSHA256(cwd, salt: salt)
    }
}

public struct HookAdapterProcessIdentity: Equatable, Sendable {
    public var pid: Int32
    public var processStartTime: Date?

    public init(pid: Int32, processStartTime: Date? = nil) {
        self.pid = pid
        self.processStartTime = processStartTime
    }
}

public enum HookAdapterProcessResolver {
    public static func nearestAgentProcess(
        startingAt pid: Int32,
        agent: AgentKind,
        snapshots: [ProcessSnapshot]
    ) -> HookAdapterProcessIdentity {
        let snapshotsByPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        var currentPID: Int32? = pid
        var visited = Set<Int32>()

        while let candidatePID = currentPID, visited.insert(candidatePID).inserted {
            guard let snapshot = snapshotsByPID[candidatePID] else {
                break
            }

            if isAgentSnapshot(snapshot, agent: agent) {
                return HookAdapterProcessIdentity(pid: snapshot.pid, processStartTime: snapshot.processStartTime)
            }

            currentPID = snapshot.parentPID
        }

        if let snapshot = snapshotsByPID[pid] {
            return HookAdapterProcessIdentity(pid: snapshot.pid, processStartTime: snapshot.processStartTime)
        }

        return HookAdapterProcessIdentity(pid: pid)
    }

    private static func isAgentSnapshot(_ snapshot: ProcessSnapshot, agent: AgentKind) -> Bool {
        !snapshot.matchingExecutableNames.isDisjoint(with: agent.defaultExecutableNames)
    }
}

public enum CWDHash {
    public static func hmacSHA256(_ value: String, salt: String) -> String {
        hmacSHA256(Data(value.utf8), salt: salt)
    }

    public static func hmacSHA256(_ data: Data, salt: String) -> String {
        let key = SymmetricKey(data: Data(salt.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

public final class CWDHashSaltStore {
    private let paths: AgentWakePaths
    private let fileManager: FileManager

    public init(paths: AgentWakePaths = .defaultPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func loadOrCreateSalt() throws -> String {
        if fileManager.fileExists(atPath: paths.cwdHashSaltURL.path) {
            return try String(contentsOf: paths.cwdHashSaltURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let salt = UUID().uuidString + UUID().uuidString
        try AtomicFileWriter.write(Data(salt.utf8), to: paths.cwdHashSaltURL, fileManager: fileManager)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.cwdHashSaltURL.path)
        return salt
    }
}

public struct HookAdapterRunResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public final class HookAdapterRunner {
    private let runtimeStore: ControlRuntimeStore
    private let send: (ControlRequest, URL) throws -> ControlResponse

    public init(
        runtimeStore: ControlRuntimeStore = ControlRuntimeStore(),
        send: @escaping (ControlRequest, URL) throws -> ControlResponse = { request, socketURL in
            try UnixControlSocketClient.send(request, to: socketURL)
        }
    ) {
        self.runtimeStore = runtimeStore
        self.send = send
    }

    public func runClaudeCodeHook(
        stdin: Data,
        context: HookAdapterContext
    ) -> HookAdapterRunResult {
        do {
            guard let event = try HookAdapterMapper.claudeCodeEvent(from: stdin, context: context) else {
                return HookAdapterRunResult()
            }

            return send(event)
        } catch {
            return HookAdapterRunResult()
        }
    }

    public func runCodexNotify(
        payload: String,
        context: HookAdapterContext,
        forwardNotifyCommand: [String] = []
    ) -> HookAdapterRunResult {
        do {
            if let event = try HookAdapterMapper.codexNotifyEvent(from: payload, context: context) {
                _ = send(event)
            }
        } catch {
            // Host integrations must not fail because AgentWake could not parse a notification.
        }

        forwardCodexNotifyIfNeeded(command: forwardNotifyCommand, payload: payload)
        return HookAdapterRunResult()
    }

    public func runCodexHook(
        stdin: Data,
        context: HookAdapterContext
    ) -> HookAdapterRunResult {
        do {
            guard let event = try HookAdapterMapper.codexHookEvent(from: stdin, context: context) else {
                return HookAdapterRunResult()
            }

            return send(event)
        } catch {
            return HookAdapterRunResult()
        }
    }

    private func send(_ event: HookAdapterEvent) -> HookAdapterRunResult {
        do {
            let token = try runtimeStore.loadToken()
            let request = ControlRequest(
                token: token,
                eventID: event.eventID,
                processID: event.pid,
                command: .integrationEvent(event)
            )
            _ = try send(request, runtimeStore.paths.controlSocketURL)
            return HookAdapterRunResult()
        } catch {
            return HookAdapterRunResult()
        }
    }

    private func forwardCodexNotifyIfNeeded(command: [String], payload: String) {
        guard let executable = command.first else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst()) + [payload]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
            }
        } catch {
            return
        }
    }
}
