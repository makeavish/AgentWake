import CryptoKit
import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32?
    public var processName: String
    public var executablePath: String?
    public var processStartTime: Date?
    public var cpuPercent: Double?

    public init(
        pid: Int32,
        parentPID: Int32? = nil,
        processName: String,
        executablePath: String? = nil,
        processStartTime: Date? = nil,
        cpuPercent: Double? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processName = processName
        self.executablePath = executablePath
        self.processStartTime = processStartTime
        self.cpuPercent = cpuPercent
    }

    public var executableName: String {
        if let executablePath {
            return URL(fileURLWithPath: executablePath).lastPathComponent
        }

        return processName
    }

    public var matchingExecutableNames: Set<String> {
        var names = Set([processName])
        names.insert(executableName)
        return names
    }
}

public struct AgentProcessObservation: Equatable, Sendable {
    public var agent: AgentKind
    public var snapshot: ProcessSnapshot
    public var key: SessionKey
    public var confidence: DetectionConfidence
    public var source: DetectionSource

    public init(
        agent: AgentKind,
        snapshot: ProcessSnapshot,
        key: SessionKey,
        confidence: DetectionConfidence = .processDetected,
        source: DetectionSource = .processScan
    ) {
        self.agent = agent
        self.snapshot = snapshot
        self.key = key
        self.confidence = confidence
        self.source = source
    }
}

public struct AgentProcessDetector: Sendable {
    public var agentConfigurations: [AgentConfiguration]

    public init(agentConfigurations: [AgentConfiguration] = AgentConfiguration.v1Defaults) {
        self.agentConfigurations = agentConfigurations
    }

    public init(settings: ClawShellSettings) {
        self.init(agentConfigurations: settings.agents)
    }

    public func observations(in snapshots: [ProcessSnapshot]) -> [AgentProcessObservation] {
        snapshots.compactMap { snapshot in
            observation(for: snapshot)
        }
    }

    private func observation(for snapshot: ProcessSnapshot) -> AgentProcessObservation? {
        for configuration in agentConfigurations where configuration.isEnabled {
            guard let kind = AgentKind(agentID: configuration.id) else {
                continue
            }

            let executableNames = kind.defaultExecutableNames.union(configuration.executableNames)
            guard !snapshot.matchingExecutableNames.isDisjoint(with: executableNames) else {
                continue
            }
            guard !shouldExclude(snapshot: snapshot, for: kind) else {
                continue
            }

            let executableIdentity = snapshot.executablePath ?? "process:\(snapshot.executableName)"
            let key = SessionKey(
                pid: snapshot.pid,
                processStartTime: snapshot.processStartTime,
                executablePathHash: StablePathHash.sha256(executableIdentity),
                executablePathHashIsVerified: snapshot.executablePath != nil
            )

            return AgentProcessObservation(agent: kind, snapshot: snapshot, key: key)
        }

        return nil
    }

    private func shouldExclude(snapshot: ProcessSnapshot, for kind: AgentKind) -> Bool {
        guard kind == .codexCLI, let executablePath = snapshot.executablePath else {
            return false
        }

        let appServerPathFragments = [
            ".app/Contents/Resources/codex",
            "/.vscode/extensions/openai.chatgpt-"
        ]
        return appServerPathFragments.contains { executablePath.contains($0) }
    }
}

public enum StablePathHash {
    public static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
