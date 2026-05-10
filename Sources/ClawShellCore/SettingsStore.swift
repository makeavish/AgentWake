import Foundation

public enum SettingsStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

public final class SettingsStore: StubLifecycleComponent {
    public private(set) var settings: ClawShellSettings

    private let paths: ClawShellPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private weak var logStore: LogStore?

    public init(
        settings: ClawShellSettings = ClawShellSettings(),
        paths: ClawShellPaths = .defaultPaths(),
        fileManager: FileManager = .default,
        logStore: LogStore? = nil
    ) {
        self.settings = settings
        self.paths = paths
        self.fileManager = fileManager
        self.logStore = logStore
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        super.init(componentName: "SettingsStore")
    }

    public override func start() {
        super.start()
        settings = loadOrRecover()
    }

    public func save(_ settings: ClawShellSettings) throws {
        try validate(settings)
        let data = try encoder.encode(settings)
        try AtomicFileWriter.write(data, to: paths.settingsURL, fileManager: fileManager)
        self.settings = settings
        logStore?.append(kind: .settingsSaved, message: "Settings saved")
    }

    public func exportData() throws -> Data {
        try encoder.encode(SettingsExport(settings: settings))
    }

    public func importData(_ data: Data) throws {
        let imported = try decoder.decode(SettingsExport.self, from: data)
        let nextSettings = imported.applying(to: settings)
        try save(nextSettings)
        logStore?.append(kind: .settingsImported, message: "Settings imported")
    }

    public func loadOrRecover() -> ClawShellSettings {
        do {
            return try load()
        } catch {
            let recoveredSettings = ClawShellSettings()
            let corruptURL = moveCorruptSettingsAside()

            do {
                try save(recoveredSettings)
            } catch {
                settings = recoveredSettings
            }

            logStore?.append(
                kind: .settingsRecoveredFromCorruption,
                message: "Corrupt settings were moved aside and replaced with defaults",
                metadata: [
                    "settingsFile": paths.settingsURL.path,
                    "corruptSettingsFile": corruptURL?.path ?? "missing"
                ]
            )

            return recoveredSettings
        }
    }

    public func load() throws -> ClawShellSettings {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else {
            let defaults = ClawShellSettings()
            try save(defaults)
            return defaults
        }

        let data = try Data(contentsOf: paths.settingsURL)
        let loaded = try decoder.decode(ClawShellSettings.self, from: data)
        try validate(loaded)
        return loaded
    }

    private func validate(_ settings: ClawShellSettings) throws {
        guard settings.schemaVersion == ClawShellSettings.currentSchemaVersion else {
            throw SettingsStoreError.unsupportedSchemaVersion(settings.schemaVersion)
        }
    }

    private func moveCorruptSettingsAside() -> URL? {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else {
            return nil
        }

        let recoveredURL = paths.settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("settings.corrupt.\(Int(Date().timeIntervalSince1970)).\(UUID().uuidString).json")

        do {
            try fileManager.moveItem(at: paths.settingsURL, to: recoveredURL)
            return recoveredURL
        } catch {
            return nil
        }
    }
}
