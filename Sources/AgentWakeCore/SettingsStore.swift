import Foundation

public enum SettingsStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidDefaultGraceSeconds(Int)
    case invalidSafetySettings
    case invalidAgentConfiguration(String)
    case duplicateAgentID(String)
}

public final class SettingsStore: StubLifecycleComponent {
    public var settings: AgentWakeSettings {
        settingsQueue.sync {
            storedSettings
        }
    }

    private let paths: AgentWakePaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private weak var logStore: LogStore?
    private let settingsQueue = DispatchQueue(label: "wtf.vishal.agentwake.settings-store")
    private var storedSettings: AgentWakeSettings

    public init(
        settings: AgentWakeSettings = AgentWakeSettings(),
        paths: AgentWakePaths = .defaultPaths(),
        fileManager: FileManager = .default,
        logStore: LogStore? = nil
    ) {
        self.storedSettings = settings
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
        setSettings(loadOrRecover())
    }

    public func save(_ settings: AgentWakeSettings) throws {
        try validate(settings)
        let data = try encoder.encode(settings)
        try AtomicFileWriter.write(data, to: paths.settingsURL, fileManager: fileManager)
        setSettings(settings)
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

    public func recordIntegrationState(_ state: IntegrationState) throws {
        var next = settings
        next.integrationStates[state.agentID] = state
        try save(next)
    }

    public func recordIntegrationSuppression(agentID: String, reason: String?) throws {
        var next = settings
        next.integrationSuppressions[agentID] = IntegrationSuppression(doNotAutoInstall: true, reason: reason)
        try save(next)
    }

    public func clearIntegrationSuppression(agentID: String) throws {
        var next = settings
        next.integrationSuppressions.removeValue(forKey: agentID)
        try save(next)
    }

    public func removeSavedSettingsForFreshInstall() throws {
        if fileManager.fileExists(atPath: paths.settingsURL.path) {
            try fileManager.removeItem(at: paths.settingsURL)
        }
        setSettings(AgentWakeSettings())
        logStore?.append(
            kind: .settingsSaved,
            message: "Saved settings removed for fresh install"
        )
    }

    public func pauseSleepProtection(until expiresAt: Date? = nil) throws {
        var next = settings
        next.manualOverrides.removeAll { $0.overrideKind == .pauseAll }
        next.manualOverrides.append(
            ManualOverride(id: "user-pause", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: expiresAt)
        )
        try save(next)
    }

    public func resumeSleepProtection() throws {
        var next = settings
        next.manualOverrides.removeAll { $0.overrideKind == .pauseAll }
        try save(next)
    }

    public func setLaunchAtLogin(_ isEnabled: Bool) throws {
        var next = settings
        next.launchAtLogin = isEnabled
        try save(next)
    }

    public func setSafety(_ safety: SafetySettings) throws {
        var next = settings
        next.safety = safety
        try save(next)
    }

    public func setAgentEnabled(agentID: String, isEnabled: Bool) throws {
        var next = settings
        guard let index = next.agents.firstIndex(where: { $0.id == agentID }) else {
            throw SettingsStoreError.invalidAgentConfiguration(agentID)
        }

        next.agents[index].isEnabled = isEnabled
        try save(next)
    }

    public func loadOrRecover() -> AgentWakeSettings {
        do {
            return try load()
        } catch is DecodingError {
            return recoverCorruptSettings()
        } catch SettingsStoreError.unsupportedSchemaVersion(let version) {
            logStore?.append(
                kind: .degradedConfidence,
                metadata: [
                    "status": "unsupported-settings-schema",
                    "errorCode": "schema-\(version)"
                ]
            )
            return settings
        } catch {
            logStore?.append(
                kind: .degradedConfidence,
                metadata: [
                    "status": "settings-load-failed",
                    "errorCode": "io"
                ]
            )
            return settings
        }
    }

    public func load() throws -> AgentWakeSettings {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else {
            let defaults = AgentWakeSettings()
            try save(defaults)
            return defaults
        }

        let data = try Data(contentsOf: paths.settingsURL)
        let loaded = try decoder.decode(AgentWakeSettings.self, from: data)
        try validate(loaded)
        return loaded
    }

    private func validate(_ settings: AgentWakeSettings) throws {
        guard settings.schemaVersion == AgentWakeSettings.currentSchemaVersion else {
            throw SettingsStoreError.unsupportedSchemaVersion(settings.schemaVersion)
        }

        guard (60...86_400).contains(settings.defaultGraceSeconds) else {
            throw SettingsStoreError.invalidDefaultGraceSeconds(settings.defaultGraceSeconds)
        }

        guard (0...100).contains(settings.safety.batteryFloorPercent),
              (0...120).contains(settings.safety.temperatureWarningCelsius),
              (1...125).contains(settings.safety.temperatureCutoffCelsius),
              settings.safety.temperatureWarningCelsius < settings.safety.temperatureCutoffCelsius
        else {
            throw SettingsStoreError.invalidSafetySettings
        }

        var seenAgentIDs = Set<String>()
        for agent in settings.agents {
            try validateAgentID(agent.id)
            guard !agent.executableNames.isEmpty else {
                throw SettingsStoreError.invalidAgentConfiguration(agent.id)
            }
            guard seenAgentIDs.insert(agent.id).inserted else {
                throw SettingsStoreError.duplicateAgentID(agent.id)
            }
        }

        for agent in settings.customAgents {
            try validateAgentID(agent.id)
            guard !agent.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SettingsStoreError.invalidAgentConfiguration(agent.id)
            }
            guard seenAgentIDs.insert(agent.id).inserted else {
                throw SettingsStoreError.duplicateAgentID(agent.id)
            }
        }

        for (agentID, state) in settings.integrationStates {
            try validateAgentID(agentID)
            guard state.agentID == agentID else {
                throw SettingsStoreError.invalidAgentConfiguration(agentID)
            }
        }
    }

    private func validateAgentID(_ id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsStoreError.invalidAgentConfiguration(id)
        }
    }

    private func recoverCorruptSettings() -> AgentWakeSettings {
        let recoveredSettings = AgentWakeSettings()
        let corruptURL = moveCorruptSettingsAside()

        do {
            try save(recoveredSettings)
        } catch {
            setSettings(recoveredSettings)
        }

        logStore?.append(
            kind: .settingsRecoveredFromCorruption,
            metadata: [
                "settingsFile": paths.settingsURL.path,
                "corruptSettingsFile": corruptURL?.path ?? "missing"
            ]
        )

        return recoveredSettings
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

    private func setSettings(_ settings: AgentWakeSettings) {
        settingsQueue.sync {
            storedSettings = settings
        }
    }
}
