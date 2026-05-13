import Foundation

public enum ControlServerError: Error, Equatable, LocalizedError {
    case unauthenticated
    case replayedEvent
    case rateLimited
    case unsupportedSchemaVersion(Int)
    case invalidRequest(String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            "Control request was not authenticated."
        case .replayedEvent:
            "Control request was already processed."
        case .rateLimited:
            "Too many control requests. Try again in a moment."
        case .unsupportedSchemaVersion(let version):
            "Unsupported control request schema version: \(version)."
        case .invalidRequest(let message):
            message
        case .notRunning:
            "ClawShell is not running."
        }
    }
}

public enum ControlCommand: Equatable, Sendable, Codable {
    case status
    case pause(duration: TimeInterval)
    case releaseNow
    case list
    case add(binary: String)
    case integrationsList
    case integrationsStatus
    case integrationsRemove(agentID: String)
    case integrationsEnableAuto(agentID: String)
    case integrationEvent(HookAdapterEvent)
    case helperStatus
    case helperRepair
    case uninstall(removeHelper: Bool, removeIntegrations: Bool)

    private enum CodingKeys: String, CodingKey {
        case name
        case duration
        case binary
        case agentID
        case event
        case removeHelper
        case removeIntegrations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)

        switch name {
        case "status":
            self = .status
        case "pause":
            self = .pause(duration: try container.decode(TimeInterval.self, forKey: .duration))
        case "releaseNow":
            self = .releaseNow
        case "list":
            self = .list
        case "add":
            self = .add(binary: try container.decode(String.self, forKey: .binary))
        case "integrationsList":
            self = .integrationsList
        case "integrationsStatus":
            self = .integrationsStatus
        case "integrationsRemove":
            self = .integrationsRemove(agentID: try container.decode(String.self, forKey: .agentID))
        case "integrationsEnableAuto":
            self = .integrationsEnableAuto(agentID: try container.decode(String.self, forKey: .agentID))
        case "integrationEvent":
            self = .integrationEvent(try container.decode(HookAdapterEvent.self, forKey: .event))
        case "helperStatus":
            self = .helperStatus
        case "helperRepair":
            self = .helperRepair
        case "uninstall":
            self = .uninstall(
                removeHelper: try container.decode(Bool.self, forKey: .removeHelper),
                removeIntegrations: try container.decode(Bool.self, forKey: .removeIntegrations)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Unknown control command: \(name)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .status:
            try container.encode("status", forKey: .name)
        case .pause(let duration):
            try container.encode("pause", forKey: .name)
            try container.encode(duration, forKey: .duration)
        case .releaseNow:
            try container.encode("releaseNow", forKey: .name)
        case .list:
            try container.encode("list", forKey: .name)
        case .add(let binary):
            try container.encode("add", forKey: .name)
            try container.encode(binary, forKey: .binary)
        case .integrationsList:
            try container.encode("integrationsList", forKey: .name)
        case .integrationsStatus:
            try container.encode("integrationsStatus", forKey: .name)
        case .integrationsRemove(let agentID):
            try container.encode("integrationsRemove", forKey: .name)
            try container.encode(agentID, forKey: .agentID)
        case .integrationsEnableAuto(let agentID):
            try container.encode("integrationsEnableAuto", forKey: .name)
            try container.encode(agentID, forKey: .agentID)
        case .integrationEvent(let event):
            try container.encode("integrationEvent", forKey: .name)
            try container.encode(event, forKey: .event)
        case .helperStatus:
            try container.encode("helperStatus", forKey: .name)
        case .helperRepair:
            try container.encode("helperRepair", forKey: .name)
        case .uninstall(let removeHelper, let removeIntegrations):
            try container.encode("uninstall", forKey: .name)
            try container.encode(removeHelper, forKey: .removeHelper)
            try container.encode(removeIntegrations, forKey: .removeIntegrations)
        }
    }
}

public struct ControlRequest: Equatable, Sendable, Codable {
    public var schemaVersion: Int
    public var token: String
    public var eventID: String
    public var processID: Int32?
    public var clientTimestamp: Date?
    public var command: ControlCommand

    public init(
        schemaVersion: Int = 1,
        token: String,
        eventID: String = UUID().uuidString,
        processID: Int32? = nil,
        clientTimestamp: Date? = nil,
        command: ControlCommand
    ) {
        self.schemaVersion = schemaVersion
        self.token = token
        self.eventID = eventID
        self.processID = processID
        self.clientTimestamp = clientTimestamp
        self.command = command
    }
}

public struct ControlResponse: Equatable, Sendable, Codable {
    public var accepted: Bool
    public var receiptTimestamp: Date
    public var message: String

    public init(accepted: Bool, receiptTimestamp: Date, message: String) {
        self.accepted = accepted
        self.receiptTimestamp = receiptTimestamp
        self.message = message
    }
}

public protocol ControlCommandRouting {
    func route(_ command: ControlCommand, receivedAt: Date) throws -> ControlResponse
}

public final class ControlServer: @unchecked Sendable {
    public let token: String
    public let maxEventsPerWindow: Int
    public let maxTokenEventsPerWindow: Int
    public let rateLimitWindow: TimeInterval
    public let replayTTL: TimeInterval
    public let maxReplayEventIDs: Int

    private let router: ControlCommandRouting
    private let now: () -> Date
    private let lock = NSLock()
    private var replayedEventIDs: [String: Date] = [:]
    private var rateBuckets: [RateLimitKey: [Date]] = [:]

    public init(
        token: String,
        router: ControlCommandRouting,
        maxEventsPerWindow: Int = 30,
        maxTokenEventsPerWindow: Int? = nil,
        rateLimitWindow: TimeInterval = 60,
        replayTTL: TimeInterval = 600,
        maxReplayEventIDs: Int = 10_000,
        now: @escaping () -> Date = Date.init
    ) {
        self.token = token
        self.router = router
        self.maxEventsPerWindow = maxEventsPerWindow
        self.maxTokenEventsPerWindow = maxTokenEventsPerWindow ?? maxEventsPerWindow * 4
        self.rateLimitWindow = rateLimitWindow
        self.replayTTL = replayTTL
        self.maxReplayEventIDs = maxReplayEventIDs
        self.now = now
    }

    public func handle(_ request: ControlRequest) throws -> ControlResponse {
        lock.lock()
        defer { lock.unlock() }

        let receiptTime = now()

        guard request.schemaVersion == 1 else {
            throw ControlServerError.unsupportedSchemaVersion(request.schemaVersion)
        }

        guard request.token == token else {
            throw ControlServerError.unauthenticated
        }

        try validateCommand(request.command)

        guard !request.eventID.isEmpty else {
            throw ControlServerError.invalidRequest("control request requires an event ID")
        }

        pruneReplayEvents(at: receiptTime)

        guard replayedEventIDs[request.eventID] == nil else {
            throw ControlServerError.replayedEvent
        }

        replayedEventIDs[request.eventID] = receiptTime
        trimReplayEventsIfNeeded()
        try enforceRateLimit(for: request, at: receiptTime)
        return try router.route(request.command, receivedAt: receiptTime)
    }

    private func enforceRateLimit(for request: ControlRequest, at receiptTime: Date) throws {
        let tokenHash = StablePathHash.sha256(request.token)
        let cutoff = receiptTime.addingTimeInterval(-rateLimitWindow)
        var bucketsToConsume: [(key: RateLimitKey, limit: Int)] = [
            (RateLimitKey(tokenHash: tokenHash, processID: nil), maxTokenEventsPerWindow)
        ]

        if let processID = request.processID {
            bucketsToConsume.append((RateLimitKey(tokenHash: tokenHash, processID: processID), maxEventsPerWindow))
        }

        var retainedBuckets: [RateLimitKey: [Date]] = [:]

        for bucket in bucketsToConsume {
            let retained = (rateBuckets[bucket.key] ?? []).filter { $0 >= cutoff }
            retainedBuckets[bucket.key] = retained

            guard retained.count < bucket.limit else {
                rateBuckets[bucket.key] = retained
                throw ControlServerError.rateLimited
            }
        }

        for (key, retained) in retainedBuckets {
            rateBuckets[key] = retained + [receiptTime]
        }
    }

    private func pruneReplayEvents(at receiptTime: Date) {
        let cutoff = receiptTime.addingTimeInterval(-replayTTL)
        replayedEventIDs = replayedEventIDs.filter { $0.value >= cutoff }
    }

    private func trimReplayEventsIfNeeded() {
        guard replayedEventIDs.count > maxReplayEventIDs else {
            return
        }

        let overflowCount = replayedEventIDs.count - maxReplayEventIDs
        let oldestEventIDs = replayedEventIDs
            .sorted { $0.value < $1.value }
            .prefix(overflowCount)
            .map(\.key)

        oldestEventIDs.forEach {
            replayedEventIDs.removeValue(forKey: $0)
        }
    }

    private func validateCommand(_ command: ControlCommand) throws {
        if case .pause(let duration) = command {
            guard duration.isFinite, duration > 0 else {
                throw ControlServerError.invalidRequest("pause requires a positive finite duration")
            }
        }
    }
}

public struct DefaultControlCommandRouter: ControlCommandRouting {
    public var statusProvider: () -> String
    public var pauseHandler: (TimeInterval, Date) -> Void
    public var releaseNowHandler: (Date) -> Void
    public var integrationsListProvider: () -> String
    public var integrationsStatusProvider: () -> String
    public var integrationRemoveHandler: (String, Date) throws -> String
    public var integrationEnableAutoHandler: (String, Date) throws -> String
    public var integrationEventHandler: (HookAdapterEvent, Date) -> String
    public var helperStatusProvider: () -> String
    public var helperRepairHandler: (Date) throws -> String
    public var uninstallHandler: (Bool, Bool, Date) throws -> String

    public init(
        statusProvider: @escaping () -> String = { "ClawShell status unavailable" },
        pauseHandler: @escaping (TimeInterval, Date) -> Void = { _, _ in },
        releaseNowHandler: @escaping (Date) -> Void = { _ in },
        integrationsListProvider: @escaping () -> String = { "Integrations: claude-code, codex-cli" },
        integrationsStatusProvider: @escaping () -> String = { "Integration setup pending" },
        integrationRemoveHandler: @escaping (String, Date) throws -> String = { agentID, _ in "Remove integration requested: \(agentID)" },
        integrationEnableAutoHandler: @escaping (String, Date) throws -> String = { agentID, _ in "Auto-integration enabled: \(agentID)" },
        integrationEventHandler: @escaping (HookAdapterEvent, Date) -> String = { event, _ in "Integration event accepted: \(event.agent.rawValue) \(event.event.rawValue)" },
        helperStatusProvider: @escaping () -> String = { "Helper status unavailable: no helper is installed" },
        helperRepairHandler: @escaping (Date) throws -> String = { _ in "Helper repair unavailable: no helper is installed" },
        uninstallHandler: @escaping (Bool, Bool, Date) throws -> String = { removeHelper, removeIntegrations, _ in
            "Uninstall requested removeHelper=\(removeHelper) removeIntegrations=\(removeIntegrations)"
        }
    ) {
        self.statusProvider = statusProvider
        self.pauseHandler = pauseHandler
        self.releaseNowHandler = releaseNowHandler
        self.integrationsListProvider = integrationsListProvider
        self.integrationsStatusProvider = integrationsStatusProvider
        self.integrationRemoveHandler = integrationRemoveHandler
        self.integrationEnableAutoHandler = integrationEnableAutoHandler
        self.integrationEventHandler = integrationEventHandler
        self.helperStatusProvider = helperStatusProvider
        self.helperRepairHandler = helperRepairHandler
        self.uninstallHandler = uninstallHandler
    }

    public func route(_ command: ControlCommand, receivedAt: Date) throws -> ControlResponse {
        switch command {
        case .status:
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: statusProvider())
        case .pause(let duration):
            pauseHandler(duration, receivedAt)
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: "Pause requested for \(Int(duration)) seconds")
        case .releaseNow:
            releaseNowHandler(receivedAt)
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: "Release requested")
        case .list:
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: "No sessions reported")
        case .add(let binary):
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: "Custom binary support is post-v1: \(binary)")
        case .integrationsList:
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: integrationsListProvider())
        case .integrationsStatus:
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: integrationsStatusProvider())
        case .integrationsRemove(let agentID):
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: try integrationRemoveHandler(agentID, receivedAt))
        case .integrationsEnableAuto(let agentID):
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: try integrationEnableAutoHandler(agentID, receivedAt))
        case .integrationEvent(let event):
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: integrationEventHandler(event, receivedAt))
        case .helperStatus:
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: helperStatusProvider())
        case .helperRepair:
            return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: try helperRepairHandler(receivedAt))
        case .uninstall(let removeHelper, let removeIntegrations):
            return ControlResponse(
                accepted: true,
                receiptTimestamp: receivedAt,
                message: try uninstallHandler(removeHelper, removeIntegrations, receivedAt)
            )
        }
    }
}

private struct RateLimitKey: Hashable {
    var tokenHash: String
    var processID: Int32?
}
