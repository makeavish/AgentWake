import Foundation

public final class AgentSessionStateMachine {
    public var graceInterval: TimeInterval
    public var processDetectionHoldInterval: TimeInterval
    public private(set) var sessions: [AgentSession]
    public private(set) var pauseAllExpiresAt: Date?
    public private(set) var manualPauseAllExpiresAt: Date?
    public private(set) var safetyCutoffActive: Bool
    public private(set) var manualSafetyCutoffExpiresAt: Date?

    public init(
        graceInterval: TimeInterval = 15 * 60,
        processDetectionHoldInterval: TimeInterval = 15 * 60,
        sessions: [AgentSession] = [],
        pauseAllExpiresAt: Date? = nil,
        manualPauseAllExpiresAt: Date? = nil,
        safetyCutoffActive: Bool = false,
        manualSafetyCutoffExpiresAt: Date? = nil
    ) {
        self.graceInterval = graceInterval
        self.processDetectionHoldInterval = processDetectionHoldInterval
        self.sessions = sessions
        self.pauseAllExpiresAt = pauseAllExpiresAt
        self.manualPauseAllExpiresAt = manualPauseAllExpiresAt
        self.safetyCutoffActive = safetyCutoffActive
        self.manualSafetyCutoffExpiresAt = manualSafetyCutoffExpiresAt
    }

    public func applyProcessObservations(_ observations: [AgentProcessObservation], at now: Date) {
        refreshExpirations(at: now)

        let observedRuntimeIdentities = Set(observations.compactMap(\.key.processRuntimeIdentity))
        let observedRuntimeIdentitiesByAgent = Dictionary(grouping: observations, by: \.agent)
            .mapValues { Set($0.compactMap(\.key.processRuntimeIdentity)) }
        let observedPIDsByAgent = Dictionary(grouping: observations, by: \.agent)
            .mapValues { Set($0.map { $0.snapshot.pid }) }
        for index in sessions.indices {
            if sessions[index].source == .processScan,
               let identity = sessions[index].key.processRuntimeIdentity,
               !observedRuntimeIdentities.contains(identity) {
                markProcessDisappeared(at: index, now: now)
                continue
            }

            if sessions[index].source == .integrationEvent,
               sessions[index].state != .finished {
                if let identity = sessions[index].key.processRuntimeIdentity {
                    if observedRuntimeIdentitiesByAgent[sessions[index].agent]?.contains(identity) != true {
                        markProcessDisappeared(at: index, now: now)
                    }
                } else if let pid = sessions[index].key.pid,
                          observedPIDsByAgent[sessions[index].agent]?.contains(pid) != true {
                    markProcessDisappeared(at: index, now: now)
                }
            }
        }

        var newProcessSessionIndexes = Set<Array<AgentSession>.Index>()
        for observation in observations {
            guard let runtimeIdentity = observation.key.processRuntimeIdentity else {
                continue
            }

            if let index = firstProcessSessionIndex(matching: observation.key) {
                updateSession(at: index, with: observation, at: now)
            } else {
                if let volatileIndex = sessions.firstIndex(where: {
                    $0.state != .finished && $0.key.processRuntimeIdentity == runtimeIdentity
                }) {
                    markProcessDisappeared(at: volatileIndex, now: now)
                }

                let provisionalHoldExpiresAt: Date? = hasReleasedProcessSession(matching: observation.key) ? .distantPast : nil
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
                        diagnosticCPUPercent: observation.snapshot.cpuPercent,
                        provisionalHoldExpiresAt: provisionalHoldExpiresAt
                    )
                )
                newProcessSessionIndexes.insert(sessions.index(before: sessions.endIndex))
            }
        }

        refreshProvisionalProcessHolds(at: now, newSessionIndexes: newProcessSessionIndexes)
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

    public func applyIntegrationEvent(_ event: HookAdapterEvent, at now: Date) {
        refreshExpirations(at: now)

        guard event.schemaVersion == 1 else {
            return
        }

        if let index = firstIntegrationSessionIndex(matching: event) {
            guard shouldAcceptTrustedEvent(event.sessionEventKind, forSessionAt: index, at: now),
                  shouldAcceptIntegrationEvent(event, forSessionAt: index) else {
                return
            }

            adoptIntegrationIdentity(from: event, forSessionAt: index)
            applyTrustedEvent(event.sessionEventKind, toSessionAt: index, at: now)
            return
        }

        guard event.createsSession else {
            return
        }

        guard !hasFinishedIntegrationSession(matching: event) else {
            return
        }

        sessions.append(
            AgentSession(
                key: SessionKey(
                    pid: event.pid,
                    processStartTime: event.processStartTime,
                    integrationSessionId: event.integrationSessionId,
                    cwdHash: event.cwdHash
                ),
                agent: event.agent,
                confidence: .integrated,
                source: .integrationEvent,
                firstSeenAt: now,
                lastActivityAt: now,
                lastObservedAt: now,
                lastEvent: SessionEvent(kind: event.sessionEventKind, occurredAt: now)
            )
        )
    }

    public func applyIntegrationEvent(_ event: HookAdapterEvent, at now: Date, fallbackObservations: [AgentProcessObservation]) {
        if let pid = event.pid,
           fallbackObservations.contains(where: { $0.snapshot.pid == pid && $0.agent == event.agent }) {
            applyProcessObservations(fallbackObservations, at: now)
        }

        applyIntegrationEvent(event, at: now)
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

    public func applyManualOverrides(_ overrides: [ManualOverride], at now: Date) {
        refreshExpirations(at: now)

        let activeOverrides = overrides.filter { $0.isActive(at: now) }
        let pauseOverrideExpirations = activeOverrides
            .filter { $0.overrideKind == .pauseAll }
            .map { $0.expiresAt ?? .distantFuture }
        manualPauseAllExpiresAt = pauseOverrideExpirations.max()
        let safetyOverrideExpirations = activeOverrides
            .filter { $0.overrideKind == .safetyCutoff }
            .map { $0.expiresAt ?? .distantFuture }
        manualSafetyCutoffExpiresAt = safetyOverrideExpirations.max()
    }

    public func refreshExpirations(at now: Date) {
        if let pauseAllExpiresAt, pauseAllExpiresAt <= now {
            self.pauseAllExpiresAt = nil
        }

        if let manualPauseAllExpiresAt, manualPauseAllExpiresAt <= now {
            self.manualPauseAllExpiresAt = nil
        }

        if let manualSafetyCutoffExpiresAt, manualSafetyCutoffExpiresAt <= now {
            self.manualSafetyCutoffExpiresAt = nil
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
        let isManualSafetyCutoffActive = manualSafetyCutoffExpiresAt.map { $0 > now } ?? false
        if safetyCutoffActive || isManualSafetyCutoffActive {
            return AgentAggregateHoldState(
                shouldHold: false,
                heldSessionIDs: [],
                isSafetyCutoffActive: true
            )
        }

        let isPaused = pauseAllExpiresAt.map { $0 > now } ?? false
        let isManuallyPaused = manualPauseAllExpiresAt.map { $0 > now } ?? false
        if isPaused || isManuallyPaused {
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

        case .toolStarted, .toolFinishedContinuing, .agentResumed, .processTreeChanged:
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

    private func firstIntegrationSessionIndex(matching event: HookAdapterEvent) -> Array<AgentSession>.Index? {
        if let integrationSessionId = event.integrationSessionId,
           let index = sessions.firstIndex(where: {
               $0.agent == event.agent
                   && $0.key.integrationSessionId == integrationSessionId
                   && $0.state != .finished
                   && eventProcessEvidenceMatches(session: $0, event: event)
           }) {
            return index
        }

        if let pid = event.pid,
           let index = sessions.firstIndex(where: {
               guard $0.agent == event.agent && $0.key.pid == pid && $0.state != .finished else {
                   return false
               }

               if let sessionIntegrationId = $0.key.integrationSessionId,
                  let eventIntegrationId = event.integrationSessionId,
                  sessionIntegrationId != eventIntegrationId {
                   return false
               }

               guard eventProcessEvidenceMatches(session: $0, event: event) else {
                   return false
               }

               if $0.key.processStartTime != nil, event.processStartTime != nil {
                   return true
               }

               return $0.source == .integrationEvent
           }) {
            return index
        }

        return nil
    }

    private func adoptIntegrationIdentity(
        from event: HookAdapterEvent,
        forSessionAt index: Array<AgentSession>.Index
    ) {
        if sessions[index].key.integrationSessionId == nil {
            sessions[index].key.integrationSessionId = event.integrationSessionId
        }

        if sessions[index].key.cwdHash == nil {
            sessions[index].key.cwdHash = event.cwdHash
        }

        sessions[index].provisionalHoldExpiresAt = nil
    }

    private func refreshProvisionalProcessHolds(
        at now: Date,
        newSessionIndexes: Set<Array<AgentSession>.Index>
    ) {
        let activeProcessIndexes = sessions.indices.filter {
            sessions[$0].source == .processScan
                && sessions[$0].state == .active
                && !sessions[$0].hasIntegratedEvidence
                && !sessions[$0].holdWhileOpen
        }

        guard let candidateIndex = provisionalHoldCandidateIndex(from: activeProcessIndexes) else {
            activeProcessIndexes.forEach { sessions[$0].provisionalHoldExpiresAt = nil }
            return
        }

        for index in activeProcessIndexes where index != candidateIndex {
            sessions[index].provisionalHoldExpiresAt = nil
        }

        if sessions[candidateIndex].provisionalHoldExpiresAt == nil,
           newSessionIndexes.contains(candidateIndex) {
            sessions[candidateIndex].provisionalHoldExpiresAt = now.addingTimeInterval(processDetectionHoldInterval)
        }
    }

    private func provisionalHoldCandidateIndex(from indexes: [Array<AgentSession>.Index]) -> Array<AgentSession>.Index? {
        guard !indexes.isEmpty else {
            return nil
        }

        let sortedIndexes = indexes.sorted { lhs, rhs in
            processSortDate(for: sessions[lhs]) > processSortDate(for: sessions[rhs])
        }
        guard let first = sortedIndexes.first else {
            return nil
        }

        if sortedIndexes.count > 1,
           processSortDate(for: sessions[first]) == processSortDate(for: sessions[sortedIndexes[1]]) {
            return nil
        }

        return first
    }

    private func processSortDate(for session: AgentSession) -> Date {
        session.key.processStartTime ?? session.firstSeenAt
    }

    private func shouldAcceptIntegrationEvent(
        _ event: HookAdapterEvent,
        forSessionAt index: Array<AgentSession>.Index
    ) -> Bool {
        if sessions[index].state == .standingBy,
           sessions[index].lastEvent?.kind == .turnFinished {
            switch event.event {
            case .toolStarted, .toolFinishedContinuing:
                return false
            case .turnStarted where event.agent == .codexCLI:
                return false
            default:
                break
            }
        }

        return true
    }

    private func hasFinishedIntegrationSession(matching event: HookAdapterEvent) -> Bool {
        guard let integrationSessionId = event.integrationSessionId else {
            return false
        }

        return sessions.contains {
            $0.agent == event.agent
                && $0.key.integrationSessionId == integrationSessionId
                && $0.lastEvent?.kind == .sessionFinished
                && eventProcessEvidenceMatches(session: $0, event: event)
        }
    }

    private func hasReleasedProcessSession(matching key: SessionKey) -> Bool {
        guard let runtimeIdentity = key.processRuntimeIdentity else {
            return false
        }

        return sessions.contains {
            $0.source == .processScan
                && $0.state == .finished
                && $0.lastEvent?.kind == .releaseNow
                && $0.key.processRuntimeIdentity == runtimeIdentity
        }
    }

    private func eventProcessEvidenceMatches(session: AgentSession, event: HookAdapterEvent) -> Bool {
        guard let eventPID = event.pid else {
            return true
        }

        guard session.key.pid == eventPID else {
            return false
        }

        switch (session.key.processStartTime, event.processStartTime) {
        case let (sessionStart?, eventStart?):
            return sessionStart == eventStart
        case (nil, nil):
            return true
        case (.some, nil), (nil, .some):
            return false
        }
    }

    private func firstProcessSessionIndex(matching key: SessionKey) -> Array<AgentSession>.Index? {
        if let identity = key.processIdentity,
           let index = sessions.firstIndex(where: {
               $0.state != .finished && $0.key.processIdentity == identity
           }) {
            return index
        }

        return sessions.firstIndex { session in
            guard session.source == .processScan,
                  session.state != .finished,
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
            case .toolStarted, .toolFinishedContinuing, .agentResumed, .processTreeChanged, .turnFinished, .keepHolding:
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

private extension HookAdapterEvent {
    var sessionEventKind: SessionEventKind {
        switch event {
        case .sessionStarted, .turnStarted:
            .agentResumed
        case .toolStarted:
            .toolStarted
        case .toolFinishedContinuing:
            .toolFinishedContinuing
        case .agentResumed:
            .agentResumed
        case .turnFinished:
            .turnFinished
        case .sessionFinished:
            .sessionFinished
        }
    }

    var createsSession: Bool {
        switch event {
        case .sessionStarted, .turnStarted, .toolStarted, .toolFinishedContinuing, .agentResumed:
            true
        case .turnFinished, .sessionFinished:
            false
        }
    }
}
