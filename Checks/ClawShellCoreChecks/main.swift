import ClawShellCore
import Foundation

@main
struct ClawShellCoreChecks {
    static func main() throws {
        try snapshotIncludesAllPlaceholderStates()
        try snapshotNamesTheCurrentState()
        try lifecycleComponentsCanStartAndStopTogether()
        try processDetectorMatchesBuiltInAgents()
        try agentMonitorPollsSnapshotsEveryTwoSecondsByDefault()
        try agentMonitorStartUsesTimerCadence()
        try sessionStateMachineCoversProcessIdentityTransitionsAndAggregateHold()
        try pathLookupVolatilityDoesNotSplitSessions()
        try executablePathHashParticipatesInVerifiedIdentity()
        try cpuDiagnosticsDoNotDriveTransitions()
        try remainingTransitionRowsAreExecutable()
        try trustedEventsAreMonotonic()
        try settingsPersistWithExpectedSchema()
        try corruptSettingsRecoverToDefaults()
        try unsupportedSchemaDoesNotRecoverAsCorrupt()
        try invalidSettingsAreRejected()
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

    private static func processDetectorMatchesBuiltInAgents() throws {
        let detector = AgentProcessDetector(settings: ClawShellSettings())
        let observations = detector.observations(
            in: [
                ProcessSnapshot(
                    pid: 11,
                    processName: "claude",
                    executablePath: "/opt/homebrew/bin/claude",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 12,
                    processName: "claude-code",
                    executablePath: "/usr/local/bin/claude-code",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 13,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 15,
                    processName: "codex",
                    executablePath: nil,
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 16,
                    processName: "codex",
                    executablePath: "/opt/homebrew/Caskroom/codex/codex-aarch64-apple-darwin",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 14,
                    processName: "not-codex",
                    executablePath: "/usr/bin/not-codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                )
            ]
        )

        try check(
            observations.map(\.agent) == [.claudeCode, .claudeCode, .codexCLI, .codexCLI, .codexCLI],
            "Expected built-in process detection for claude, claude-code, and codex"
        )
        try check(
            observations.allSatisfy { $0.key.executablePathHash != nil },
            "Expected executable path hashes when paths are available"
        )
        try check(
            observations[0].key.executablePathHash == StablePathHash.sha256("/opt/homebrew/bin/claude"),
            "Expected real executable path to drive path hash"
        )
        try check(
            observations[0].key.executablePathHash != "/opt/homebrew/bin/claude",
            "Expected raw executable paths not to be retained in session keys"
        )
        try check(!observations[3].key.executablePathHashIsVerified, "Expected missing paths to be marked unverified")
        try check(observations[4].key.executablePathHashIsVerified, "Expected resolved paths to be marked verified")
    }

    private static func agentMonitorPollsSnapshotsEveryTwoSecondsByDefault() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let monitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(
                snapshotsToReturn: [
                    ProcessSnapshot(
                        pid: 24,
                        processName: "codex",
                        executablePath: "/opt/homebrew/bin/codex",
                        processStartTime: now
                    )
                ]
            ),
            settingsProvider: { ClawShellSettings() },
            now: { now }
        )

        try check(monitor.pollInterval == 2, "Expected default process polling interval to be two seconds")
        monitor.poll()
        try check(monitor.sessions.count == 1, "Expected monitor poll to normalize snapshots into sessions")
        try check(monitor.sessions.first?.agent == .codexCLI, "Expected monitor to detect Codex CLI")
    }

    private static func agentMonitorStartUsesTimerCadence() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = CountingSnapshotProvider(
            snapshotsToReturn: [
                ProcessSnapshot(
                    pid: 25,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: now
                )
            ]
        )
        let monitor = AgentMonitor(
            snapshotProvider: provider,
            settingsProvider: { ClawShellSettings() },
            pollInterval: 0.01,
            now: { now }
        )

        monitor.start()
        try check(monitor.scheduledPollInterval == 0.01, "Expected start() to schedule the configured poll cadence")
        try check(provider.callCount == 1, "Expected start() to perform an immediate poll")
        monitor.stop()
        try check(monitor.scheduledPollInterval == nil, "Expected stop() to cancel the scheduled poll")
    }

    private static func sessionStateMachineCoversProcessIdentityTransitionsAndAggregateHold() throws {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let machine = AgentSessionStateMachine(graceInterval: 900)

        machine.applyProcessObservations([observation(pid: 42, start: baseline)], at: baseline)
        let firstSessionID = try checkNotNil(machine.sessions.first?.id, "Expected initial process session")
        try check(machine.sessions.first?.state == .active, "Expected matching process start to create an active session")
        try check(machine.aggregateHoldState(at: baseline).shouldHold, "Expected active session to hold")

        machine.applyProcessObservations(
            [observation(pid: 42, start: baseline, cpuPercent: 80)],
            at: baseline.addingTimeInterval(30)
        )
        try check(machine.sessions.count == 1, "Expected pid/start/path identity to dedupe")
        try check(machine.sessions[0].id == firstSessionID, "Expected deduped observation to keep session id")
        try check(machine.sessions[0].lastActivityAt == baseline, "Expected process polling not to reset activity")

        let turnFinishedAt = baseline.addingTimeInterval(60)
        machine.applyTrustedEvent(.turnFinished, to: firstSessionID, at: turnFinishedAt)
        try check(machine.sessions[0].state == .standingBy, "Expected turn finish to enter standing by")
        try check(
            machine.sessions[0].standingByExpiresAt == turnFinishedAt.addingTimeInterval(900),
            "Expected default 15-minute standing-by grace"
        )

        machine.applyTrustedEvent(.toolStarted, to: firstSessionID, at: baseline.addingTimeInterval(90))
        try check(machine.sessions[0].state == .active, "Expected trusted activity to reactivate")
        try check(machine.sessions[0].standingByExpiresAt == nil, "Expected trusted activity to clear grace expiry")

        let restartedAt = baseline.addingTimeInterval(120)
        machine.applyProcessObservations([observation(pid: 42, start: restartedAt)], at: restartedAt)
        try check(machine.sessions.count == 2, "Expected PID reuse to create a new session")
        try check(
            machine.sessions.contains { $0.id == firstSessionID && $0.state == .finished },
            "Expected old reused-PID session to finish"
        )
        try check(
            machine.sessions.contains { $0.id != firstSessionID && $0.state == .active },
            "Expected new reused-PID session to become active"
        )

        let activeSessionID = try checkNotNil(
            machine.sessions.first(where: { $0.id != firstSessionID })?.id,
            "Expected restarted session id"
        )
        machine.applyTrustedEvent(.turnFinished, to: activeSessionID, at: restartedAt.addingTimeInterval(10))
        machine.applyTrustedEvent(.keepHolding, to: activeSessionID, at: restartedAt.addingTimeInterval(20))
        try check(
            machine.sessions.first(where: { $0.id == activeSessionID })?.standingByExpiresAt == restartedAt.addingTimeInterval(10 + 1_800),
            "Expected keep holding to extend by one grace window"
        )
        try check(machine.aggregateHoldState(at: restartedAt.addingTimeInterval(30)).shouldHold, "Expected standing-by session to hold before expiry")

        machine.refreshExpirations(at: restartedAt.addingTimeInterval(1_811))
        try check(!machine.aggregateHoldState(at: restartedAt.addingTimeInterval(1_811)).shouldHold, "Expected aggregate hold to release after all sessions finish or expire")
    }

    private static func pathLookupVolatilityDoesNotSplitSessions() throws {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let machine = AgentSessionStateMachine()

        machine.applyProcessObservations([observationWithMissingPath(pid: 43, start: baseline)], at: baseline)
        let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected fallback process session")
        machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
        let expiry = try checkNotNil(machine.sessions.first?.standingByExpiresAt, "Expected standing-by expiry")

        machine.applyProcessObservations(
            [observation(pid: 43, start: baseline, path: "/opt/homebrew/bin/codex")],
            at: baseline.addingTimeInterval(20)
        )

        try check(machine.sessions.count == 1, "Expected path hash upgrade not to split the same pid/start process")
        try check(machine.sessions[0].id == sessionID, "Expected path hash upgrade to preserve session identity")
        try check(machine.sessions[0].state == .standingBy, "Expected path hash upgrade not to reactivate the session")
        try check(machine.sessions[0].standingByExpiresAt == expiry, "Expected path hash upgrade not to reset grace")
        try check(machine.sessions[0].key.executablePathHash == StablePathHash.sha256("/opt/homebrew/bin/codex"), "Expected verified path hash to upgrade")
        try check(machine.sessions[0].key.executablePathHashIsVerified, "Expected upgraded path hash to be marked verified")
    }

    private static func executablePathHashParticipatesInVerifiedIdentity() throws {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let machine = AgentSessionStateMachine()

        machine.applyProcessObservations(
            [observation(pid: 44, start: baseline, path: "/opt/homebrew/bin/codex")],
            at: baseline
        )
        let firstSessionID = try checkNotNil(machine.sessions.first?.id, "Expected first verified session")

        machine.applyProcessObservations(
            [observation(pid: 44, start: baseline, path: "/tmp/codex")],
            at: baseline.addingTimeInterval(10)
        )

        try check(machine.sessions.count == 2, "Expected same pid/start with a different verified path to create a new identity")
        try check(
            machine.sessions.contains { $0.id == firstSessionID && $0.state == .finished },
            "Expected old verified-path session to be closed"
        )
        try check(
            machine.sessions.contains { $0.id != firstSessionID && $0.state == .active },
            "Expected new verified-path identity to be active"
        )
    }

    private static func cpuDiagnosticsDoNotDriveTransitions() throws {
        let baseline = Date(timeIntervalSince1970: 2_000)
        let machine = AgentSessionStateMachine(graceInterval: 900)

        machine.applyProcessObservations([observation(pid: 60, start: baseline, cpuPercent: 5)], at: baseline)
        let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected active CPU diagnostic session")
        machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
        let originalExpiry = try checkNotNil(machine.sessions[0].standingByExpiresAt, "Expected standing-by expiry")

        machine.applyProcessObservations(
            [observation(pid: 60, start: baseline, cpuPercent: 95)],
            at: baseline.addingTimeInterval(20)
        )

        try check(machine.sessions[0].state == .standingBy, "Expected CPU load not to reactivate standing-by session")
        try check(machine.sessions[0].standingByExpiresAt == originalExpiry, "Expected CPU load not to extend grace")
        try check(machine.sessions[0].diagnosticCPUPercent == 95, "Expected CPU load to be diagnostic only")
    }

    private static func remainingTransitionRowsAreExecutable() throws {
        let baseline = Date(timeIntervalSince1970: 3_000)
        let machine = AgentSessionStateMachine(graceInterval: 900)
        machine.applyProcessObservations(
            [
                observation(pid: 80, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode),
                observation(pid: 81, start: baseline, path: "/opt/homebrew/bin/codex", agent: .codexCLI)
            ],
            at: baseline
        )
        let claudeID = try checkNotNil(machine.sessions.first(where: { $0.agent == .claudeCode })?.id, "Expected Claude session")
        let codexID = try checkNotNil(machine.sessions.first(where: { $0.agent == .codexCLI })?.id, "Expected Codex session")

        machine.applyTrustedEvent(.releaseNow, to: claudeID, at: baseline.addingTimeInterval(10))
        try check(machine.sessions.first(where: { $0.id == claudeID })?.state == .finished, "Expected releaseNow to release the selected session")
        try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(11)).shouldHold, "Expected other active sessions to keep aggregate hold active")

        machine.pauseAll(until: baseline.addingTimeInterval(20))
        try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(12)).isPaused, "Expected pauseAll to suppress aggregate hold")
        try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(12)).shouldHold, "Expected pauseAll to release assertions")
        try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(21)).shouldHold, "Expected pause expiry to restore remaining held sessions")

        machine.setSafetyCutoffActive(true)
        try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(22)).isSafetyCutoffActive, "Expected safety cutoff to be represented")
        try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(22)).shouldHold, "Expected safety cutoff to suppress aggregate hold")
        machine.setSafetyCutoffActive(false)

        machine.applyTrustedEvent(.sessionFinished, to: codexID, at: baseline.addingTimeInterval(30))
        try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(31)).shouldHold, "Expected sessionFinished to release when no held sessions remain")

        machine.applyProcessObservations([observation(pid: 82, start: baseline.addingTimeInterval(40))], at: baseline.addingTimeInterval(40))
        let processGoneID = try checkNotNil(machine.sessions.first(where: { $0.key.pid == 82 })?.id, "Expected process-backed session")
        machine.applyProcessObservations([], at: baseline.addingTimeInterval(50))
        let processGoneSession = try checkNotNil(machine.sessions.first(where: { $0.id == processGoneID }), "Expected process-backed session to remain visible")
        try check(processGoneSession.state == .finished, "Expected missing process poll to finish the session")
        try check(processGoneSession.processExitedAt == baseline.addingTimeInterval(50), "Expected process exit time to be recorded")
    }

    private static func trustedEventsAreMonotonic() throws {
        let baseline = Date(timeIntervalSince1970: 4_000)
        let machine = AgentSessionStateMachine(graceInterval: 900)
        machine.applyProcessObservations([observation(pid: 90, start: baseline)], at: baseline)
        let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected session")

        machine.applyTrustedEvent(.agentResumed, to: sessionID, at: baseline.addingTimeInterval(20))
        machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
        try check(machine.sessions[0].state == .active, "Expected stale turnFinished not to move active session backward")

        machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(30))
        machine.applyTrustedEvent(.keepHolding, to: sessionID, at: baseline.addingTimeInterval(931))
        try check(machine.sessions[0].state == .finished, "Expected expired grace to finish before keepHolding is considered")

        machine.applyTrustedEvent(.agentResumed, to: sessionID, at: baseline.addingTimeInterval(940))
        try check(machine.sessions[0].state == .finished, "Expected terminal finished session not to reactivate")
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
        try check(
            store.settings.agents.first?.executableNames == ["claude", "claude-code"],
            "Expected Claude executable aliases to include claude and claude-code"
        )
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

    private static func unsupportedSchemaDoesNotRecoverAsCorrupt() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let futureSettings = """
        {
          "schemaVersion": 999,
          "launchAtLogin": true,
          "defaultGraceSeconds": 900,
          "agents": [],
          "customAgents": [],
          "integrationSuppressions": {},
          "safety": {
            "temperatureWarningCelsius": 85,
            "temperatureCutoffCelsius": 95,
            "batteryFloorPercent": 15
          },
          "manualOverrides": [],
          "helperOwnership": null
        }
        """
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        try Data(futureSettings.utf8).write(to: paths.settingsURL)

        let logStore = LogStore(paths: paths, homeDirectory: "/Users/tester")
        let store = SettingsStore(paths: paths, logStore: logStore)
        logStore.start()
        store.start()

        let settingsJSON = try String(contentsOf: paths.settingsURL, encoding: .utf8)
        try check(settingsJSON.contains("\"schemaVersion\": 999"), "Expected unsupported schema file to be preserved")
        try check(
            !logStore.events.map(\.kind).contains(.settingsRecoveredFromCorruption),
            "Expected unsupported schema not to be treated as corruption"
        )

        let recoveredFiles = try FileManager.default.contentsOfDirectory(atPath: paths.applicationSupportDirectory.path)
            .filter { $0.hasPrefix("settings.corrupt.") }
        try check(recoveredFiles.isEmpty, "Expected unsupported schema not to be moved aside")
    }

    private static func invalidSettingsAreRejected() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let store = SettingsStore(paths: paths)

        var invalidGrace = ClawShellSettings()
        invalidGrace.defaultGraceSeconds = -1
        try expectThrows("Expected invalid grace settings to be rejected") {
            try store.save(invalidGrace)
        }

        var invalidSafety = ClawShellSettings()
        invalidSafety.safety = SafetySettings(
            temperatureWarningCelsius: 100,
            temperatureCutoffCelsius: 90,
            batteryFloorPercent: 150
        )
        try expectThrows("Expected invalid safety settings to be rejected") {
            try store.save(invalidSafety)
        }

        var invalidAgent = ClawShellSettings()
        invalidAgent.agents = [
            AgentConfiguration(id: "", displayName: "Broken", executableNames: ["broken"])
        ]
        try expectThrows("Expected invalid agent settings to be rejected") {
            try store.save(invalidAgent)
        }
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
        try check(!exportJSON.contains("manualOverrides"), "Expected manual overrides to be excluded from export")
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
                "settingsFile": "\(home)/.claude/settings.json",
                "configFile": "\(home)/.claude/settings.json",
                "cwd": "\(home)/project",
                "details": "secret prompt",
                "prompt": "secret prompt",
                "environment": "TOKEN=secret"
            ]
        )

        let event = try checkNotNil(logStore.events.last, "Expected persisted log event")
        try check(event.message == "Configuration changed", "Expected canonical audit message")
        try check(event.metadata["settingsFile"] == "~/.claude/settings.json", "Expected safe path redaction")
        try check(event.metadata["configFile"] == nil, "Expected non-allowlisted config key to be dropped")
        try check(event.metadata["cwd"] == nil, "Expected raw cwd key to be dropped")
        try check(event.metadata["details"] == nil, "Expected non-allowlisted details key to be dropped")
        try check(event.metadata["prompt"] == nil, "Expected prompt key to be dropped")
        try check(event.metadata["environment"] == nil, "Expected environment key to be dropped")

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
        logStore.append(
            LogEvent(
                timestamp: now.addingTimeInterval(8 * 24 * 60 * 60),
                kind: .degradedConfidence,
                message: "future event",
                metadata: ["status": "future"]
            )
        )
        logStore.append(kind: .appStarted, message: "recent event")
        logStore.append(kind: .appStopped, message: String(repeating: "x", count: 300))

        try check(!logStore.events.contains { $0.kind == .crashRecovery }, "Expected old log events to be trimmed")
        try check(
            logStore.events.allSatisfy { $0.timestamp <= now },
            "Expected future log timestamps to be clamped to now"
        )
        let logSize = try FileManager.default.attributesOfItem(atPath: paths.auditLogURL.path)[.size] as? UInt64 ?? 0
        try check(logSize <= 420, "Expected log file to stay under the byte cap")
    }

    private static func makeTemporaryPaths() throws -> ClawShellPaths {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClawShellChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ClawShellPaths(applicationSupportDirectory: url)
    }

    private static func observation(
        pid: Int32,
        start: Date,
        path: String = "/opt/homebrew/bin/codex",
        agent: AgentKind = .codexCLI,
        cpuPercent: Double? = nil
    ) -> AgentProcessObservation {
        let snapshot = ProcessSnapshot(
            pid: pid,
            processName: URL(fileURLWithPath: path).lastPathComponent,
            executablePath: path,
            processStartTime: start,
            cpuPercent: cpuPercent
        )

        return AgentProcessObservation(
            agent: agent,
            snapshot: snapshot,
            key: SessionKey(
                pid: pid,
                processStartTime: start,
                executablePathHash: StablePathHash.sha256(path),
                executablePathHashIsVerified: true
            )
        )
    }

    private static func observationWithMissingPath(pid: Int32, start: Date) -> AgentProcessObservation {
        let snapshot = ProcessSnapshot(
            pid: pid,
            processName: "codex",
            executablePath: nil,
            processStartTime: start
        )

        return AgentProcessObservation(
            agent: .codexCLI,
            snapshot: snapshot,
            key: SessionKey(
                pid: pid,
                processStartTime: start,
                executablePathHash: StablePathHash.sha256("process:codex"),
                executablePathHashIsVerified: false
            )
        )
    }

    private static func checkNotNil<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CheckFailure(message)
        }

        return value
    }

    private static func expectThrows(_ message: String, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }

        throw CheckFailure(message)
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

struct StaticSnapshotProvider: ProcessSnapshotProviding {
    var snapshotsToReturn: [ProcessSnapshot]

    func snapshots() throws -> [ProcessSnapshot] {
        snapshotsToReturn
    }
}

final class CountingSnapshotProvider: ProcessSnapshotProviding {
    var snapshotsToReturn: [ProcessSnapshot]
    private let lock = NSLock()
    private var count = 0

    init(snapshotsToReturn: [ProcessSnapshot]) {
        self.snapshotsToReturn = snapshotsToReturn
    }

    var callCount: Int {
        lock.withLock {
            count
        }
    }

    func snapshots() throws -> [ProcessSnapshot] {
        lock.withLock {
            count += 1
        }
        return snapshotsToReturn
    }
}
