import Foundation

public struct AgentWakeSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case launchAtLogin
        case defaultGraceSeconds
        case agents
        case customAgents
        case integrationSuppressions
        case integrationStates
        case safety
        case manualOverrides
        case helperOwnership
    }

    public var schemaVersion: Int
    public var launchAtLogin: Bool
    public var defaultGraceSeconds: Int
    public var agents: [AgentConfiguration]
    public var customAgents: [CustomAgentConfiguration]
    public var integrationSuppressions: [String: IntegrationSuppression]
    public var integrationStates: [String: IntegrationState]
    public var safety: SafetySettings
    public var manualOverrides: [ManualOverride]
    public var helperOwnership: HelperOwnership?

    public init(
        schemaVersion: Int = AgentWakeSettings.currentSchemaVersion,
        launchAtLogin: Bool = true,
        defaultGraceSeconds: Int = 900,
        agents: [AgentConfiguration] = AgentConfiguration.v1Defaults,
        customAgents: [CustomAgentConfiguration] = [],
        integrationSuppressions: [String: IntegrationSuppression] = [:],
        integrationStates: [String: IntegrationState] = [:],
        safety: SafetySettings = SafetySettings(),
        manualOverrides: [ManualOverride] = [],
        helperOwnership: HelperOwnership? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.launchAtLogin = launchAtLogin
        self.defaultGraceSeconds = defaultGraceSeconds
        self.agents = agents
        self.customAgents = customAgents
        self.integrationSuppressions = integrationSuppressions
        self.integrationStates = integrationStates
        self.safety = safety
        self.manualOverrides = manualOverrides
        self.helperOwnership = helperOwnership
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        defaultGraceSeconds = try container.decode(Int.self, forKey: .defaultGraceSeconds)
        agents = try container.decode([AgentConfiguration].self, forKey: .agents)
        customAgents = try container.decode([CustomAgentConfiguration].self, forKey: .customAgents)
        integrationSuppressions = try container.decode([String: IntegrationSuppression].self, forKey: .integrationSuppressions)
        integrationStates = try container.decodeIfPresent([String: IntegrationState].self, forKey: .integrationStates) ?? [:]
        safety = try container.decode(SafetySettings.self, forKey: .safety)
        manualOverrides = try container.decode([ManualOverride].self, forKey: .manualOverrides)
        helperOwnership = try container.decodeIfPresent(HelperOwnership.self, forKey: .helperOwnership)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(defaultGraceSeconds, forKey: .defaultGraceSeconds)
        try container.encode(agents, forKey: .agents)
        try container.encode(customAgents, forKey: .customAgents)
        try container.encode(integrationSuppressions, forKey: .integrationSuppressions)
        try container.encode(integrationStates, forKey: .integrationStates)
        try container.encode(safety, forKey: .safety)
        try container.encode(manualOverrides, forKey: .manualOverrides)
        try container.encode(helperOwnership, forKey: .helperOwnership)
    }
}

public struct AgentConfiguration: Codable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var executableNames: [String]
    public var isEnabled: Bool

    public init(
        id: String,
        displayName: String,
        executableNames: [String],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.executableNames = executableNames
        self.isEnabled = isEnabled
    }

    public static let v1Defaults = [
        AgentConfiguration(
            id: "claude-code",
            displayName: "Claude Code",
            executableNames: ["claude", "claude-code"]
        ),
        AgentConfiguration(
            id: "codex-cli",
            displayName: "Codex CLI",
            executableNames: ["codex"]
        )
    ]
}

public struct CustomAgentConfiguration: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var executablePath: String
    public var matchArguments: [String]
    public var isEnabled: Bool

    public init(
        id: String,
        displayName: String,
        executablePath: String,
        matchArguments: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.matchArguments = matchArguments
        self.isEnabled = isEnabled
    }
}

public struct IntegrationSuppression: Codable, Equatable, Sendable {
    public var doNotAutoInstall: Bool
    public var reason: String?

    public init(doNotAutoInstall: Bool = true, reason: String? = nil) {
        self.doNotAutoInstall = doNotAutoInstall
        self.reason = reason
    }
}

public enum IntegrationInstallStatus: String, Codable, Equatable, Sendable {
    case notInstalled
    case installed
    case failed
    case degraded
    case removed
}

public struct IntegrationState: Codable, Equatable, Sendable {
    public var agentID: String
    public var status: IntegrationInstallStatus
    public var integrationID: String
    public var settingsFile: String?
    public var patcherVersion: Int
    public var updatedAt: Date
    public var failureReason: String?

    public init(
        agentID: String,
        status: IntegrationInstallStatus,
        integrationID: String,
        settingsFile: String? = nil,
        patcherVersion: Int = 1,
        updatedAt: Date = Date(),
        failureReason: String? = nil
    ) {
        self.agentID = agentID
        self.status = status
        self.integrationID = integrationID
        self.settingsFile = settingsFile
        self.patcherVersion = patcherVersion
        self.updatedAt = updatedAt
        self.failureReason = failureReason
    }
}

public struct SafetySettings: Codable, Equatable, Sendable {
    public var temperatureWarningCelsius: Int
    public var temperatureCutoffCelsius: Int
    public var batteryFloorPercent: Int

    public init(
        temperatureWarningCelsius: Int = 85,
        temperatureCutoffCelsius: Int = 95,
        batteryFloorPercent: Int = 15
    ) {
        self.temperatureWarningCelsius = temperatureWarningCelsius
        self.temperatureCutoffCelsius = temperatureCutoffCelsius
        self.batteryFloorPercent = batteryFloorPercent
    }
}

public struct ManualOverride: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var expiresAt: Date?

    public init(id: String, kind: String, expiresAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.expiresAt = expiresAt
    }

    public var overrideKind: ManualOverrideKind? {
        ManualOverrideKind(rawValue: kind)
    }

    public func isActive(at now: Date) -> Bool {
        expiresAt.map { $0 > now } ?? true
    }
}

public enum ManualOverrideKind: String, Codable, Equatable, Sendable {
    case pauseAll
    case safetyCutoff
}

public struct HelperOwnership: Codable, Equatable, Sendable {
    public var owner: String
    public var installedAt: Date

    public init(owner: String, installedAt: Date) {
        self.owner = owner
        self.installedAt = installedAt
    }
}

public struct SettingsExport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var launchAtLogin: Bool
    public var defaultGraceSeconds: Int
    public var agents: [AgentConfiguration]
    public var customAgents: [CustomAgentConfiguration]
    public var integrationSuppressions: [String: IntegrationSuppression]
    public var safety: SafetySettings

    public init(settings: AgentWakeSettings) {
        schemaVersion = settings.schemaVersion
        launchAtLogin = settings.launchAtLogin
        defaultGraceSeconds = settings.defaultGraceSeconds
        agents = settings.agents
        customAgents = settings.customAgents
        integrationSuppressions = settings.integrationSuppressions
        safety = settings.safety
    }

    public func applying(to settings: AgentWakeSettings) -> AgentWakeSettings {
        AgentWakeSettings(
            schemaVersion: schemaVersion,
            launchAtLogin: launchAtLogin,
            defaultGraceSeconds: defaultGraceSeconds,
            agents: agents,
            customAgents: customAgents,
            integrationSuppressions: integrationSuppressions,
            integrationStates: settings.integrationStates,
            safety: safety,
            manualOverrides: settings.manualOverrides,
            helperOwnership: settings.helperOwnership
        )
    }
}
