import Foundation

public enum AuditEventKind: String, Codable, Equatable, Sendable {
    case appStarted
    case appStopped
    case stateChanged
    case settingsRecoveredFromCorruption
    case settingsSaved
    case settingsImported
    case configMutation
    case integrationSetup
    case integrationRemoval
    case helperChange
    case safetyCutoff
    case crashRecovery
    case endpointAuthFailure
    case degradedConfidence
}

public struct LogEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var kind: AuditEventKind
    public var message: String
    public var metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        kind: AuditEventKind,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.metadata = metadata
    }
}

public final class LogStore: StubLifecycleComponent {
    public private(set) var events: [LogEvent]

    private let paths: ClawShellPaths
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let retentionDays: Int
    private let maxBytes: UInt64
    private let homeDirectory: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        paths: ClawShellPaths = .defaultPaths(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        retentionDays: Int = 7,
        maxBytes: UInt64 = 10 * 1024 * 1024,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        events: [LogEvent] = []
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.now = now
        self.retentionDays = retentionDays
        self.maxBytes = maxBytes
        self.homeDirectory = homeDirectory
        self.events = events
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        super.init(componentName: "LogStore")
    }

    public override func start() {
        super.start()
        do {
            try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
            try enforceRetention()
            events = try loadEvents()
        } catch {
            events = []
        }
    }

    public func append(_ event: LogEvent) {
        let sanitizedEvent = LogEvent(
            timestamp: event.timestamp,
            kind: event.kind,
            message: PrivacyRedactor.redact(event.message, homeDirectory: homeDirectory),
            metadata: PrivacyRedactor.sanitizedMetadata(event.metadata, homeDirectory: homeDirectory)
        )

        events.append(sanitizedEvent)

        do {
            try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
            let line = try encoder.encode(sanitizedEvent) + Data([0x0A])
            if fileManager.fileExists(atPath: paths.auditLogURL.path) {
                let handle = try FileHandle(forWritingTo: paths.auditLogURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.synchronize()
                try handle.close()
            } else {
                try AtomicFileWriter.write(line, to: paths.auditLogURL, fileManager: fileManager)
            }
            try enforceRetention()
            events = try loadEvents()
        } catch {
            // Logging must never take the app down; keep the in-memory event as the fallback.
        }
    }

    public func append(
        kind: AuditEventKind,
        message: String,
        metadata: [String: String] = [:]
    ) {
        append(
            LogEvent(
                timestamp: now(),
                kind: kind,
                message: message,
                metadata: metadata
            )
        )
    }

    public func loadEvents() throws -> [LogEvent] {
        guard fileManager.fileExists(atPath: paths.auditLogURL.path) else {
            return []
        }

        let data = try Data(contentsOf: paths.auditLogURL)
        return data
            .split(separator: 0x0A)
            .compactMap { line in
                try? decoder.decode(LogEvent.self, from: Data(line))
            }
    }

    private func enforceRetention() throws {
        guard fileManager.fileExists(atPath: paths.auditLogURL.path) else {
            return
        }

        var retained = try loadEvents().filter { event in
            now().timeIntervalSince(event.timestamp) <= TimeInterval(retentionDays * 24 * 60 * 60)
        }

        var encoded = try encodeLines(retained)

        while encoded.count > maxBytes, !retained.isEmpty {
            retained.removeFirst()
            encoded = try encodeLines(retained)
        }

        try AtomicFileWriter.write(encoded, to: paths.auditLogURL, fileManager: fileManager)
    }

    private func encodeLines(_ events: [LogEvent]) throws -> Data {
        var data = Data()

        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }

        return data
    }
}
