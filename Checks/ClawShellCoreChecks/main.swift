import ClawShellCore
import Foundation

@main
struct ClawShellCoreChecks {
    static func main() throws {
        try snapshotIncludesAllPlaceholderStates()
        try snapshotNamesTheCurrentState()
        try lifecycleComponentsCanStartAndStopTogether()
        try settingsPersistWithExpectedSchema()
        try corruptSettingsRecoverToDefaults()
        try settingsExportExcludesLocalOnlyState()
        try logsRedactSensitiveFields()
        try logsEnforceRetention()

        print("ClawShellCoreChecks passed")
    }

    private static func snapshotIncludesAllPlaceholderStates() throws {
        let snapshot = MenuBarModel.snapshot(currentState: .idle)

        let placeholderStates = snapshot.items.compactMap { item -> ClawShellState? in
            guard case let .placeholderState(state) = item.kind else {
                return nil
            }

            return state
        }

        try check(
            placeholderStates == ClawShellState.allCases,
            "Expected all placeholder states in declaration order"
        )

        let placeholderTitles = snapshot.items.compactMap { item -> String? in
            guard case .placeholderState = item.kind else {
                return nil
            }

            return item.title
        }

        try check(
            placeholderTitles == ["Idle", "Active", "Bag Mode", "Paused"],
            "Expected menu placeholders for idle, active, Bag Mode, and paused"
        )
    }

    private static func snapshotNamesTheCurrentState() throws {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        try check(snapshot.currentState == .bagMode, "Expected Bag Mode as current state")
        try check(snapshot.statusItemTitle == "ClawShell Bag", "Expected Bag Mode status item title")
        try check(snapshot.items.first?.title == "Current: Bag Mode", "Expected current-state menu row")
        try check(snapshot.items.first?.detail == "Closed-lid guarded mode", "Expected Bag Mode placeholder detail")
    }

    private static func lifecycleComponentsCanStartAndStopTogether() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let services = ClawShellServices(paths: paths)

        services.startAll()
        try check(
            services.lifecycleComponents.allSatisfy { $0.runState == .started },
            "Expected all lifecycle components to start"
        )
        try check(services.logStore.events.map(\.kind).contains(.appStarted), "Expected appStarted log event")

        services.stopAll()
        try check(
            services.lifecycleComponents.allSatisfy { $0.runState == .stopped },
            "Expected all lifecycle components to stop"
        )
        try check(
            services.logStore.events.map(\.kind).contains(.appStopped),
            "Expected appStopped log event"
        )
    }

    private static func settingsPersistWithExpectedSchema() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let logStore = LogStore(paths: paths, homeDirectory: "/Users/tester")
        let store = SettingsStore(paths: paths, logStore: logStore)

        logStore.start()
        store.start()

        try check(FileManager.default.fileExists(atPath: paths.settingsURL.path), "Expected settings.json to exist")
        try check(store.settings.schemaVersion == 1, "Expected schema version 1")
        try check(store.settings.launchAtLogin, "Expected launch at login to default on")
        try check(store.settings.defaultGraceSeconds == 900, "Expected default grace to be 900 seconds")
        try check(store.settings.agents.map(\.id) == ["claude-code", "codex-cli"], "Expected Claude and Codex agent defaults")
        try check(store.settings.safety.batteryFloorPercent == 15, "Expected default battery floor")

        let settingsJSON = try String(contentsOf: paths.settingsURL, encoding: .utf8)
        try check(settingsJSON.contains("\"helperOwnership\" : null"), "Expected helperOwnership null placeholder")
    }

    private static func corruptSettingsRecoverToDefaults() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: paths.settingsURL)

        let logStore = LogStore(paths: paths, homeDirectory: "/Users/tester")
        let store = SettingsStore(paths: paths, logStore: logStore)

        logStore.start()
        store.start()

        try check(store.settings == ClawShellSettings(), "Expected corrupt settings to recover to defaults")
        try check(
            logStore.events.map(\.kind).contains(.settingsRecoveredFromCorruption),
            "Expected corrupt settings recovery log"
        )

        let recoveredFiles = try FileManager.default.contentsOfDirectory(atPath: paths.applicationSupportDirectory.path)
            .filter { $0.hasPrefix("settings.corrupt.") }
        try check(recoveredFiles.count == 1, "Expected corrupt settings file to be moved aside")
    }

    private static func settingsExportExcludesLocalOnlyState() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let logStore = LogStore(paths: paths, homeDirectory: "/Users/tester")
        let store = SettingsStore(paths: paths, logStore: logStore)
        logStore.start()

        var settings = ClawShellSettings()
        settings.defaultGraceSeconds = 1200
        settings.integrationSuppressions["codex-cli"] = IntegrationSuppression(reason: "user removed integration")
        settings.helperOwnership = HelperOwnership(owner: "root", installedAt: Date(timeIntervalSince1970: 1))
        try store.save(settings)

        let exportData = try store.exportData()
        let exportJSON = String(decoding: exportData, as: UTF8.self)

        try check(exportJSON.contains("defaultGraceSeconds"), "Expected grace settings in export")
        try check(exportJSON.contains("integrationSuppressions"), "Expected integration suppressions in export")
        try check(!exportJSON.contains("helperOwnership"), "Expected helper ownership to be excluded from export")
        try check(!exportJSON.contains("runtime"), "Expected runtime tokens to be absent from export")
        try check(!exportJSON.contains("hookPayload"), "Expected hook payloads to be absent from export")

        let importJSON = """
        {
          "schemaVersion": 1,
          "launchAtLogin": false,
          "defaultGraceSeconds": 600,
          "agents": [],
          "customAgents": [],
          "integrationSuppressions": {},
          "safety": {
            "temperatureWarningCelsius": 80,
            "temperatureCutoffCelsius": 90,
            "batteryFloorPercent": 20
          },
          "manualOverrides": [],
          "helperOwnership": {
            "owner": "foreign-helper",
            "installedAt": 1
          }
        }
        """

        try store.importData(Data(importJSON.utf8))
        try check(store.settings.defaultGraceSeconds == 600, "Expected import to apply normal settings")
        try check(store.settings.helperOwnership == settings.helperOwnership, "Expected import to preserve local helper ownership")
    }

    private static func logsRedactSensitiveFields() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let home = "/Users/tester"
        let logStore = LogStore(paths: paths, homeDirectory: home)
        logStore.start()
        logStore.append(
            kind: .configMutation,
            message: "Updated \(home)/.claude/settings.json",
            metadata: [
                "configFile": "\(home)/.claude/settings.json",
                "cwd": "\(home)/project",
                "prompt": "secret prompt",
                "environment": "TOKEN=secret"
            ]
        )

        let event = try checkNotNil(logStore.events.last, "Expected persisted log event")
        try check(event.message == "Updated ~/.claude/settings.json", "Expected home directory redaction")
        try check(event.metadata["configFile"] == "~/.claude/settings.json", "Expected safe path redaction")
        try check(event.metadata["cwd"] == "[redacted]", "Expected raw cwd redaction")
        try check(event.metadata["prompt"] == "[redacted]", "Expected prompt redaction")
        try check(event.metadata["environment"] == "[redacted]", "Expected environment redaction")

        let rawLog = try String(contentsOf: paths.auditLogURL, encoding: .utf8)
        try check(!rawLog.contains(home), "Expected raw log to omit home directory")
        try check(!rawLog.contains("secret prompt"), "Expected raw log to omit prompt text")
        try check(!rawLog.contains("TOKEN=secret"), "Expected raw log to omit environment values")
    }

    private static func logsEnforceRetention() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let now = Date(timeIntervalSince1970: 1_000_000)
        let logStore = LogStore(
            paths: paths,
            now: { now },
            retentionDays: 7,
            maxBytes: 420,
            homeDirectory: "/Users/tester"
        )
        logStore.start()
        logStore.append(
            LogEvent(
                timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                kind: .crashRecovery,
                message: "old event"
            )
        )
        logStore.append(kind: .appStarted, message: "recent event")
        logStore.append(kind: .appStopped, message: String(repeating: "x", count: 300))

        try check(!logStore.events.contains { $0.message == "old event" }, "Expected old log events to be trimmed")
        let logSize = try FileManager.default.attributesOfItem(atPath: paths.auditLogURL.path)[.size] as? UInt64 ?? 0
        try check(logSize <= 420, "Expected log file to stay under the byte cap")
    }

    private static func makeTemporaryPaths() throws -> ClawShellPaths {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClawShellChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ClawShellPaths(applicationSupportDirectory: url)
    }

    private static func checkNotNil<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CheckFailure(message)
        }

        return value
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw CheckFailure(message)
        }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
