import Foundation

public enum AgentKind: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case codexCLI = "codex-cli"

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codexCLI:
            "Codex CLI"
        }
    }

    public var defaultExecutableNames: Set<String> {
        switch self {
        case .claudeCode:
            ["claude", "claude-code"]
        case .codexCLI:
            ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"]
        }
    }

    public init?(agentID: String) {
        self.init(rawValue: agentID)
    }
}

public enum SessionState: String, Codable, Equatable, Sendable {
    case active
    case standingBy
    case finished
}

public enum DetectionConfidence: String, Codable, Equatable, Sendable {
    case integrated
    case appSessionDetected
    case processDetected
}

public enum DetectionSource: String, Codable, Equatable, Sendable {
    case processScan
    case integrationEvent
    case customBinary
    case manualOverride
}

public enum SessionEventKind: String, Codable, Equatable, Sendable {
    case matchingProcessStarted
    case turnFinished
    case sessionFinished
    case processDisappeared
    case toolStarted
    case toolFinishedContinuing
    case agentResumed
    case processTreeChanged
    case graceExpired
    case keepHolding
    case releaseNow
    case pauseAll
    case safetyCutoff
}

public struct SessionEvent: Codable, Equatable, Sendable {
    public var kind: SessionEventKind
    public var occurredAt: Date

    public init(kind: SessionEventKind, occurredAt: Date) {
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public struct SessionKey: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32?
    public var processStartTime: Date?
    public var auditTokenHash: String?
    public var executablePathHash: String?
    public var executablePathHashIsVerified: Bool
    public var bundleIdentifier: String?
    public var integrationSessionId: String?
    public var cwdHash: String?

    public init(
        pid: Int32? = nil,
        processStartTime: Date? = nil,
        auditTokenHash: String? = nil,
        executablePathHash: String? = nil,
        executablePathHashIsVerified: Bool = false,
        bundleIdentifier: String? = nil,
        integrationSessionId: String? = nil,
        cwdHash: String? = nil
    ) {
        self.pid = pid
        self.processStartTime = processStartTime
        self.auditTokenHash = auditTokenHash
        self.executablePathHash = executablePathHash
        self.executablePathHashIsVerified = executablePathHashIsVerified
        self.bundleIdentifier = bundleIdentifier
        self.integrationSessionId = integrationSessionId
        self.cwdHash = cwdHash
    }

    public var processIdentity: ProcessSessionIdentity? {
        guard let pid, let processStartTime, let executablePathHash else {
            return nil
        }

        return ProcessSessionIdentity(
            pid: pid,
            processStartTime: processStartTime,
            executablePathHash: executablePathHash
        )
    }

    public var processRuntimeIdentity: ProcessRuntimeIdentity? {
        guard let pid, let processStartTime else {
            return nil
        }

        return ProcessRuntimeIdentity(pid: pid, processStartTime: processStartTime)
    }
}

public struct ProcessRuntimeIdentity: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var processStartTime: Date

    public init(pid: Int32, processStartTime: Date) {
        self.pid = pid
        self.processStartTime = processStartTime
    }
}

public struct ProcessSessionIdentity: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var processStartTime: Date
    public var executablePathHash: String

    public init(pid: Int32, processStartTime: Date, executablePathHash: String) {
        self.pid = pid
        self.processStartTime = processStartTime
        self.executablePathHash = executablePathHash
    }
}

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var key: SessionKey
    public let agent: AgentKind
    public let confidence: DetectionConfidence
    public let source: DetectionSource
    public var state: SessionState
    public var firstSeenAt: Date
    public var lastActivityAt: Date
    public var lastObservedAt: Date
    public var standingByExpiresAt: Date?
    public var holdWhileOpen: Bool
    public var lastEvent: SessionEvent?
    public var diagnosticCPUPercent: Double?
    public var processExitedAt: Date?
    public var provisionalHoldExpiresAt: Date?

    public init(
        id: UUID = UUID(),
        key: SessionKey,
        agent: AgentKind,
        confidence: DetectionConfidence,
        source: DetectionSource,
        state: SessionState = .active,
        firstSeenAt: Date,
        lastActivityAt: Date,
        lastObservedAt: Date,
        standingByExpiresAt: Date? = nil,
        holdWhileOpen: Bool = false,
        lastEvent: SessionEvent? = nil,
        diagnosticCPUPercent: Double? = nil,
        processExitedAt: Date? = nil,
        provisionalHoldExpiresAt: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.agent = agent
        self.confidence = confidence
        self.source = source
        self.state = state
        self.firstSeenAt = firstSeenAt
        self.lastActivityAt = lastActivityAt
        self.lastObservedAt = lastObservedAt
        self.standingByExpiresAt = standingByExpiresAt
        self.holdWhileOpen = holdWhileOpen
        self.lastEvent = lastEvent
        self.diagnosticCPUPercent = diagnosticCPUPercent
        self.processExitedAt = processExitedAt
        self.provisionalHoldExpiresAt = provisionalHoldExpiresAt
    }

    public func contributesToHold(at now: Date) -> Bool {
        let hasConfirmedEvidence = hasIntegratedEvidence
        let hasProvisionalProcessHold = isProvisionalHold(at: now)

        guard hasConfirmedEvidence || holdWhileOpen || hasProvisionalProcessHold else {
            return false
        }

        return switch state {
        case .active:
            true
        case .standingBy:
            holdWhileOpen || (standingByExpiresAt.map { $0 > now } ?? false)
        case .finished:
            false
        }
    }

    public var hasIntegratedEvidence: Bool {
        source != .processScan || confidence == .integrated || key.integrationSessionId != nil
    }

    public func isProvisionalHold(at now: Date) -> Bool {
        source == .processScan
            && !hasIntegratedEvidence
            && !holdWhileOpen
            && (provisionalHoldExpiresAt.map { $0 > now } ?? false)
    }
}

public struct AgentAggregateHoldState: Equatable, Sendable {
    public var shouldHold: Bool
    public var heldSessionIDs: [UUID]
    public var isPaused: Bool
    public var isSafetyCutoffActive: Bool

    public init(
        shouldHold: Bool,
        heldSessionIDs: [UUID],
        isPaused: Bool = false,
        isSafetyCutoffActive: Bool = false
    ) {
        self.shouldHold = shouldHold
        self.heldSessionIDs = heldSessionIDs
        self.isPaused = isPaused
        self.isSafetyCutoffActive = isSafetyCutoffActive
    }
}
