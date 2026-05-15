import Foundation

public struct AgentWakePaths: Equatable, Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public static func defaultPaths(
        fileManager: FileManager = .default
    ) -> AgentWakePaths {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AgentWake", isDirectory: true)

        return AgentWakePaths(applicationSupportDirectory: directory)
    }

    public var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    public var logsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public var auditLogURL: URL {
        logsDirectory.appendingPathComponent("audit.jsonl", isDirectory: false)
    }

    public var runtimeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("run", isDirectory: true)
    }

    public var controlSocketURL: URL {
        runtimeDirectory.appendingPathComponent("agentwake.sock", isDirectory: false)
    }

    public var hookTokenURL: URL {
        runtimeDirectory.appendingPathComponent("hook-token", isDirectory: false)
    }

    public var cwdHashSaltURL: URL {
        applicationSupportDirectory.appendingPathComponent("cwd-hash-salt", isDirectory: false)
    }
}
