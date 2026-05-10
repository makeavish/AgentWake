import Foundation

public struct ClawShellPaths: Equatable, Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public static func defaultPaths(
        fileManager: FileManager = .default
    ) -> ClawShellPaths {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ClawShell", isDirectory: true)

        return ClawShellPaths(applicationSupportDirectory: directory)
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
}
