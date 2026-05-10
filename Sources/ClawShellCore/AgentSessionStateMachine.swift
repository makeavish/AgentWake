import Foundation

public final class AgentSessionStateMachine {
    public var graceInterval: TimeInterval
    public private(set) var sessions: [AgentSession]
    public private(set) var pauseAllExpiresAt: Date?
    public private(set) var safetyCutoffActive: Bool

    public init(
        graceInterval: TimeInterval = 15 * 60,
        sessions: [AgentSession] = [],
        pauseAllExpiresAt: Date? = nil,
        safetyCutoffActive: Bool = false
    ) {
        self.graceInterval = graceInterval
        self.sessions = sessions
        self.pauseAllExpiresAt = pauseAllExpiresAt
        self.safetyCutoffActive = safetyCutoffActive
    }

    public func applyProcessObservations(_ observations: [AgentProcessObservation], at now: Date) {
        refreshExpirations(at: now)

        let observedRuntimeIdentities = Set(observations.compactMap(\.key.processRuntimeIdentity))
        for index in sessions.indices {
            guard sessions[index].source == .processScan,
                  let identity = sessions[index].key.processRuntimeIdentity,
                  !observedRuntimeIdentities.contains(identity) else {
                continue
            }

            markProcessDisappeared(at: index, now: now)
        }

        for observation in observations {
            guard let runtimeIdentity = observation.key.processRuntimeIdentity else {
                continue
            }

            if let index = firstProcessSessionIndex(matching: observation.key) {
                updateSession(at: index, with: observation, at: now)
            } else {
                if let volatileIndex = sessions.firstIndex(where: { $0.key.processRuntimeIdentity == runtimeIdentity }) {
                    markProcessDisappeared(at: volatileIndex, now: now)
                }

                sessions.append(
                    AgentSession(
                        key: observation.key,
                        agent: observation.agent,
                        confidence: observation.confidence,
                        source: observation.source,
                        firstSeenAt: now,
                        lastActivityAt: now,
                        lastObservedAt: now,
                        lastEvent: SessionEvent(kind: .matchingProcessStarted, occurredAt: now),
                        diagnosticCPUPercent: observation.snapshot.cpuPercent
                    )
                )
            }
        }
    }

    public func applyTrustedEvent(_ kind: SessionEventKind, to sessionID: UUID, at now: Date) {
        refreshExpirations(at: now)

        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        guard shouldAcceptTrustedEvent(kind, forSessionAt: index, at: now) else {
            return
        }

        applyTrustedEvent(kind, toSessionAt: index, at: now)
    }

    public func pauseAll(until expiresAt: Date?) {
        pauseAllExpiresAt = expiresAt ?? .distantFuture
    }

    public func clearPauseAll() {
        pauseAllExpiresAt = nil
    }

    public func setSafetyCutoffActive(_ isActive: Bool) {
        safetyCutoffActive = isActive
    }

    public func refreshExpirations(at now: Date) {
        if let pauseAllExpiresAt, pauseAllExpiresAt <= now {
            self.pauseAllExpiresAt = nil
        }

        for index in sessions.indices {
            guard sessions[index].state == .standingBy,
                  !sessions[index].holdWhileOpen,
                  let expiresAt = sessions[index].standingByExpiresAt,
                  expiresAt <= now else {
                continue
            }

            sessions[index].state = .finished
            sessions[index].lastEvent = SessionEvent(kind: .graceExpired, occurredAt: now)
        }
    }

    public func aggregateHoldState(at now: Date) -> AgentAggregateHoldState {
        if safetyCutoffActive {
            return AgentAggregateHoldState(
                shouldHold: false,
                heldSessionIDs: [],
                isSafetyCutoffActive: true
            )
        }

        let isPaused = pauseAllExpiresAt.map { $0 > now } ?? false
        if isPaused {
            return AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [], isPaused: true)
        }

        let heldSessionIDs = sessions
            .filter { $0.contributesToHold(at: now) }
            .map(\.id)

        return AgentAggregateHoldState(
            shouldHold: !heldSessionIDs.isEmpty,
            heldSessionIDs: heldSessionIDs
        )
    }

    private func applyTrustedEvent(_ kind: SessionEventKind, toSessionAt index: Int, at now: Date) {
        switch kind {
        case .turnFinished:
            guard sessions[index].state == .active else {
                return
            }

            sessions[index].state = .standingBy
            sessions[index].standingByExpiresAt = now.addingTimeInterval(graceInterval)
            sessions[index].lastEvent = SessionEvent(kind: kind, occurredAt: now)

        case .sessionFinished, .processDisappeared, .releaseNow:
            sessions[index].state = .finished
            sessions[index].standingByExpiresAt = nil
            sessions[index].lastEvent = SessionEvent(kind: kind, occurredAt: now)

        case .toolStarted, .agentResumed, .processTreeChanged:
            guard !sessions[index].hasTerminalEndEvent else {
                return
            }

            sessions[index].state = .active
            sessions[index].lastActivityAt = now
            sessions[index].standingByExpiresAt = nil
            sessions[index].lastEvent = SessionEvent(kind: kind, occurredAt: now)

        case .keepHolding:
            guard sessions[index].state == .standingBy,
                  let expiresAt = sessions[index].standingByExpiresAt,
                  expiresAt > now else {
                return
            }

            let baseline = max(expiresAt, now)
            sessions[index].standingByExpiresAt = baseline.addingTimeInterval(graceInterval)
            sessions[index].lastEvent = SessionEvent(kind: kind, occurredAt: now)

        case .pauseAll:
            pauseAll(until: nil)

        case .safetyCutoff:
            setSafetyCutoffActive(true)

        case .matchingProcessStarted, .graceExpired:
            return
        }
    }

    private func firstProcessSessionIndex(matching key: SessionKey) -> Array<AgentSession>.Index? {
        if let identity = key.processIdentity,
           let index = sessions.firstIndex(where: { $0.key.processIdentity == identity }) {
            return index
        }

        return sessions.firstIndex { session in
            guard session.source == .processScan,
                  let runtimeIdentity = key.processRuntimeIdentity,
                  session.key.processRuntimeIdentity == runtimeIdentity else {
                return false
            }

            return canReconcileExecutablePathVolatility(existing: session.key, incoming: key)
        }
    }

    private func canReconcileExecutablePathVolatility(existing: SessionKey, incoming: SessionKey) -> Bool {
        guard existing.processRuntimeIdentity == incoming.processRuntimeIdentity else {
            return false
        }

        if existing.executablePathHash == incoming.executablePathHash {
            return true
        }

        return !existing.executablePathHashIsVerified || !incoming.executablePathHashIsVerified
    }

    private func updateSession(
        at index: Array<AgentSession>.Index,
        with observation: AgentProcessObservation,
        at now: Date
    ) {
        sessions[index].lastObservedAt = now
        sessions[index].diagnosticCPUPercent = observation.snapshot.cpuPercent
        sessions[index].processExitedAt = nil

        if observation.key.executablePathHashIsVerified {
            sessions[index].key.executablePathHash = observation.key.executablePathHash
            sessions[index].key.executablePathHashIsVerified = true
        } else if sessions[index].key.executablePathHash == nil {
            sessions[index].key.executablePathHash = observation.key.executablePathHash
            sessions[index].key.executablePathHashIsVerified = false
        }
    }

    private func markProcessDisappeared(at index: Array<AgentSession>.Index, now: Date) {
        if sessions[index].processExitedAt == nil {
            sessions[index].processExitedAt = now
        }

        guard sessions[index].state != .finished else {
            sessions[index].lastEvent = SessionEvent(kind: .processDisappeared, occurredAt: now)
            return
        }

        sessions[index].state = .finished
        sessions[index].standingByExpiresAt = nil
        sessions[index].lastEvent = SessionEvent(kind: .processDisappeared, occurredAt: now)
    }

    private func shouldAcceptTrustedEvent(
        _ kind: SessionEventKind,
        forSessionAt index: Array<AgentSession>.Index,
        at now: Date
    ) -> Bool {
        if let lastEventAt = sessions[index].lastEvent?.occurredAt, now < lastEventAt {
            return false
        }

        if sessions[index].hasTerminalEndEvent {
            switch kind {
            case .toolStarted, .agentResumed, .processTreeChanged, .turnFinished, .keepHolding:
                return false
            default:
                return true
            }
        }

        return true
    }
}

private extension AgentSession {
    var hasTerminalEndEvent: Bool {
        switch lastEvent?.kind {
        case .sessionFinished, .processDisappeared, .graceExpired:
            true
        default:
            false
        }
    }
}
