import Foundation

public struct IntegrationInstallLocations: Equatable, Sendable {
    public var claudeSettingsURL: URL
    public var codexConfigURL: URL
    public var adapterPath: String

    public init(
        claudeSettingsURL: URL,
        codexConfigURL: URL,
        adapterPath: String
    ) {
        self.claudeSettingsURL = claudeSettingsURL
        self.codexConfigURL = codexConfigURL
        self.adapterPath = adapterPath
    }

    public static func defaultLocations(fileManager: FileManager = .default) -> IntegrationInstallLocations {
        let home = fileManager.homeDirectoryForCurrentUser
        return IntegrationInstallLocations(
            claudeSettingsURL: home.appendingPathComponent(".claude").appendingPathComponent("settings.json"),
            codexConfigURL: home.appendingPathComponent(".codex").appendingPathComponent("config.toml"),
            adapterPath: defaultAdapterPath()
        )
    }

    private static func defaultAdapterPath() -> String {
        if let bundledAdapter = Bundle.main.url(forAuxiliaryExecutable: "AgentWakeHookAdapter") {
            return bundledAdapter.path
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "AgentWake")
        return executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("AgentWakeHookAdapter")
            .path
    }
}

public struct IntegrationStatusSnapshot: Equatable, Sendable {
    public var agentID: String
    public var displayName: String
    public var status: IntegrationInstallStatus
    public var autoInstallSuppressed: Bool
    public var settingsFile: String?
    public var failureReason: String?

    public init(
        agentID: String,
        displayName: String,
        status: IntegrationInstallStatus,
        autoInstallSuppressed: Bool = false,
        settingsFile: String? = nil,
        failureReason: String? = nil
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.status = status
        self.autoInstallSuppressed = autoInstallSuppressed
        self.settingsFile = settingsFile
        self.failureReason = failureReason
    }
}

public enum IntegrationManagerError: Error, Equatable, LocalizedError {
    case missingInstallLocations
    case unsupportedAgent(String)

    public var errorDescription: String? {
        switch self {
        case .missingInstallLocations:
            "Integration install locations are not configured."
        case .unsupportedAgent(let agentID):
            "Unsupported integration agent: \(agentID)."
        }
    }
}

public final class IntegrationManager: StubLifecycleComponent {
    private let settingsStore: SettingsStore?
    private let logStore: LogStore?
    private let fileManager: FileManager
    private let autoInstallOnStart: Bool
    private let installLocations: IntegrationInstallLocations?
    private let homeDirectory: String
    private let now: @Sendable () -> Date

    public init(
        settingsStore: SettingsStore? = nil,
        logStore: LogStore? = nil,
        autoInstallOnStart: Bool = false,
        installLocations: IntegrationInstallLocations? = nil,
        fileManager: FileManager = .default,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.autoInstallOnStart = autoInstallOnStart
        self.installLocations = installLocations
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.now = now
        super.init(componentName: "IntegrationManager")
    }

    public override func start() {
        super.start()

        guard autoInstallOnStart else {
            return
        }

        for agentID in autoInstallCandidateAgentIDs() {
            guard settingsStore?.settings.integrationSuppressions[agentID]?.doNotAutoInstall != true else {
                continue
            }

            do {
                try installIntegration(agentID: agentID)
            } catch {
                logStore?.append(
                    kind: .degradedConfidence,
                    metadata: [
                        "status": "integration-auto-install-failed",
                        "agentID": agentID,
                        "failureReason": failureReason(for: error)
                    ]
                )
            }
        }
    }

    public func snapshots() -> [IntegrationStatusSnapshot] {
        let settings = settingsStore?.settings ?? AgentWakeSettings()
        return settings.agents.compactMap { configuration -> IntegrationStatusSnapshot? in
            guard AgentKind(agentID: configuration.id) != nil else {
                return nil
            }

            let state = settings.integrationStates[configuration.id]
            let suppression = settings.integrationSuppressions[configuration.id]
            return IntegrationStatusSnapshot(
                agentID: configuration.id,
                displayName: configuration.displayName,
                status: state?.status ?? .notInstalled,
                autoInstallSuppressed: suppression?.doNotAutoInstall == true,
                settingsFile: state?.settingsFile,
                failureReason: state?.failureReason
            )
        }
    }

    public func listMessage() -> String {
        snapshots()
            .map { snapshot in
                var parts = ["\(snapshot.agentID): \(snapshot.status.rawValue)"]
                if snapshot.autoInstallSuppressed {
                    parts.append("suppressed")
                }
                if let settingsFile = snapshot.settingsFile, !settingsFile.isEmpty {
                    parts.append("file=\(redactStatusValue(settingsFile))")
                }
                if let failureReason = snapshot.failureReason, !failureReason.isEmpty {
                    parts.append("reason=\(redactStatusValue(failureReason))")
                }
                return parts.joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    public func statusMessage() -> String {
        let message = listMessage()
        return message.isEmpty ? "No integrations configured" : message
    }

    @discardableResult
    public func recordSetup(
        agentID: String,
        status: IntegrationInstallStatus,
        integrationID: String,
        settingsFile: String?,
        failureReason: String? = nil
    ) throws -> String {
        let state = IntegrationState(
            agentID: agentID,
            status: status,
            integrationID: integrationID,
            settingsFile: settingsFile,
            updatedAt: now(),
            failureReason: failureReason
        )
        try settingsStore?.recordIntegrationState(state)
        logStore?.append(
            kind: status == .removed ? .integrationRemoval : .integrationSetup,
            metadata: [
                "agentID": agentID,
                "integrationID": integrationID,
                "failureReason": failureReason ?? "",
                "settingsFile": settingsFile ?? "",
                "status": status.rawValue
            ]
        )
        return "\(agentID): \(status.rawValue)"
    }

    @discardableResult
    public func installIntegration(agentID: String) throws -> String {
        guard let agent = AgentKind(agentID: agentID) else {
            throw IntegrationManagerError.unsupportedAgent(agentID)
        }
        guard settingsStore?.settings.integrationSuppressions[agentID]?.doNotAutoInstall != true else {
            return "Auto-integration suppressed: \(agentID)"
        }

        do {
            guard let target = target(for: agent) else {
                throw IntegrationManagerError.missingInstallLocations
            }

            let currentData = try readConfigDataIfPresent(at: target.url)
            let plan = try installPlan(for: agent, currentData: currentData, adapterPath: target.adapterPath)
            try validate(plan, for: agent)
            if plan.patchedData != currentData {
                try IntegrationConfigWriter.write(plan, to: target.url, fileManager: fileManager)
            }
            return try recordSetup(
                agentID: agentID,
                status: .installed,
                integrationID: plan.manifest.ownerMarker,
                settingsFile: target.url.path
            )
        } catch {
            _ = try? recordSetup(
                agentID: agentID,
                status: .failed,
                integrationID: integrationID(for: agentID),
                settingsFile: targetURL(for: agent)?.path,
                failureReason: failureReason(for: error)
            )
            throw error
        }
    }

    @discardableResult
    public func removeIntegration(agentID: String, at date: Date? = nil) throws -> String {
        guard let agent = AgentKind(agentID: agentID) else {
            throw IntegrationManagerError.unsupportedAgent(agentID)
        }
        let timestamp = date ?? now()
        let targetURL = targetURL(for: agent)

        try settingsStore?.recordIntegrationSuppression(
            agentID: agentID,
            reason: "removed-by-user"
        )

        if let targetURL, fileManager.fileExists(atPath: targetURL.path) {
            do {
                let currentData = try Data(contentsOf: targetURL)
                let plan = try removalPlan(for: agent, currentData: currentData)
                try validate(plan, for: agent)
                if plan.patchedData != currentData {
                    try IntegrationConfigWriter.write(plan, to: targetURL, fileManager: fileManager)
                }
            } catch {
                _ = try? recordSetup(
                    agentID: agentID,
                    status: .failed,
                    integrationID: integrationID(for: agentID),
                    settingsFile: targetURL.path,
                    failureReason: failureReason(for: error)
                )
                throw error
            }
        }

        let state = IntegrationState(
            agentID: agentID,
            status: .removed,
            integrationID: integrationID(for: agentID),
            settingsFile: targetURL?.path,
            updatedAt: timestamp
        )
        try settingsStore?.recordIntegrationState(state)
        logStore?.append(
            kind: .integrationRemoval,
            metadata: [
                "agentID": agentID,
                "integrationID": state.integrationID,
                "settingsFile": targetURL?.path ?? "",
                "status": "removed"
            ]
        )
        return "Integration removed and auto-install suppressed: \(agentID)"
    }

    @discardableResult
    public func removeAllIntegrations(at date: Date? = nil) throws -> String {
        var messages: [String] = []
        var firstError: Error?

        for agent in AgentKind.allCases {
            do {
                messages.append(try removeIntegration(agentID: agent.rawValue, at: date))
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }

        return messages.joined(separator: "\n")
    }

    @discardableResult
    public func enableAutoInstall(agentID: String) throws -> String {
        guard AgentKind(agentID: agentID) != nil else {
            throw IntegrationManagerError.unsupportedAgent(agentID)
        }

        try settingsStore?.clearIntegrationSuppression(agentID: agentID)
        logStore?.append(
            kind: .integrationSetup,
            metadata: [
                "agentID": agentID,
                "integrationID": integrationID(for: agentID),
                "status": "auto-install-enabled"
            ]
        )

        guard installLocations != nil else {
            return "Auto-integration enabled: \(agentID)"
        }

        let installMessage = try installIntegration(agentID: agentID)
        return "Auto-integration enabled: \(agentID)\n\(installMessage)"
    }

    private func integrationID(for agentID: String) -> String {
        "com.agentwake.integration.\(agentID).v1"
    }

    private func autoInstallCandidateAgentIDs() -> [String] {
        let settings = settingsStore?.settings ?? AgentWakeSettings()
        return settings.agents.compactMap { configuration in
            guard configuration.isEnabled, AgentKind(agentID: configuration.id) != nil else {
                return nil
            }

            return configuration.id
        }
    }

    private func target(for agent: AgentKind) -> (url: URL, adapterPath: String)? {
        guard let installLocations else {
            return nil
        }

        return (targetURL(for: agent, locations: installLocations), installLocations.adapterPath)
    }

    private func targetURL(for agent: AgentKind) -> URL? {
        guard let installLocations else {
            return nil
        }

        return targetURL(for: agent, locations: installLocations)
    }

    private func targetURL(for agent: AgentKind, locations: IntegrationInstallLocations) -> URL {
        switch agent {
        case .claudeCode:
            locations.claudeSettingsURL
        case .codexCLI:
            locations.codexConfigURL
        }
    }

    private func readConfigDataIfPresent(at url: URL) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            return Data()
        }

        return try Data(contentsOf: url)
    }

    private func installPlan(
        for agent: AgentKind,
        currentData: Data,
        adapterPath: String
    ) throws -> IntegrationPatchPlan {
        switch agent {
        case .claudeCode:
            try ClaudeCodeConfigPatcher().installPlan(currentData: currentData, adapterPath: adapterPath)
        case .codexCLI:
            try CodexConfigPatcher().installPlan(currentData: currentData, adapterPath: adapterPath)
        }
    }

    private func removalPlan(
        for agent: AgentKind,
        currentData: Data
    ) throws -> IntegrationPatchPlan {
        switch agent {
        case .claudeCode:
            try ClaudeCodeConfigPatcher().removalPlan(currentData: currentData)
        case .codexCLI:
            try CodexConfigPatcher().removalPlan(currentData: currentData)
        }
    }

    private func validate(_ plan: IntegrationPatchPlan, for agent: AgentKind) throws {
        switch agent {
        case .claudeCode:
            try ClaudeCodeConfigPatcher().validate(plan.patchedData)
        case .codexCLI:
            try CodexConfigPatcher().validate(plan.patchedData)
        }
    }

    private func failureReason(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }

        return String(describing: error)
    }

    private func redactStatusValue(_ value: String) -> String {
        PrivacyRedactor.redact(value, homeDirectory: homeDirectory)
    }
}
