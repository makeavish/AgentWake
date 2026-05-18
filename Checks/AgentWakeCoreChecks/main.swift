import AgentWakeCore
import Foundation

@main
struct AgentWakeCoreChecks {
    static func main() throws {
        try snapshotIncludesRuntimeDiagnostics()
        try snapshotNamesTheCurrentState()
        try snapshotUsesGlanceableStatusIcons()
        try closedLidModeControllerEnablesAndRestoresPrimitive()
        try stateDerivesFromHoldState()
        try lifecycleComponentsCanStartAndStopTogether()
        try processDetectorMatchesBuiltInAgents()
        try processDetectorExcludesCodexAppServerProcesses()
        try agentMonitorSummarizesParallelSessions()
        try processOnlyDetectionsRemainDiagnosticUntilIntegrated()
        try sessionOverviewCombinesAgentStateBuckets()
        try processOnlyDetectionDoesNotProtectWithoutIntegration()
        try agentMonitorPollsSnapshotsEveryTwoSecondsByDefault()
        try agentMonitorStartUsesTimerCadence()
        try sessionStateMachineCoversProcessIdentityTransitionsAndAggregateHold()
        try pathLookupVolatilityDoesNotSplitSessions()
        try executablePathHashParticipatesInVerifiedIdentity()
        try cpuDiagnosticsDoNotDriveTransitions()
        try remainingTransitionRowsAreExecutable()
        try bagModeSafetyPolicyCoversWarningCutoffFailClosedAndHysteresis()
        try closedLidSafetyMonitorReleasesOnCutoff()
        try bagModeSafetyDiagnosticsCoverUserFacingProviderStates()
        try powerSourceReaderParsesPmsetBatteryOutput()
        try trustedEventsAreMonotonic()
        try outOfOrderHookEventsAreIgnored()
        try manualOverridePrecedenceAndPersistence()
        try assertionManagerAcquiresValidatedNormalAssertionsAndReleases()
        try assertionManagerPauseAndReleaseOverridesStopAssertions()
        try assertionManagerPartialCreateFailureKeepsAcquiredAssertionsAndRetriesMissingOnes()
        try assertionManagerFailedReleaseRemainsTrackedAndRetriesWithoutHidingError()
        try controlRouterPauseAndReleaseReconcileAssertions()
        try controlRouterPropagatesIntegrationMutationFailures()
        try controlRouterSurfacesHelperCommandOutcomes()
        try assertionManagerStopReleasesHeldAssertions()
        try assertionManagerStopWithFailedReleaseDoesNotReportStoppedUntilRetryCompletes()
        try stoppedAssertionManagerDoesNotReacquireAssertions()
        try normalAssertionPolicyAvoidsDisplayAndDiskAssertions()
        try assertionManagerDefaultReconcileIntervalMeetsReleaseSLA()
        try controlRuntimeStoreCreatesPrivateDirectoryAndRotatingToken()
        try controlServerRejectsAuthReplayAndRateLimitFailures()
        try controlServerRateLimitsPerProcessAndTokenBackstop()
        try replayCacheExpiresOldEvents()
        try controlServerRejectsInvalidPauseDurations()
        try controlServerUsesReceiptTime()
        try cliParsesCommandsAndSendsThroughClient()
        try cliRejectsExtraArgumentsAndUnknownFlags()
        try localControlClientSendsThroughUnixSocket()
        try socketEndpointRejectsAuthReplayAndClientPIDRotation()
        try controlServerComponentRotatesTokenAndClearsRuntime()
        try hookAdapterMapsAndRedactsClaudePayload()
        try hookAdapterMapsAndRedactsCodexNativeHookPayloads()
        try hookAdapterUsesStableReplayIDForNativeToolEventsOnly()
        try hookAdapterResolvesAgentAncestorThroughShellShim()
        try hookAdapterNoOpsWhenAgentWakeIsUnavailable()
        try hookAdapterRoutesIntegrationEventsThroughControlServer()
        try integrationEventCanMoveProcessDetectedSessionToStandingBy()
        try claudePatcherPreservesExistingHooksAndRemovesOwnedHandlers()
        try codexPatcherPreservesExistingNotifyAndRestoresItOnRemoval()
        try codexPatcherHandlesMultilineAndSingleQuotedNotify()
        try configPatchersRejectInvalidEncodingAndPreserveMarkerLookalikes()
        try integrationManagerRecordsRemovalSuppressionAndStatus()
        try integrationManagerAppliesConfigPatchesAndRemovesThem()
        try integrationManagerSurfacesFailedInstallReasons()
        try settingsPersistWithExpectedSchema()
        try freshInstallSettingsCleanupClearsAutoInstallSuppressions()
        try corruptSettingsRecoverToDefaults()
        try unsupportedSchemaDoesNotRecoverAsCorrupt()
        try invalidSettingsAreRejected()
        try settingsExportExcludesLocalOnlyState()
        try logsRedactSensitiveFields()
        try logsEnforceRetention()

        print("AgentWakeCoreChecks passed")
    }

    private static func snapshotIncludesRuntimeDiagnostics() throws {
        let snapshot = MenuBarModel.snapshot(
            currentState: .idle,
            sessionSummary: "No sessions",
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "claude-code",
                    displayName: "Claude Code",
                    status: .installed
                )
            ]
        )

        let titles = snapshot.items.map(\.title)
        try check(titles.contains("No sessions"), "Expected session summary in menu")
        try check(titles.contains(ClosedLidModeAvailability.unavailableTitle), "Expected Closed-Lid Mode boundary in menu")
        try check(!titles.contains("Also keep 1 detected session awake"), "Expected protect action only when sessions are detected")
        try check(titles.contains("Turn On Lid-Closed Awake"), "Expected Closed-Lid Mode enable action in menu")
        try check(!titles.contains("Refresh"), "Expected refresh action to stay out of the menu")
        try check(titles.contains("Pause Sleep Protection"), "Expected menu to expose pause control")
        try check(!titles.contains("Claude Code: Installed"), "Expected installed integrations to stay out of the short menu")
        try check(!titles.contains("Reinstall agent hooks"), "Expected repair action only when an integration needs attention")

        let pausedSnapshot = MenuBarModel.snapshot(currentState: .paused, isSleepProtectionPaused: true)
        try check(pausedSnapshot.items.contains { $0.title == "Resume Sleep Protection" }, "Expected paused menu to expose resume control")

        let protectableSnapshot = MenuBarModel.snapshot(
            currentState: .idle,
            protectableDetectedSessionCount: 2
        )
        try check(
            protectableSnapshot.items.contains {
                $0.title == "Also keep 2 detected sessions awake" && $0.isEnabled
            },
            "Expected protect action to name the number of detected sessions"
        )

        let activeSnapshot = MenuBarModel.snapshot(
            currentState: .active,
            sessionSummary: "1 session kept awake; 2 detected"
        )
        try check(
            activeSnapshot.items.first?.title == "1 session kept awake; 2 detected",
            "Expected active menu status to include the protected session count"
        )
        try check(
            !activeSnapshot.items.contains { $0.title == "Stop Keeping Awake" },
            "Expected active menu to avoid a second sleep-control action"
        )

        let degradedSnapshot = MenuBarModel.snapshot(
            currentState: .idle,
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "codex-cli",
                    displayName: "Codex CLI",
                    status: .failed
                )
            ]
        )
        let degradedTitles = degradedSnapshot.items.map(\.title)
        try check(degradedTitles.contains("Codex CLI: Needs repair"), "Expected broken integration to be visible")
        try check(degradedTitles.contains("Reinstall agent hooks"), "Expected repair action for broken integration")
    }

    private static func snapshotNamesTheCurrentState() throws {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        try check(snapshot.currentState == .bagMode, "Expected Closed-Lid Mode as current state")
        try check(snapshot.statusItemAccessibilityTitle == "AgentWake", "Expected stable status item accessibility title")
        try check(snapshot.statusItemIcon.baseSystemImageName == "moon", "Expected Closed-Lid Mode status icon")
        try check(snapshot.statusItemIcon.tint == .unknown, "Expected unavailable status icon tint")
        try check(
            snapshot.items.first?.title == ClosedLidModeAvailability.unavailableTitle,
            "Expected current-state menu row"
        )
        try check(snapshot.items.first?.detail == ClosedLidModeAvailability.settingsDetail, "Expected Closed-Lid Mode unavailable detail")

        let closedLidStatus = ClosedLidModeStatus(pendingGates: [.helperLifecycle, .temperatureProvider])
        try check(!closedLidStatus.isAvailable, "Expected pending gates to keep Closed-Lid Mode unavailable")
        try check(closedLidStatus.summary == "Blocked by 2 checks.", "Expected pending check count in Closed-Lid Mode summary")
        try check(
            closedLidStatus.commandMessage("status").contains("- Temperature provider:"),
            "Expected Closed-Lid Mode status to name pending provider gate"
        )
    }

    private static func snapshotUsesGlanceableStatusIcons() throws {
        let idle = MenuBarModel.snapshot(currentState: .idle)
        try check(idle.statusItemIcon.baseSystemImageName == "moon.fill", "Expected idle moon status icon")
        try check(idle.statusItemIcon.tint == .secondary, "Expected idle status icon tint")

        let active = MenuBarModel.snapshot(currentState: .active)
        try check(active.statusItemIcon.baseSystemImageName == "bolt.fill", "Expected active status icon")
        try check(active.statusItemIcon.overlaySystemImageName == nil, "Expected no lock overlay when Lid-Closed Awake is off")
        try check(active.statusItemIcon.tint == .accent, "Expected active status icon tint")

        let activeWithClosedLid = MenuBarModel.snapshot(
            currentState: .active,
            closedLidStatus: .enabledByAgentWake
        )
        try check(activeWithClosedLid.statusItemIcon.baseSystemImageName == "bolt.fill", "Expected active status icon with Lid-Closed Awake on")
        try check(activeWithClosedLid.statusItemIcon.overlaySystemImageName == "lock.fill", "Expected lock overlay when Lid-Closed Awake is on")

        let paused = MenuBarModel.snapshot(currentState: .paused)
        try check(paused.statusItemIcon.baseSystemImageName == "exclamationmark.triangle.fill", "Expected paused warning status icon")
        try check(paused.statusItemIcon.tint == .warning, "Expected paused warning tint")

        let outsideClosedLidOwner = MenuBarModel.snapshot(
            currentState: .idle,
            closedLidStatus: .enabledByOther,
            takeClosedLidOwnershipEnabled: true
        )
        let outsideTitles = outsideClosedLidOwner.items.map(\.title)
        try check(outsideTitles.contains("Lid-closed sleep is disabled by another tool"), "Expected user-facing outside-owner copy")
        try check(!outsideTitles.contains { $0.contains("Outside AgentWake") }, "Expected bookkeeping copy to stay out of the menu")
        try check(outsideTitles.contains("Take Ownership..."), "Expected takeover action for externally disabled lid sleep")
    }

    private static func closedLidModeControllerEnablesAndRestoresPrimitive() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }
        let runner = RecordingClosedLidModeCommandRunner(initialValue: 0)
        let controller = ClosedLidModeController(
            paths: paths,
            commandRunner: runner,
            now: { Date(timeIntervalSince1970: 123) }
        )

        let currentDisablesleep = try controller.currentDisablesleepValue()
        try check(currentDisablesleep == 0, "Expected Closed-Lid controller to expose the current restore value before prompting")

        let enabled = try controller.enable()
        try check(enabled.contains("SleepDisabled=1"), "Expected enable message to report SleepDisabled=1")
        try check(runner.setValues == [1], "Expected enable to set disablesleep=1")
        try check(FileManager.default.fileExists(atPath: paths.closedLidModeStateURL.path), "Expected enable to record restore state")

        let status = controller.statusMessage()
        try check(status.contains("Closed-Lid Mode enabled"), "Expected status to report enabled state")
        try check(status.contains("Restore value=0"), "Expected status to report restore value")

        let disabled = try controller.disable()
        try check(disabled.contains("SleepDisabled=0"), "Expected disable message to report restore value")
        try check(runner.setValues == [1, 0], "Expected disable to restore previous disablesleep value")
        try check(!FileManager.default.fileExists(atPath: paths.closedLidModeStateURL.path), "Expected disable to remove restore state")

        let externalRunner = RecordingClosedLidModeCommandRunner(initialValue: 1)
        let externalController = ClosedLidModeController(paths: paths, commandRunner: externalRunner)
        do {
            _ = try externalController.disable()
            throw CheckFailure("Expected disable to reject externally owned disablesleep=1")
        } catch ClosedLidModeError.notAgentWakeOwned {
            try check(externalRunner.setValues.isEmpty, "Expected externally owned state to remain unchanged")
        }

        let pendingPaths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: pendingPaths.applicationSupportDirectory) }
        let pendingState = ClosedLidModeState(
            previousDisablesleep: 0,
            enabledAt: Date(timeIntervalSince1970: 222),
            phase: .pending
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: pendingPaths.closedLidModeStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(pendingState).write(to: pendingPaths.closedLidModeStateURL, options: .atomic)
        let pendingRunner = RecordingClosedLidModeCommandRunner(initialValue: 1)
        let pendingController = ClosedLidModeController(paths: pendingPaths, commandRunner: pendingRunner)
        do {
            _ = try pendingController.disable()
            throw CheckFailure("Expected pending ownership to reject externally enabled disablesleep=1")
        } catch ClosedLidModeError.notAgentWakeOwned {
            try check(pendingRunner.setValues.isEmpty, "Expected pending state not to restore externally held value")
        }

        let failingStatus = ClosedLidModeController(
            paths: paths,
            commandRunner: RecordingClosedLidModeCommandRunner(initialValue: 0, readError: ClosedLidModeError.pmsetFailed("pmset failed"))
        )
        try check(
            failingStatus.statusMessage().contains("Closed-Lid Mode status unknown"),
            "Expected status read failure to be visible"
        )

        let failingPaths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: failingPaths.applicationSupportDirectory) }
        let failingRunner = RecordingClosedLidModeCommandRunner(
            initialValue: 0,
            setError: ClosedLidModeError.authorizationFailed("operator cancelled")
        )
        let failingController = ClosedLidModeController(paths: failingPaths, commandRunner: failingRunner)
        do {
            _ = try failingController.enable()
            throw CheckFailure("Expected enable to propagate set failure")
        } catch ClosedLidModeError.authorizationFailed {
            try check(failingRunner.setValues == [1], "Expected enable to attempt disablesleep=1")
            try check(
                !FileManager.default.fileExists(atPath: failingPaths.closedLidModeStateURL.path),
                "Expected failed enable to remove provisional restore state"
            )
        }
    }

    private static func stateDerivesFromHoldState() throws {
        try check(
            AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])) == .idle,
            "Expected idle hold state to derive Idle"
        )
        try check(
            AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])) == .active,
            "Expected held session to derive active"
        )
        try check(
            AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isPaused: true)) == .paused,
            "Expected pause to derive Paused"
        )
        try check(
            AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isSafetyCutoffActive: true)) == .paused,
            "Expected safety cutoff to derive Paused"
        )
    }

    private static func lifecycleComponentsCanStartAndStopTogether() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let services = AgentWakeServices(paths: paths)

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
        let detector = AgentProcessDetector(settings: AgentWakeSettings())
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

        var disabledCodexSettings = AgentWakeSettings()
        if let index = disabledCodexSettings.agents.firstIndex(where: { $0.id == "codex-cli" }) {
            disabledCodexSettings.agents[index].isEnabled = false
        }
        let disabledCodexObservations = AgentProcessDetector(settings: disabledCodexSettings).observations(
            in: [
                ProcessSnapshot(
                    pid: 13,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                )
            ]
        )
        try check(disabledCodexObservations.isEmpty, "Expected disabled agent config to suppress process detection")
    }

    private static func processDetectorExcludesCodexAppServerProcesses() throws {
        let detector = AgentProcessDetector(settings: AgentWakeSettings())
        let observations = detector.observations(
            in: [
                ProcessSnapshot(
                    pid: 16,
                    processName: "Codex",
                    executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 17,
                    parentPID: 16,
                    processName: "codex",
                    executablePath: "/Applications/Codex.app/Contents/Resources/codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 18,
                    parentPID: 99,
                    processName: "codex",
                    executablePath: "/Applications/Codex.app/Contents/Resources/codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 19,
                    processName: "codex",
                    executablePath: "/Users/tester/.vscode/extensions/openai.chatgpt-1.0/bin/macos-aarch64/codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                ),
                ProcessSnapshot(
                    pid: 20,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: Date(timeIntervalSince1970: 1)
                )
            ]
        )

        try check(
            observations.map(\.snapshot.pid) == [17, 20],
            "Expected Codex detection to include the primary desktop app-server but exclude helper app-servers"
        )
    }

    private static func agentMonitorSummarizesParallelSessions() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let monitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(
                snapshotsToReturn: [
                    ProcessSnapshot(
                        pid: 21,
                        processName: "claude",
                        executablePath: "/opt/homebrew/bin/claude",
                        processStartTime: now
                    ),
                    ProcessSnapshot(
                        pid: 22,
                        processName: "claude",
                        executablePath: "/opt/homebrew/Caskroom/claude-code/latest/claude",
                        processStartTime: now
                    ),
                    ProcessSnapshot(
                        pid: 23,
                        processName: "claude-code",
                        executablePath: "/usr/local/bin/claude-code",
                        processStartTime: now
                    )
                ]
            ),
            settingsProvider: { AgentWakeSettings() },
            now: { now }
        )

        monitor.poll()
        try check(monitor.visibleSessions.count == 3, "Expected parallel agent processes to remain distinct")
        try check(
            monitor.sessionSummaryMessage() == "3 sessions detected",
            "Expected process-only matches to stay diagnostic instead of claiming confirmed protection"
        )

        monitor.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .claudeCode,
                host: "claude-code",
                event: .toolStarted,
                pid: 23,
                processStartTime: now,
                integrationSessionId: "claude-turn-1"
            ),
            at: now.addingTimeInterval(1)
        )
        try check(
            monitor.sessionSummaryMessage() == "1 session kept awake; 2 detected",
            "Expected integration-backed activity to protect while process-only sessions remain detected: \(monitor.sessionSummaryMessage())"
        )

        var disabledClaudeSettings = AgentWakeSettings()
        if let index = disabledClaudeSettings.agents.firstIndex(where: { $0.id == "claude-code" }) {
            disabledClaudeSettings.agents[index].isEnabled = false
        }
        let disabledMonitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(snapshotsToReturn: []),
            settingsProvider: { disabledClaudeSettings },
            now: { now }
        )
        disabledMonitor.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .claudeCode,
                host: "claude-code",
                event: .toolStarted,
                pid: 24,
                processStartTime: now,
                integrationSessionId: "disabled-claude"
            ),
            at: now.addingTimeInterval(1)
        )
        try check(disabledMonitor.sessions.isEmpty, "Expected disabled agent config to ignore hook events")
    }

    private static func processOnlyDetectionsRemainDiagnosticUntilIntegrated() throws {
        var currentDate = Date(timeIntervalSince1970: 2_000)
        let monitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(
                snapshotsToReturn: [
                    ProcessSnapshot(
                        pid: 31,
                        processName: "claude",
                        executablePath: "/opt/homebrew/bin/claude",
                        processStartTime: currentDate.addingTimeInterval(-300)
                    ),
                    ProcessSnapshot(
                        pid: 32,
                        processName: "codex",
                        executablePath: "/opt/homebrew/bin/codex",
                        processStartTime: currentDate.addingTimeInterval(-60)
                    ),
                    ProcessSnapshot(
                        pid: 33,
                        processName: "claude",
                        executablePath: "/usr/local/bin/claude-code",
                        processStartTime: currentDate.addingTimeInterval(-180)
                    )
                ]
            ),
            settingsProvider: { AgentWakeSettings(defaultGraceSeconds: 900) },
            now: { currentDate }
        )

        monitor.poll()
        try check(
            monitor.sessionSummaryMessage() == "3 sessions detected",
            "Expected process-only detections to remain diagnostic until hook evidence arrives: \(monitor.sessionSummaryMessage())"
        )
        try check(
            monitor.sessionOverviewMessage().contains("Codex CLI: detected"),
            "Expected settings overview to hide process diagnostics: \(monitor.sessionOverviewMessage())"
        )
        try check(
            monitor.sessionListMessage().contains("Codex CLI: detected source=processScan pid=32"),
            "Expected process-only detection to be labeled detected: \(monitor.sessionListMessage())"
        )

        currentDate = currentDate.addingTimeInterval(901)
        try check(
            monitor.sessionSummaryMessage() == "3 sessions detected",
            "Expected process-only detections to stay diagnostic without hook evidence: \(monitor.sessionSummaryMessage())"
        )
    }

    private static func sessionOverviewCombinesAgentStateBuckets() throws {
        let currentDate = Date(timeIntervalSince1970: 2_100)
        let firstProcessStart = currentDate.addingTimeInterval(-30)
        let monitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(
                snapshotsToReturn: [
                    ProcessSnapshot(
                        pid: 41,
                        processName: "claude",
                        executablePath: "/opt/homebrew/bin/claude",
                        processStartTime: firstProcessStart
                    ),
                    ProcessSnapshot(
                        pid: 42,
                        processName: "claude",
                        executablePath: "/opt/homebrew/bin/claude",
                        processStartTime: currentDate.addingTimeInterval(-60)
                    ),
                    ProcessSnapshot(
                        pid: 43,
                        processName: "claude",
                        executablePath: "/usr/local/bin/claude-code",
                        processStartTime: currentDate.addingTimeInterval(-90)
                    )
                ]
            ),
            settingsProvider: { AgentWakeSettings(defaultGraceSeconds: 900) },
            now: { currentDate }
        )

        monitor.poll()
        monitor.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .claudeCode,
                host: "claude-code",
                event: .toolStarted,
                pid: 41,
                processStartTime: firstProcessStart,
                integrationSessionId: "claude-active"
            ),
            at: currentDate.addingTimeInterval(1)
        )

        let overview = monitor.sessionOverviewMessage()
        try check(
            overview == "Claude Code: keeping awake, 2 detected",
            "Expected one Claude Code row with combined states, got: \(overview)"
        )
        try check(
            overview.components(separatedBy: "Claude Code:").count == 2,
            "Expected Claude Code to appear only once, got: \(overview)"
        )
        let detail = monitor.sessionDetailMessage()
        try check(detail.contains("Claude Code (3)"), "Expected detailed session list to group by agent: \(detail)")
        try check(detail.contains("41  processScan"), "Expected detailed session list to include PID and source: \(detail)")
        try check(detail.contains("toolStarted"), "Expected detailed session list to include last event: \(detail)")
    }

    private static func processOnlyDetectionDoesNotProtectWithoutIntegration() throws {
        let baseline = Date(timeIntervalSince1970: 2_500)
        let machine = AgentSessionStateMachine(graceInterval: 900)
        let processObservation = observation(
            pid: 34,
            start: baseline.addingTimeInterval(-30),
            path: "/opt/homebrew/bin/claude",
            agent: .claudeCode
        )

        machine.applyProcessObservations([processObservation], at: baseline)
        try check(machine.sessions.first?.id != nil, "Expected process-backed session")
        try check(!machine.aggregateHoldState(at: baseline).shouldHold, "Expected process-only detection not to protect")

        machine.applyProcessObservations([processObservation], at: baseline.addingTimeInterval(2))
        try check(
            !machine.aggregateHoldState(at: baseline.addingTimeInterval(2)).shouldHold,
            "Expected process-only session not to protect on the next poll"
        )

        let protectedCount = machine.protectDetectedProcessSessions(at: baseline.addingTimeInterval(3))
        try check(protectedCount == 1, "Expected manual action to protect one detected process")
        try check(
            machine.aggregateHoldState(at: baseline.addingTimeInterval(3)).shouldHold,
            "Expected manual protection to hold while the process remains open"
        )
        try check(
            machine.sessions.first?.lastEvent?.kind == .manualProtectDetected,
            "Expected manual protection event to be recorded"
        )

        machine.applyProcessObservations([], at: baseline.addingTimeInterval(4))
        try check(
            !machine.aggregateHoldState(at: baseline.addingTimeInterval(4)).shouldHold,
            "Expected manually protected detected session to release when the process exits"
        )
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
            settingsProvider: { AgentWakeSettings() },
            now: { now }
        )

        try check(monitor.pollInterval == 2, "Expected default process polling interval to be two seconds")
        try check(monitor.lastPollAt == nil, "Expected last poll timestamp to be empty before polling")
        monitor.poll()
        try check(monitor.lastPollAt == now, "Expected manual poll to record last poll timestamp")
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
            settingsProvider: { AgentWakeSettings() },
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

        machine.applyProcessObservations(
            [observation(pid: 42, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode)],
            at: baseline
        )
        let firstSessionID = try checkNotNil(machine.sessions.first?.id, "Expected initial process session")
        try check(machine.sessions.first?.state == .active, "Expected matching process start to create an active session")
        try check(!machine.aggregateHoldState(at: baseline).shouldHold, "Expected process-only session not to protect")
        try check(
            !machine.aggregateHoldState(at: baseline.addingTimeInterval(901)).shouldHold,
            "Expected process-only session to remain diagnostic without integration evidence"
        )
        machine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .claudeCode,
                host: "claude-code",
                event: .toolStarted,
                pid: 42,
                processStartTime: baseline,
                integrationSessionId: "claude-session-42"
            ),
            at: baseline.addingTimeInterval(1)
        )
        try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(1)).shouldHold, "Expected integration-backed session to hold")

        machine.applyProcessObservations(
            [observation(pid: 42, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode, cpuPercent: 80)],
            at: baseline.addingTimeInterval(30)
        )
        try check(machine.sessions.count == 1, "Expected pid/start/path identity to dedupe")
        try check(machine.sessions[0].id == firstSessionID, "Expected deduped observation to keep session id")
        try check(machine.sessions[0].lastActivityAt == baseline.addingTimeInterval(1), "Expected process polling not to reset integration activity")

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
        machine.applyProcessObservations(
            [observation(pid: 42, start: restartedAt, path: "/opt/homebrew/bin/claude", agent: .claudeCode)],
            at: restartedAt
        )
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
        machine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .claudeCode,
                host: "claude-code",
                event: .toolStarted,
                pid: 42,
                processStartTime: restartedAt,
                integrationSessionId: "claude-session-43"
            ),
            at: restartedAt.addingTimeInterval(1)
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

        machine.applyProcessObservations(
            [observation(pid: 42, start: restartedAt)],
            at: restartedAt.addingTimeInterval(1_812)
        )
        try check(
            machine.sessions.filter { $0.state == .active }.count == 1,
            "Expected a re-observed live process to create a fresh active session instead of updating a finished one"
        )
    }

    private static func pathLookupVolatilityDoesNotSplitSessions() throws {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let machine = AgentSessionStateMachine()

        machine.applyProcessObservations(
            [observationWithMissingPath(pid: 43, start: baseline, processName: "claude", agent: .claudeCode)],
            at: baseline
        )
        let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected fallback process session")
        machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
        let expiry = try checkNotNil(machine.sessions.first?.standingByExpiresAt, "Expected standing-by expiry")

        machine.applyProcessObservations(
            [observation(pid: 43, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode)],
            at: baseline.addingTimeInterval(20)
        )

        try check(machine.sessions.count == 1, "Expected path hash upgrade not to split the same pid/start process")
        try check(machine.sessions[0].id == sessionID, "Expected path hash upgrade to preserve session identity")
        try check(machine.sessions[0].state == .standingBy, "Expected path hash upgrade not to reactivate the session")
        try check(machine.sessions[0].standingByExpiresAt == expiry, "Expected path hash upgrade not to reset grace")
        try check(machine.sessions[0].key.executablePathHash == StablePathHash.sha256("/opt/homebrew/bin/claude"), "Expected verified path hash to upgrade")
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

        machine.applyProcessObservations(
            [observation(pid: 60, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode, cpuPercent: 5)],
            at: baseline
        )
        let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected active CPU diagnostic session")
        machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
        let originalExpiry = try checkNotNil(machine.sessions[0].standingByExpiresAt, "Expected standing-by expiry")

        machine.applyProcessObservations(
            [observation(pid: 60, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode, cpuPercent: 95)],
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
        machine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .claudeCode,
                host: "claude-code",
                event: .toolStarted,
                pid: 80,
                processStartTime: baseline,
                integrationSessionId: "claude-session"
            ),
            at: baseline.addingTimeInterval(1)
        )
        machine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .codexCLI,
                host: "codex-cli",
                event: .toolStarted,
                pid: 81,
                processStartTime: baseline,
                integrationSessionId: "codex-session"
            ),
            at: baseline.addingTimeInterval(2)
        )

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

    private static func bagModeSafetyPolicyCoversWarningCutoffFailClosedAndHysteresis() throws {
        let now = Date(timeIntervalSince1970: 4_500)
        let policy = BagModeSafetyPolicy(
            settings: SafetySettings(
                temperatureWarningCelsius: 85,
                temperatureCutoffCelsius: 95,
                batteryFloorPercent: 15
            )
        )

        let warning = policy.evaluate(
            input: safetyInput(temperature: 86, battery: 80, now: now),
            isBagModeArmed: false
        )
        try check(warning.state.mode == .warning, "Expected warning temperature to enter warning mode")
        try check(warning.action == .warn, "Expected warning temperature to warn without cutting off")
        try check(warning.canArmBagMode, "Expected warning state to remain armable below cutoff")

        let supplementalWarning = policy.evaluate(
            input: safetyInput(temperature: 60, pressure: .serious, battery: 80, now: now),
            isBagModeArmed: false
        )
        try check(supplementalWarning.state.mode == .warning, "Expected app thermal pressure to be supplemental warning")
        try check(supplementalWarning.action == .warn, "Expected app thermal pressure not to be sole cutoff source")
        try check(supplementalWarning.canArmBagMode, "Expected app thermal pressure warning not to veto arming by itself")

        let thermalPressureCutoff = policy.evaluate(
            input: safetyInput(temperature: 60, pressure: .critical, battery: 80, now: now),
            isBagModeArmed: true
        )
        try check(thermalPressureCutoff.state.cutoffReason == .temperature, "Expected critical app thermal pressure to cut off")
        try check(thermalPressureCutoff.action == .releaseIfArmed, "Expected critical app thermal pressure to release")

        let temperatureCutoff = policy.evaluate(
            input: safetyInput(temperature: 96, battery: 80, now: now),
            isBagModeArmed: true
        )
        try check(temperatureCutoff.state.mode == .cutoffLockedOut, "Expected cutoff temperature to lock out")
        try check(temperatureCutoff.state.cutoffReason == .temperature, "Expected temperature cutoff reason")
        try check(temperatureCutoff.action == .releaseIfArmed, "Expected armed Closed-Lid Mode to release on cutoff")

        let batteryCutoff = policy.evaluate(
            input: safetyInput(temperature: 70, battery: 15, now: now),
            isBagModeArmed: true
        )
        try check(batteryCutoff.state.cutoffReason == .battery, "Expected battery floor cutoff")

        let stale = policy.evaluate(
            input: BagModeSafetyInput(
                temperature: .sample(
                    BagModeTemperatureSample(
                        celsius: 70,
                        capturedAt: now.addingTimeInterval(-11),
                        coversClosedBagRisk: true
                    )
                ),
                batteryPercent: 80,
                now: now
            ),
            isBagModeArmed: false
        )
        try check(stale.state.cutoffReason == .staleSensor, "Expected stale readings to fail closed")
        try check(stale.action == .failClosedBeforeArming, "Expected unarmed stale readings to block arming")

        let malformedSamples = [
            BagModeTemperatureSample(celsius: .nan, capturedAt: now),
            BagModeTemperatureSample(celsius: .infinity, capturedAt: now),
            BagModeTemperatureSample(celsius: 70, capturedAt: now.addingTimeInterval(1))
        ]
        for malformedSample in malformedSamples {
            let decision = policy.evaluate(
                input: BagModeSafetyInput(
                    temperature: .sample(malformedSample),
                    batteryPercent: 80,
                    now: now
                ),
                isBagModeArmed: true
            )
            try check(decision.state.cutoffReason == .parseFailed, "Expected malformed temperature samples to fail closed")
            try check(decision.action == .releaseIfArmed, "Expected malformed temperature samples to release armed Closed-Lid Mode")
        }

        let failClosedReadings: [(BagModeTemperatureReading, BagModeSafetyCutoffReason)] = [
            (.unavailable, .unavailableSensor),
            (.permissionDenied, .permissionDenied),
            (.parseFailed, .parseFailed),
            (.helperCrashed, .helperCrashed),
            (.unsupportedHardware, .unsupportedHardware),
            (.timedOut, .timedOut)
        ]
        for (reading, reason) in failClosedReadings {
            let decision = policy.evaluate(
                input: BagModeSafetyInput(temperature: reading, batteryPercent: 80, now: now),
                isBagModeArmed: true
            )
            try check(decision.state.cutoffReason == reason, "Expected \(reason.rawValue) to fail closed")
            try check(decision.action == .releaseIfArmed, "Expected \(reason.rawValue) to release armed Closed-Lid Mode")
        }

        let coverage = policy.evaluate(
            input: BagModeSafetyInput(
                temperature: .sample(
                    BagModeTemperatureSample(
                        celsius: 70,
                        capturedAt: now,
                        coversClosedBagRisk: false
                    )
                ),
                batteryPercent: 80,
                now: now
            ),
            isBagModeArmed: true
        )
        try check(coverage.state.cutoffReason == .coverageInsufficient, "Expected unsupported thermal coverage to fail closed")

        let missingBattery = policy.evaluate(
            input: BagModeSafetyInput(
                temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now)),
                batteryPercent: nil,
                now: now
            ),
            isBagModeArmed: false
        )
        try check(missingBattery.state.cutoffReason == .batteryUnavailable, "Expected missing battery reading to fail closed")

        let invalidBattery = policy.evaluate(
            input: safetyInput(temperature: 70, battery: 999, now: now),
            isBagModeArmed: true
        )
        try check(invalidBattery.state.cutoffReason == .batteryInvalid, "Expected out-of-range battery reading to fail closed")
        try check(invalidBattery.action == .releaseIfArmed, "Expected invalid battery reading to release armed Closed-Lid Mode")

        let locked = BagModeSafetyState(
            mode: .cutoffLockedOut,
            cutoffReason: .temperature,
            cutoffAt: now.addingTimeInterval(-60)
        )
        let stillLocked = policy.evaluate(
            previous: locked,
            input: safetyInput(temperature: 86, battery: 21, now: now),
            isBagModeArmed: false
        )
        try check(stillLocked.state.mode == .cutoffLockedOut, "Expected hysteresis to keep lockout until temperature recovers enough")

        let rearmEligible = policy.evaluate(
            previous: locked,
            input: safetyInput(temperature: 84, battery: 20, now: now),
            isBagModeArmed: false
        )
        try check(rearmEligible.state.mode == .rearmEligible, "Expected recovered temperature and battery to become rearm eligible")
        try check(rearmEligible.canArmBagMode, "Expected rearm eligible state to allow arming")

        let recoveredButStillArmed = policy.evaluate(
            previous: locked,
            input: safetyInput(temperature: 84, battery: 20, now: now),
            isBagModeArmed: true
        )
        try check(recoveredButStillArmed.state.mode == .cutoffLockedOut, "Expected lockout to stay active until Closed-Lid Mode is observed disarmed")
        try check(recoveredButStillArmed.action == .releaseIfArmed, "Expected recovered but still armed lockout to keep requesting release")

        let rearmed = policy.evaluate(
            previous: rearmEligible.state,
            input: safetyInput(temperature: 70, battery: 80, now: now),
            isBagModeArmed: true
        )
        try check(rearmed.state.mode == .normal, "Expected re-arm to clear rearm eligible state")

        let rearmedWarning = policy.evaluate(
            previous: rearmEligible.state,
            input: safetyInput(temperature: 86, battery: 80, now: now),
            isBagModeArmed: true
        )
        try check(rearmedWarning.state.mode == .warning, "Expected re-armed warning input to remain warning")
    }

    private static func closedLidSafetyMonitorReleasesOnCutoff() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let runner = RecordingClosedLidModeCommandRunner(initialValue: 0)
        let controller = ClosedLidModeController(
            paths: paths,
            commandRunner: runner,
            now: { Date(timeIntervalSince1970: 5_000) }
        )
        _ = try controller.enable()

        let settings = AgentWakeSettings(
            safety: SafetySettings(
                temperatureWarningCelsius: 85,
                temperatureCutoffCelsius: 95,
                batteryFloorPercent: 15
            )
        )
        let monitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(snapshotsToReturn: []),
            settingsProvider: { settings },
            now: { Date(timeIntervalSince1970: 5_001) }
        )
        let assertionController = RecordingPowerAssertionController()
        let assertionManager = AssertionManager(
            controller: assertionController,
            holdStateProvider: { monitor.aggregateHoldState }
        )
        let logStore = LogStore(paths: paths, now: { Date(timeIntervalSince1970: 5_001) })
        logStore.start()

        let safetyMonitor = ClosedLidSafetyMonitor(
            settingsProvider: { settings },
            closedLidModeController: controller,
            agentMonitor: monitor,
            assertionManager: assertionManager,
            logStore: logStore,
            batteryPercentProvider: { 10 },
            thermalPressureProvider: { .nominal },
            now: { Date(timeIntervalSince1970: 5_001) }
        )

        safetyMonitor.evaluateNow()
        try check(runner.setValues == [1, 0], "Expected safety monitor to restore disablesleep after battery cutoff")
        try check(!controller.isAgentWakeOwnedEnabled(), "Expected safety release to remove AgentWake-owned Closed-Lid Mode")
        try check(monitor.aggregateHoldState.isSafetyCutoffActive, "Expected safety cutoff to suppress further assertions")
        try check(logStore.events.contains { $0.kind == .safetyCutoff && $0.metadata["cutoff"] == "battery" }, "Expected safety cutoff event to be logged")

        let unarmedMonitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(snapshotsToReturn: []),
            settingsProvider: { settings },
            now: { Date(timeIntervalSince1970: 5_002) }
        )
        let unarmedAssertionManager = AssertionManager(holdStateProvider: { unarmedMonitor.aggregateHoldState })
        let unarmedSafetyMonitor = ClosedLidSafetyMonitor(
            settingsProvider: { settings },
            closedLidModeController: controller,
            agentMonitor: unarmedMonitor,
            assertionManager: unarmedAssertionManager,
            logStore: logStore,
            batteryPercentProvider: { nil },
            thermalPressureProvider: { .nominal },
            now: { Date(timeIntervalSince1970: 5_002) }
        )
        unarmedSafetyMonitor.evaluateNow()
        try check(!unarmedMonitor.aggregateHoldState.isSafetyCutoffActive, "Expected missing battery while unarmed not to suppress normal sleep protection")
    }

    private static func bagModeSafetyDiagnosticsCoverUserFacingProviderStates() throws {
        let now = Date(timeIntervalSince1970: 4_600)
        let policy = BagModeSafetyPolicy()

        let allow = policy.evaluate(
            input: safetyInput(temperature: 70, battery: 80, now: now),
            isBagModeArmed: false
        )
        try check(BagModeSafetyDiagnostic.userFacing(for: allow) == nil, "Expected normal safety state to have no diagnostic")

        let warning = policy.evaluate(
            input: safetyInput(temperature: 86, battery: 80, now: now),
            isBagModeArmed: false
        )
        let warningDiagnostic = try checkNotNil(
            BagModeSafetyDiagnostic.userFacing(for: warning),
            "Expected warning state to have a diagnostic"
        )
        try check(warningDiagnostic.title.contains("warning"), "Expected warning diagnostic title")
        try check(warningDiagnostic.recoveryAction != nil, "Expected warning diagnostic recovery action")

        let supplementalWarning = policy.evaluate(
            input: safetyInput(temperature: 60, pressure: .serious, battery: 80, now: now),
            isBagModeArmed: false
        )
        let supplementalWarningDiagnostic = try checkNotNil(
            BagModeSafetyDiagnostic.userFacing(for: supplementalWarning),
            "Expected supplemental thermal pressure warning to have a diagnostic"
        )
        try check(
            !supplementalWarningDiagnostic.title.localizedCaseInsensitiveContains("temperature is elevated"),
            "Expected supplemental warning copy not to claim numeric temperature is elevated"
        )

        let failureCases: [(String, BagModeSafetyInput, BagModeSafetyAction, String)] = [
            (
                "temperature",
                safetyInput(temperature: 96, battery: 80, now: now),
                .failClosedBeforeArming,
                "temperature cutoff"
            ),
            (
                "battery",
                safetyInput(temperature: 70, battery: 15, now: now),
                .failClosedBeforeArming,
                "battery"
            ),
            (
                "stale",
                BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now.addingTimeInterval(-11))),
                    batteryPercent: 80,
                    now: now
                ),
                .failClosedBeforeArming,
                "stale"
            ),
            (
                "unavailable",
                BagModeSafetyInput(temperature: .unavailable, batteryPercent: 80, now: now),
                .failClosedBeforeArming,
                "unavailable"
            ),
            (
                "permission",
                BagModeSafetyInput(temperature: .permissionDenied, batteryPercent: 80, now: now),
                .failClosedBeforeArming,
                "permission"
            ),
            (
                "parse",
                BagModeSafetyInput(temperature: .parseFailed, batteryPercent: 80, now: now),
                .failClosedBeforeArming,
                "parsed"
            ),
            (
                "helper",
                BagModeSafetyInput(temperature: .helperCrashed, batteryPercent: 80, now: now),
                .releaseIfArmed,
                "helper"
            ),
            (
                "unsupported",
                BagModeSafetyInput(temperature: .unsupportedHardware, batteryPercent: 80, now: now),
                .failClosedBeforeArming,
                "unsupported"
            ),
            (
                "timeout",
                BagModeSafetyInput(temperature: .timedOut, batteryPercent: 80, now: now),
                .releaseIfArmed,
                "timed out"
            ),
            (
                "coverage",
                BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now, coversClosedBagRisk: false)),
                    batteryPercent: 80,
                    now: now
                ),
                .failClosedBeforeArming,
                "coverage"
            ),
            (
                "battery unavailable",
                BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now)),
                    batteryPercent: nil,
                    now: now
                ),
                .failClosedBeforeArming,
                "battery"
            ),
            (
                "battery invalid",
                safetyInput(temperature: 70, battery: 999, now: now),
                .releaseIfArmed,
                "battery"
            )
        ]

        for (label, input, expectedAction, expectedTitleFragment) in failureCases {
            let decision = policy.evaluate(input: input, isBagModeArmed: expectedAction == .releaseIfArmed)
            try check(decision.action == expectedAction, "Expected \(label) diagnostic case to use \(expectedAction.rawValue)")

            let diagnostic = try checkNotNil(
                BagModeSafetyDiagnostic.userFacing(for: decision),
                "Expected \(label) to have a diagnostic"
            )
            try check(
                diagnostic.title.localizedCaseInsensitiveContains(expectedTitleFragment),
                "Expected \(label) diagnostic title to explain the reason"
            )
            try check(!diagnostic.detail.isEmpty, "Expected \(label) diagnostic detail")
            try check(diagnostic.recoveryAction?.isEmpty == false, "Expected \(label) diagnostic recovery action")
        }
    }

    private static func powerSourceReaderParsesPmsetBatteryOutput() throws {
        let batteryOutput = """
        Now drawing from 'Battery Power'
         -InternalBattery-0 (id=1234567)\t82%; discharging; 5:12 remaining present: true
        """
        let acOutput = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=1234567)\t82%; charging; 1:03 remaining present: true
        """

        try check(PowerSourceReader.parse(pmsetBatteryOutput: batteryOutput) == .battery, "Expected pmset battery output to parse as battery")
        try check(PowerSourceReader.parse(pmsetBatteryOutput: acOutput) == .ac, "Expected pmset AC output to parse as AC")
        try check(PowerSourceReader.parse(pmsetBatteryOutput: "No power source") == .unknown, "Expected unknown pmset output to stay unknown")
        try check(PowerSourceReader.parseBatteryPercent(pmsetBatteryOutput: batteryOutput) == 82, "Expected battery percent parser to extract pmset percentage")
        try check(PowerSourceReader.parseBatteryPercent(pmsetBatteryOutput: "No power source") == nil, "Expected missing battery percent to stay nil")
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

    private static func outOfOrderHookEventsAreIgnored() throws {
        let baseline = Date(timeIntervalSince1970: 4_000)
        let machine = AgentSessionStateMachine(graceInterval: 900)
        let processStart = baseline.addingTimeInterval(-60)
        let sessionID = "codex-turn-1"

        machine.applyIntegrationEvent(
            hookEvent(.turnStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(20)
        )
        try check(machine.sessions.count == 1, "Expected hook start to create one integration session")
        try check(machine.sessions[0].state == .active, "Expected hook start to make the session active")

        machine.applyIntegrationEvent(
            hookEvent(.turnFinished, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(10)
        )
        try check(machine.sessions[0].state == .active, "Expected stale turnFinished hook not to move active session backward")

        machine.applyIntegrationEvent(
            hookEvent(.turnFinished, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(30)
        )
        try check(machine.sessions[0].state == .finished, "Expected current Codex Stop hook to finish the turn")
        try check(machine.sessions[0].standingByExpiresAt == nil, "Expected Codex Stop not to keep a grace hold")

        machine.applyIntegrationEvent(
            hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(25)
        )
        try check(machine.sessions[0].state == .finished, "Expected stale toolStarted hook not to reactivate the finished Codex turn")

        machine.applyIntegrationEvent(
            hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(40)
        )
        try check(machine.sessions[0].state == .finished, "Expected late toolStarted hook after Codex Stop not to reactivate")

        machine.applyIntegrationEvent(
            hookEvent(.turnStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(45)
        )
        try check(machine.sessions[0].state == .finished, "Expected late same-turn Codex UserPromptSubmit not to reactivate after Stop")

        machine.applyIntegrationEvent(
            hookEvent(.turnStarted, integrationSessionId: "codex-turn-2", pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(46)
        )
        try check(machine.sessions.count == 2, "Expected a new Codex turn id on the same process to create a new active turn")
        try check(machine.sessions[1].state == .active, "Expected the new Codex turn to become active")
        try check(machine.sessions[1].key.integrationSessionId == "codex-turn-2", "Expected latest Codex turn id to be retained")

        let processBackedMachine = AgentSessionStateMachine(graceInterval: 900)
        processBackedMachine.applyProcessObservations([observation(pid: 102, start: processStart)], at: baseline)
        processBackedMachine.applyIntegrationEvent(
            hookEvent(.turnFinished, integrationSessionId: "codex-turn-1", pid: 102, processStartTime: processStart),
            at: baseline.addingTimeInterval(1)
        )
        try check(processBackedMachine.sessions[0].state == .finished, "Expected Stop to finish the process-backed Codex turn")
        try check(
            processBackedMachine.sessions[0].key.integrationSessionId == "codex-turn-1",
            "Expected matched process-backed session to adopt the first Codex turn id"
        )
        processBackedMachine.applyIntegrationEvent(
            hookEvent(.turnStarted, integrationSessionId: "codex-turn-2", pid: 102, processStartTime: processStart),
            at: baseline.addingTimeInterval(2)
        )
        try check(processBackedMachine.sessions.count == 2, "Expected a different Codex turn id to create a new process-backed turn")
        try check(processBackedMachine.sessions[1].state == .active, "Expected the new process-backed Codex turn to become active")
        try check(
            processBackedMachine.sessions[1].key.integrationSessionId == "codex-turn-2",
            "Expected process-backed Codex session to adopt the latest turn id"
        )

        let missingStopMachine = AgentSessionStateMachine(
            graceInterval: 900,
            codexPostToolIdleTimeout: 30
        )
        missingStopMachine.applyIntegrationEvent(
            hookEvent(.turnStarted, integrationSessionId: "codex-turn-missing-stop", pid: 103, processStartTime: processStart),
            at: baseline
        )
        missingStopMachine.applyIntegrationEvent(
            hookEvent(.toolFinishedContinuing, integrationSessionId: "codex-turn-missing-stop", pid: 103, processStartTime: processStart),
            at: baseline.addingTimeInterval(1)
        )
        try check(
            missingStopMachine.aggregateHoldState(at: baseline.addingTimeInterval(2)).shouldHold,
            "Expected Codex post-tool activity to protect while waiting for completion"
        )
        missingStopMachine.applyProcessObservations(
            [observation(pid: 103, start: processStart, path: "/opt/homebrew/bin/codex")],
            at: baseline.addingTimeInterval(31)
        )
        try check(
            !missingStopMachine.aggregateHoldState(at: baseline.addingTimeInterval(31)).shouldHold,
            "Expected stale Codex post-tool activity to release even when the desktop process remains open"
        )
        try check(
            missingStopMachine.sessions.contains { $0.lastEvent?.kind == .staleActivityExpired },
            "Expected stale Codex post-tool activity to record an expiry event"
        )
        try check(
            missingStopMachine.sessions.contains {
                $0.source == .processScan && $0.state != .finished && !$0.hasIntegratedEvidence
            },
            "Expected the still-open Codex process to remain visible only as a detected process"
        )

        let terminalMachine = AgentSessionStateMachine(graceInterval: 900)
        terminalMachine.applyIntegrationEvent(
            hookEvent(.turnStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(20)
        )
        terminalMachine.applyIntegrationEvent(
            hookEvent(.sessionFinished, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(50)
        )
        try check(terminalMachine.sessions[0].state == .finished, "Expected terminal hook to finish the session")

        terminalMachine.applyIntegrationEvent(
            hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
            at: baseline.addingTimeInterval(60)
        )
        try check(terminalMachine.sessions.count == 1, "Expected post-terminal hook not to create a replacement session")
        try check(terminalMachine.sessions[0].state == .finished, "Expected post-terminal hook not to reactivate a finished session")

        let multiTurnMachine = AgentSessionStateMachine(graceInterval: 5)
        let claudeSessionID = "claude-session-1"
        multiTurnMachine.applyIntegrationEvent(
            hookEvent(
                .turnStarted,
                integrationSessionId: claudeSessionID,
                pid: 101,
                processStartTime: processStart,
                agent: .claudeCode
            ),
            at: baseline
        )
        multiTurnMachine.applyIntegrationEvent(
            hookEvent(
                .turnFinished,
                integrationSessionId: claudeSessionID,
                pid: 101,
                processStartTime: processStart,
                agent: .claudeCode
            ),
            at: baseline.addingTimeInterval(1)
        )
        multiTurnMachine.refreshExpirations(at: baseline.addingTimeInterval(7))
        try check(multiTurnMachine.sessions[0].state == .finished, "Expected grace expiry to finish the first Claude turn")

        multiTurnMachine.applyIntegrationEvent(
            hookEvent(
                .turnStarted,
                integrationSessionId: claudeSessionID,
                pid: 101,
                processStartTime: processStart,
                agent: .claudeCode
            ),
            at: baseline.addingTimeInterval(8)
        )
        try check(multiTurnMachine.sessions.count == 2, "Expected later Claude prompt with the same session id to create a new turn")
        try check(multiTurnMachine.sessions[1].state == .active, "Expected later same-session Claude prompt to become active")
    }

    private static func manualOverridePrecedenceAndPersistence() throws {
        var current = Date(timeIntervalSince1970: 5_000)
        let monitoredProcessStart = current
        var settings = AgentWakeSettings(
            manualOverrides: [
                ManualOverride(id: "pause", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: current.addingTimeInterval(60))
            ]
        )
        let monitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(
                snapshotsToReturn: [
                    ProcessSnapshot(
                        pid: 110,
                        processName: "codex",
                        executablePath: "/opt/homebrew/bin/codex",
                        processStartTime: monitoredProcessStart
                    )
                ]
            ),
            settingsProvider: { settings },
            now: { current }
        )

        monitor.poll()
        monitor.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .codexCLI,
                host: "codex-cli",
                event: .toolStarted,
                pid: 110,
                processStartTime: monitoredProcessStart,
                integrationSessionId: "manual-override-codex"
            ),
            at: current.addingTimeInterval(1)
        )
        try check(monitor.sessions.count == 1, "Expected process polling to create a held session")
        try check(!monitor.aggregateHoldState.shouldHold, "Expected persisted pause override to suppress held sessions")
        try check(monitor.aggregateHoldState.isPaused, "Expected persisted pause override to be visible in aggregate state")

        let machine = AgentSessionStateMachine()
        machine.applyProcessObservations([observation(pid: 111, start: current)], at: current)
        machine.applyManualOverrides(settings.manualOverrides, at: current)
        try check(machine.aggregateHoldState(at: current).isPaused, "Expected manual pause override to suppress direct state-machine holds")

        machine.setSafetyCutoffActive(true)
        let safetyDuringPause = machine.aggregateHoldState(at: current)
        try check(safetyDuringPause.isSafetyCutoffActive, "Expected safety cutoff to take precedence over manual pause")
        try check(!safetyDuringPause.isPaused, "Expected aggregate state to report the higher-priority safety cutoff")
        machine.setSafetyCutoffActive(false)

        settings.manualOverrides = [
            ManualOverride(id: "safety", kind: ManualOverrideKind.safetyCutoff.rawValue, expiresAt: current.addingTimeInterval(5))
        ]
        current = current.addingTimeInterval(1)
        monitor.poll()
        try check(monitor.aggregateHoldState.isSafetyCutoffActive, "Expected persisted safety override to suppress holds")
        try check(!monitor.aggregateHoldState.isPaused, "Expected safety override to take precedence over an expired previous pause")

        current = current.addingTimeInterval(6)
        try check(monitor.aggregateHoldState.shouldHold, "Expected expired safety override not to linger between polls")
        try check(!monitor.aggregateHoldState.isSafetyCutoffActive, "Expected expired safety override to stop suppressing holds")

        settings.manualOverrides = []
        current = current.addingTimeInterval(1)
        monitor.poll()
        try check(monitor.aggregateHoldState.shouldHold, "Expected removing persisted overrides to restore held sessions")
        try check(!monitor.aggregateHoldState.isPaused, "Expected removed persisted pause override not to linger")
        try check(!monitor.aggregateHoldState.isSafetyCutoffActive, "Expected removed persisted safety override not to linger")

        settings.manualOverrides = [
            ManualOverride(id: "expired", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: current.addingTimeInterval(-1))
        ]
        monitor.poll()
        try check(monitor.aggregateHoldState.shouldHold, "Expected expired persisted pause override not to suppress holds")

        settings.manualOverrides = [
            ManualOverride(id: "fallback-pause", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: current.addingTimeInterval(60))
        ]
        let fallbackMonitor = AgentMonitor(
            snapshotProvider: ThrowingSnapshotProvider(),
            settingsProvider: { settings },
            now: { current }
        )
        fallbackMonitor.poll()
        try check(fallbackMonitor.aggregateHoldState.isPaused, "Expected persisted pause override to apply even when process snapshots fail")
    }

    private static func assertionManagerAcquiresValidatedNormalAssertionsAndReleases() throws {
        let controller = RecordingPowerAssertionController()
        let heldSessionID = UUID()
        var holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
        let manager = AssertionManager(
            controller: controller,
            holdStateProvider: { holdState },
            reconcileInterval: 60
        )

        manager.start()
        try check(controller.createdTypes.isEmpty, "Expected no assertion while aggregate hold is false")

        holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [heldSessionID])
        manager.reconcile()

        try check(
            controller.createdTypes == [.preventUserIdleSystemSleep],
            "Expected validated normal assertion set"
        )
        try check(manager.snapshot.isHolding, "Expected manager snapshot to report active hold")

        holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
        manager.reconcile()

        try check(controller.releasedIDs.count == 1, "Expected normal assertion to release")
        try check(!manager.snapshot.isHolding, "Expected manager snapshot to report released state")
        manager.stop()
    }

    private static func assertionManagerPauseAndReleaseOverridesStopAssertions() throws {
        let controller = RecordingPowerAssertionController()
        var holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])
        let manager = AssertionManager(
            controller: controller,
            holdStateProvider: { holdState },
            reconcileInterval: 60
        )

        manager.start()
        try check(manager.snapshot.isHolding, "Expected initial aggregate hold to create assertions")

        holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [], isPaused: true)
        manager.reconcile()
        try check(!manager.snapshot.isHolding, "Expected pause override to release assertions")

        holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
        manager.reconcile()
        try check(controller.createdTypes.count == 1, "Expected release-now false hold state not to reacquire assertions")
        manager.stop()
    }

    private static func assertionManagerPartialCreateFailureKeepsAcquiredAssertionsAndRetriesMissingOnes() throws {
        let controller = RecordingPowerAssertionController()
        controller.createFailures[.preventDiskIdle] = PowerAssertionError.createFailed(type: .preventDiskIdle, code: -1)
        let policy = NormalPowerAssertionPolicy(assertionTypes: [.preventUserIdleSystemSleep, .preventDiskIdle])
        let manager = AssertionManager(
            controller: controller,
            policy: policy,
            holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
            reconcileInterval: 60
        )

        manager.start()
        try check(manager.snapshot.heldAssertions.map(\.type) == [.preventUserIdleSystemSleep], "Expected successful assertion to stay tracked")
        try check(manager.snapshot.lastErrorDescription != nil, "Expected create failure to stay visible")

        controller.createFailures.removeAll()
        manager.reconcile()
        try check(
            manager.snapshot.heldAssertions.map(\.type) == [.preventDiskIdle, .preventUserIdleSystemSleep],
            "Expected missing assertion type to be created on retry"
        )
        try check(manager.snapshot.lastErrorDescription == nil, "Expected retry success to clear create error")
        manager.stop()
    }

    private static func assertionManagerFailedReleaseRemainsTrackedAndRetriesWithoutHidingError() throws {
        let controller = RecordingPowerAssertionController()
        let policy = NormalPowerAssertionPolicy(assertionTypes: [.preventUserIdleSystemSleep, .preventDiskIdle])
        var holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])
        let manager = AssertionManager(
            controller: controller,
            policy: policy,
            holdStateProvider: { holdState },
            reconcileInterval: 60
        )

        manager.start()
        controller.releaseFailures = [PowerAssertionID(rawValue: 1)]
        holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
        manager.reconcile()

        try check(manager.snapshot.heldAssertions.map(\.type) == [.preventUserIdleSystemSleep], "Expected failed release to remain tracked")
        try check(manager.snapshot.lastErrorDescription != nil, "Expected failed release error to remain visible")

        holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])
        controller.releaseFailures.removeAll()
        manager.reconcile()
        try check(
            manager.snapshot.heldAssertions.map(\.type) == [.preventDiskIdle, .preventUserIdleSystemSleep],
            "Expected re-hold to recreate missing desired assertion"
        )
        try check(manager.snapshot.lastErrorDescription == nil, "Expected successful reconcile to clear release error")
        manager.stop()
    }

    private static func controlRouterPauseAndReleaseReconcileAssertions() throws {
        var current = Date(timeIntervalSince1970: 9_000)
        let monitoredProcessStart = current
        let monitor = AgentMonitor(
            snapshotProvider: StaticSnapshotProvider(
                snapshotsToReturn: [
                    ProcessSnapshot(
                        pid: 41,
                        processName: "codex",
                        executablePath: "/opt/homebrew/bin/codex",
                        processStartTime: monitoredProcessStart
                    )
                ]
            ),
            now: { current }
        )
        let controller = RecordingPowerAssertionController()
        let manager = AssertionManager(
            controller: controller,
            holdStateProvider: { monitor.aggregateHoldState },
            reconcileInterval: 60
        )
        let router = DefaultControlCommandRouter(
            pauseHandler: { duration, receivedAt in
                monitor.pauseAll(until: receivedAt.addingTimeInterval(duration))
                manager.reconcile()
            },
            releaseNowHandler: { receivedAt in
                monitor.releaseHeldSessions(at: receivedAt)
                manager.reconcile()
            }
        )

        monitor.start()
        monitor.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .codexCLI,
                host: "codex-cli",
                event: .toolStarted,
                pid: 41,
                processStartTime: monitoredProcessStart,
                integrationSessionId: "router-codex"
            ),
            at: current.addingTimeInterval(1)
        )
        manager.start()
        try check(manager.snapshot.isHolding, "Expected process-backed session to hold assertions")

        _ = try router.route(.pause(duration: 60), receivedAt: current)
        try check(!manager.snapshot.isHolding, "Expected pause command to release assertions")

        current = current.addingTimeInterval(61)
        monitor.poll()
        manager.reconcile()
        try check(manager.snapshot.isHolding, "Expected assertions to resume after pause expiry")

        _ = try router.route(.releaseNow, receivedAt: current)
        try check(!manager.snapshot.isHolding, "Expected release now command to release assertions")

        manager.stop()
        monitor.stop()
    }

    private static func controlRouterPropagatesIntegrationMutationFailures() throws {
        let router = DefaultControlCommandRouter(
            integrationRemoveHandler: { _, _ in
                throw CheckFailure("remove failed")
            },
            integrationEnableAutoHandler: { _, _ in
                throw CheckFailure("enable failed")
            },
            uninstallHandler: { _, _, _, _ in
                throw CheckFailure("uninstall failed")
            }
        )

        try expectThrows("Expected integration removal failure to propagate") {
            _ = try router.route(.integrationsRemove(agentID: "codex-cli"), receivedAt: Date())
        }
        try expectThrows("Expected integration enable-auto failure to propagate") {
            _ = try router.route(.integrationsEnableAuto(agentID: "codex-cli"), receivedAt: Date())
        }
        try expectThrows("Expected uninstall integration failure to propagate") {
            _ = try router.route(.uninstall(removeHelper: false, removeIntegrations: true, removeSettings: false), receivedAt: Date())
        }
    }

    private static func controlRouterSurfacesHelperCommandOutcomes() throws {
        let receivedAt = Date(timeIntervalSince1970: 9_000)
        let defaultRouter = DefaultControlCommandRouter()
        let defaultStatus = try defaultRouter.route(.helperStatus, receivedAt: receivedAt)
        let defaultEnable = try defaultRouter.route(.helperEnableBagMode, receivedAt: receivedAt)
        let defaultDisable = try defaultRouter.route(.helperDisableBagMode, receivedAt: receivedAt)
        let defaultRepair = try defaultRouter.route(.helperRepair, receivedAt: receivedAt)
        let defaultUninstall = try defaultRouter.route(.helperUninstall, receivedAt: receivedAt)
        let defaultClosedLidStatus = try defaultRouter.route(.closedLidStatus, receivedAt: receivedAt)
        let defaultClosedLidEnable = try defaultRouter.route(.closedLidEnable, receivedAt: receivedAt)
        let defaultClosedLidDisable = try defaultRouter.route(.closedLidDisable, receivedAt: receivedAt)
        let defaultProtectDetected = try defaultRouter.route(.protectDetectedSessions, receivedAt: receivedAt)

        try check(
            defaultStatus.message == ClosedLidModeAvailability.helperCommandMessage("status"),
            "Expected default helper status outcome"
        )
        try check(
            defaultEnable.message == ClosedLidModeAvailability.helperCommandMessage("enable"),
            "Expected default helper enable outcome"
        )
        try check(
            defaultDisable.message == ClosedLidModeAvailability.helperCommandMessage("disable"),
            "Expected default helper disable outcome"
        )
        try check(
            defaultRepair.message == ClosedLidModeAvailability.helperCommandMessage("repair"),
            "Expected default helper repair outcome"
        )
        try check(
            defaultUninstall.message == ClosedLidModeAvailability.helperCommandMessage("uninstall"),
            "Expected default helper uninstall outcome"
        )
        try check(
            defaultClosedLidStatus.message == ClosedLidModeAvailability.helperCommandMessage("status"),
            "Expected default closed-lid status outcome"
        )
        try check(
            defaultClosedLidEnable.message == ClosedLidModeAvailability.helperCommandMessage("enable"),
            "Expected default closed-lid enable outcome"
        )
        try check(
            defaultClosedLidDisable.message == ClosedLidModeAvailability.helperCommandMessage("disable"),
            "Expected default closed-lid disable outcome"
        )
        try check(
            defaultProtectDetected.message == "No detected sessions to protect",
            "Expected default protect-detected outcome"
        )

        let router = DefaultControlCommandRouter(
            helperStatusProvider: {
                "Helper installed generation=7 state=ready"
            },
            helperEnableBagModeHandler: { receivedAt in
                "Helper enable checked at \(Int(receivedAt.timeIntervalSince1970))"
            },
            helperDisableBagModeHandler: { receivedAt in
                "Helper disable checked at \(Int(receivedAt.timeIntervalSince1970))"
            },
            helperRepairHandler: { receivedAt in
                "Helper repair checked at \(Int(receivedAt.timeIntervalSince1970))"
            },
            helperUninstallHandler: { receivedAt in
                "Helper uninstall checked at \(Int(receivedAt.timeIntervalSince1970))"
            },
            closedLidStatusProvider: {
                "Closed-Lid Mode off"
            },
            closedLidEnableHandler: { receivedAt in
                "Closed-Lid enable checked at \(Int(receivedAt.timeIntervalSince1970))"
            },
            closedLidDisableHandler: { receivedAt in
                "Closed-Lid disable checked at \(Int(receivedAt.timeIntervalSince1970))"
            },
            protectDetectedSessionsHandler: { receivedAt in
                "Protect detected checked at \(Int(receivedAt.timeIntervalSince1970))"
            },
            uninstallHandler: { removeHelper, removeIntegrations, removeSettings, receivedAt in
                "Uninstall removeHelper=\(removeHelper) removeIntegrations=\(removeIntegrations) removeSettings=\(removeSettings) at \(Int(receivedAt.timeIntervalSince1970))"
            }
        )

        let status = try router.route(.helperStatus, receivedAt: receivedAt)
        let enable = try router.route(.helperEnableBagMode, receivedAt: receivedAt)
        let disable = try router.route(.helperDisableBagMode, receivedAt: receivedAt)
        let repair = try router.route(.helperRepair, receivedAt: receivedAt)
        let helperUninstall = try router.route(.helperUninstall, receivedAt: receivedAt)
        let closedLidStatus = try router.route(.closedLidStatus, receivedAt: receivedAt)
        let closedLidEnable = try router.route(.closedLidEnable, receivedAt: receivedAt)
        let closedLidDisable = try router.route(.closedLidDisable, receivedAt: receivedAt)
        let protectDetected = try router.route(.protectDetectedSessions, receivedAt: receivedAt)
        let uninstall = try router.route(.uninstall(removeHelper: true, removeIntegrations: true, removeSettings: true), receivedAt: receivedAt)

        try check(status.accepted, "Expected helper status to be accepted")
        try check(status.message == "Helper installed generation=7 state=ready", "Expected helper status provider output")
        try check(enable.message == "Helper enable checked at 9000", "Expected helper enable handler output")
        try check(disable.message == "Helper disable checked at 9000", "Expected helper disable handler output")
        try check(repair.message == "Helper repair checked at 9000", "Expected helper repair handler output")
        try check(helperUninstall.message == "Helper uninstall checked at 9000", "Expected helper uninstall handler output")
        try check(closedLidStatus.message == "Closed-Lid Mode off", "Expected closed-lid status provider output")
        try check(closedLidEnable.message == "Closed-Lid enable checked at 9000", "Expected closed-lid enable handler output")
        try check(closedLidDisable.message == "Closed-Lid disable checked at 9000", "Expected closed-lid disable handler output")
        try check(protectDetected.message == "Protect detected checked at 9000", "Expected protect-detected handler output")
        try check(
            uninstall.message == "Uninstall removeHelper=true removeIntegrations=true removeSettings=true at 9000",
            "Expected uninstall handler output"
        )
    }

    private static func assertionManagerStopReleasesHeldAssertions() throws {
        let controller = RecordingPowerAssertionController()
        let manager = AssertionManager(
            controller: controller,
            holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
            reconcileInterval: 60
        )

        manager.start()
        try check(manager.snapshot.isHolding, "Expected manager to hold after start")

        manager.stop()

        try check(controller.releasedIDs.count == 1, "Expected stop to release held assertion")
        try check(manager.snapshot.runState == .stopped, "Expected manager to report stopped state")
        try check(!manager.snapshot.isHolding, "Expected stopped manager to report no active assertions")
    }

    private static func assertionManagerStopWithFailedReleaseDoesNotReportStoppedUntilRetryCompletes() throws {
        let controller = RecordingPowerAssertionController()
        let manager = AssertionManager(
            controller: controller,
            holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
            reconcileInterval: 60
        )

        manager.start()
        controller.releaseFailures = [PowerAssertionID(rawValue: 1)]
        manager.stop()

        try check(manager.snapshot.runState == .started, "Expected manager not to report stopped while release retry is pending")
        try check(manager.snapshot.isHolding, "Expected failed release to remain tracked after stop")
        try check(manager.snapshot.lastErrorDescription != nil, "Expected stop release failure to stay visible")

        controller.releaseFailures.removeAll()
        manager.reconcile()

        try check(manager.snapshot.runState == .stopped, "Expected manager to report stopped after release retry succeeds")
        try check(!manager.snapshot.isHolding, "Expected retry to clear held assertion")
    }

    private static func stoppedAssertionManagerDoesNotReacquireAssertions() throws {
        let controller = RecordingPowerAssertionController()
        let manager = AssertionManager(
            controller: controller,
            holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
            reconcileInterval: 60
        )

        manager.start()
        manager.stop()
        manager.reconcile()

        try check(controller.createdTypes.count == 1, "Expected stopped reconcile not to reacquire assertions")
        try check(manager.snapshot.runState == .stopped, "Expected manager to remain stopped")
        try check(!manager.snapshot.isHolding, "Expected stopped manager not to hold assertions")
    }

    private static func normalAssertionPolicyAvoidsDisplayAndDiskAssertions() throws {
        let defaults = NormalPowerAssertionPolicy.validatedDefault.assertionTypes
        try check(defaults == [.preventUserIdleSystemSleep], "Expected user-idle system sleep assertion by default")
        try check(!defaults.contains(.preventDisplaySleep), "Expected display sleep assertion to stay disabled by default")
        try check(!defaults.contains(.preventDiskIdle), "Expected disk idle assertion to stay out of default set")
        try check(!defaults.contains(.preventSystemSleep), "Expected unsupported system sleep assertion to stay out of default set")
        try check(
            NormalPowerAssertionPolicy.validationCandidateAssertionTypes.contains(.preventDiskIdle),
            "Expected disk idle to remain an explicit validation candidate"
        )
    }

    private static func assertionManagerDefaultReconcileIntervalMeetsReleaseSLA() throws {
        let manager = AssertionManager()
        try check(manager.reconcileInterval <= 30, "Expected assertion release polling interval within 30 seconds")
    }

    private static func controlRuntimeStoreCreatesPrivateDirectoryAndRotatingToken() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let store = ControlRuntimeStore(paths: paths)
        let firstToken = try store.rotateToken()
        let secondToken = try store.rotateToken()
        let persistedToken = try store.loadToken()
        let runtimeMode = try store.runtimeDirectoryMode()
        let tokenMode = try store.tokenFileMode()

        try check(firstToken != secondToken, "Expected hook token to rotate per launch")
        try check(persistedToken == secondToken, "Expected latest hook token to be persisted")
        try check(runtimeMode == 0o700, "Expected runtime directory mode 0700")
        try check(tokenMode == 0o600, "Expected hook token mode 0600")
        try check(paths.controlSocketURL.path.hasSuffix("run/agentwake.sock"), "Expected canonical socket path")
    }

    private static func controlServerRejectsAuthReplayAndRateLimitFailures() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let router = RecordingControlRouter()
        let server = ControlServer(
            token: "secret",
            router: router,
            maxEventsPerWindow: 2,
            rateLimitWindow: 60,
            now: { now }
        )

        try expectThrows("Expected unauthenticated requests to be rejected") {
            _ = try server.handle(ControlRequest(token: "wrong", eventID: "bad", command: .releaseNow))
        }
        try check(router.commands.isEmpty, "Expected unauthenticated commands not to reach the router")

        _ = try server.handle(ControlRequest(token: "secret", eventID: "a", processID: 1, command: .status))
        try expectThrows("Expected replayed event to be rejected") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "a", processID: 1, command: .status))
        }

        _ = try server.handle(ControlRequest(token: "secret", eventID: "b", processID: 1, command: .status))
        try expectThrows("Expected rate-limited event to be rejected") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "c", processID: 1, command: .status))
        }
    }

    private static func controlServerRateLimitsPerProcessAndTokenBackstop() throws {
        var current = Date(timeIntervalSince1970: 5_000)
        let server = ControlServer(
            token: "secret",
            router: RecordingControlRouter(),
            maxEventsPerWindow: 2,
            maxTokenEventsPerWindow: 4,
            rateLimitWindow: 60,
            now: { current }
        )

        _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-a", processID: 1, command: .status))
        _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-b", processID: 1, command: .status))
        try expectThrows("Expected process bucket to be rate-limited") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-c", processID: 1, command: .status))
        }

        _ = try server.handle(ControlRequest(token: "secret", eventID: "p2-a", processID: 2, command: .status))
        _ = try server.handle(ControlRequest(token: "secret", eventID: "p3-a", processID: 3, command: .status))
        try expectThrows("Expected token-wide bucket to stop process ID rotation") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "p4-a", processID: 4, command: .status))
        }

        current = current.addingTimeInterval(61)
        _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-d", processID: 1, command: .status))
    }

    private static func replayCacheExpiresOldEvents() throws {
        var current = Date(timeIntervalSince1970: 7_000)
        let server = ControlServer(
            token: "secret",
            router: RecordingControlRouter(),
            replayTTL: 10,
            now: { current }
        )

        _ = try server.handle(ControlRequest(token: "secret", eventID: "repeatable", command: .status))
        try expectThrows("Expected replayed event to be rejected inside replay TTL") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "repeatable", command: .status))
        }

        current = current.addingTimeInterval(11)
        _ = try server.handle(ControlRequest(token: "secret", eventID: "repeatable", command: .status))
    }

    private static func controlServerRejectsInvalidPauseDurations() throws {
        let router = RecordingControlRouter()
        let server = ControlServer(token: "secret", router: router)

        try expectThrows("Expected zero pause duration to be rejected") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "zero-pause", command: .pause(duration: 0)))
        }
        try expectThrows("Expected negative pause duration to be rejected") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "negative-pause", command: .pause(duration: -1)))
        }
        try expectThrows("Expected infinite pause duration to be rejected") {
            _ = try server.handle(ControlRequest(token: "secret", eventID: "infinite-pause", command: .pause(duration: .infinity)))
        }

        try check(router.commands.isEmpty, "Expected invalid pause commands not to reach router")
    }

    private static func controlServerUsesReceiptTime() throws {
        let receiptTime = Date(timeIntervalSince1970: 6_000)
        let router = RecordingControlRouter()
        let server = ControlServer(token: "secret", router: router, now: { receiptTime })

        let response = try server.handle(
            ControlRequest(
                token: "secret",
                eventID: "receipt",
                clientTimestamp: Date(timeIntervalSince1970: 1),
                command: .pause(duration: 3_600)
            )
        )

        try check(response.receiptTimestamp == receiptTime, "Expected response to use server receipt time")
        try check(router.receivedAt == [receiptTime], "Expected router to receive server receipt time")
    }

    private static func cliParsesCommandsAndSendsThroughClient() throws {
        let client = RecordingControlClient()
        let cli = AgentWakeCLI(client: client)

        let statusOutput = try cli.run(arguments: ["agentwake", "status"])
        try check(statusOutput == "ok", "Expected status output from client")
        try check(client.commands.last == .status, "Expected status command")
        _ = try cli.run(arguments: ["agentwake", "doctor"])
        try check(client.commands.last == .doctor, "Expected doctor command")
        _ = try cli.run(arguments: ["agentwake", "pause", "1h"])
        try check(client.commands.last == .pause(duration: 3_600), "Expected pause command")
        _ = try cli.run(arguments: ["agentwake", "release", "now"])
        try check(client.commands.last == .releaseNow, "Expected release now command")
        _ = try cli.run(arguments: ["agentwake", "protect", "detected"])
        try check(client.commands.last == .protectDetectedSessions, "Expected protect detected command")
        _ = try cli.run(arguments: ["agentwake", "list"])
        try check(client.commands.last == .list, "Expected list command")
        try expectThrows("Expected custom agent add to require experimental flag") {
            _ = try cli.run(arguments: ["agentwake", "add", "/usr/local/bin/agent"])
        }
        _ = try cli.run(arguments: ["agentwake", "add", "--experimental", "/usr/local/bin/agent"])
        try check(client.commands.last == .add(binary: "/usr/local/bin/agent"), "Expected add command")
        _ = try cli.run(arguments: ["agentwake", "integrations", "list"])
        try check(client.commands.last == .integrationsList, "Expected integrations list command")
        _ = try cli.run(arguments: ["agentwake", "integrations", "status"])
        try check(client.commands.last == .integrationsStatus, "Expected integrations status command")
        _ = try cli.run(arguments: ["agentwake", "integrations", "remove", "codex-cli"])
        try check(client.commands.last == .integrationsRemove(agentID: "codex-cli"), "Expected integrations remove command")
        _ = try cli.run(arguments: ["agentwake", "integrations", "enable-auto", "claude-code"])
        try check(client.commands.last == .integrationsEnableAuto(agentID: "claude-code"), "Expected integrations enable-auto command")
        _ = try cli.run(arguments: ["agentwake", "helper", "status"])
        try check(client.commands.last == .helperStatus, "Expected helper status command")
        _ = try cli.run(arguments: ["agentwake", "helper", "enable"])
        try check(client.commands.last == .helperEnableBagMode, "Expected helper enable command")
        _ = try cli.run(arguments: ["agentwake", "helper", "disable"])
        try check(client.commands.last == .helperDisableBagMode, "Expected helper disable command")
        _ = try cli.run(arguments: ["agentwake", "closed-lid", "status"])
        try check(client.commands.last == .closedLidStatus, "Expected closed-lid status command")
        _ = try cli.run(arguments: ["agentwake", "closed-lid", "enable"])
        try check(client.commands.last == .closedLidEnable, "Expected closed-lid enable command")
        _ = try cli.run(arguments: ["agentwake", "closed-lid", "disable"])
        try check(client.commands.last == .closedLidDisable, "Expected closed-lid disable command")
        _ = try cli.run(arguments: ["agentwake", "helper", "repair"])
        try check(client.commands.last == .helperRepair, "Expected helper repair command")
        _ = try cli.run(arguments: ["agentwake", "helper", "uninstall"])
        try check(client.commands.last == .helperUninstall, "Expected helper uninstall command")
        _ = try cli.run(arguments: ["agentwake", "uninstall", "--remove-helper", "--remove-integrations", "--remove-settings"])
        try check(
            client.commands.last == .uninstall(removeHelper: true, removeIntegrations: true, removeSettings: true),
            "Expected uninstall flags"
        )
    }

    private static func cliRejectsExtraArgumentsAndUnknownFlags() throws {
        let cli = AgentWakeCLI(client: RecordingControlClient())

        try expectThrows("Expected extra status argument to be rejected") {
            _ = try cli.parse(arguments: ["status", "extra"])
        }
        try expectThrows("Expected extra release argument to be rejected") {
            _ = try cli.parse(arguments: ["release", "now", "again"])
        }
        try expectThrows("Expected unknown protect target to be rejected") {
            _ = try cli.parse(arguments: ["protect", "seen"])
        }
        try expectThrows("Expected integrations list extra argument to be rejected") {
            _ = try cli.parse(arguments: ["integrations", "list", "--verbose"])
        }
        try expectThrows("Expected helper status extra argument to be rejected") {
            _ = try cli.parse(arguments: ["helper", "status", "--json"])
        }
        try expectThrows("Expected closed-lid status extra argument to be rejected") {
            _ = try cli.parse(arguments: ["closed-lid", "status", "--json"])
        }
        try expectThrows("Expected unknown closed-lid subcommand to be rejected") {
            _ = try cli.parse(arguments: ["closed-lid", "arm"])
        }
        try expectThrows("Expected helper uninstall extra argument to be rejected") {
            _ = try cli.parse(arguments: ["helper", "uninstall", "--force"])
        }
        try expectThrows("Expected unknown uninstall flag to be rejected") {
            _ = try cli.parse(arguments: ["uninstall", "--everything"])
        }
        try expectThrows("Expected remove-settings to require integration removal") {
            _ = try cli.parse(arguments: ["uninstall", "--remove-settings"])
        }
    }

    private static func localControlClientSendsThroughUnixSocket() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let store = ControlRuntimeStore(paths: paths)
        let token = try store.rotateToken()
        let router = RecordingControlRouter()
        let server = ControlServer(token: token, router: router, now: { Date(timeIntervalSince1970: 8_000) })
        let socketServer = ControlSocketServer(runtimeStore: store)
        try socketServer.start(controlServer: server)
        defer { socketServer.stop() }

        let response = try LocalControlClient(runtimeStore: store).send(.status)
        let socketMode = try store.socketFileMode()

        try check(response.message == "ok", "Expected local client to receive socket server response")
        try check(router.commands.last == .status, "Expected socket server to route status command")
        try check(socketMode == 0o600, "Expected control socket mode 0600")
    }

    private static func socketEndpointRejectsAuthReplayAndClientPIDRotation() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let store = ControlRuntimeStore(paths: paths)
        let token = try store.rotateToken()
        let server = ControlServer(
            token: token,
            router: RecordingControlRouter(),
            maxEventsPerWindow: 1,
            maxTokenEventsPerWindow: 10,
            rateLimitWindow: 60,
            now: { Date(timeIntervalSince1970: 8_500) }
        )
        let socketServer = ControlSocketServer(runtimeStore: store)
        try socketServer.start(controlServer: server)
        defer { socketServer.stop() }

        try expectThrows("Expected socket endpoint to reject invalid token") {
            _ = try UnixControlSocketClient.send(
                ControlRequest(token: "wrong", eventID: "wrong-token", processID: 111, command: .status),
                to: paths.controlSocketURL
            )
        }

        _ = try UnixControlSocketClient.send(
            ControlRequest(token: token, eventID: "accepted", processID: 111, command: .status),
            to: paths.controlSocketURL
        )
        try expectThrows("Expected socket endpoint to reject replayed event") {
            _ = try UnixControlSocketClient.send(
                ControlRequest(token: token, eventID: "accepted", processID: 111, command: .status),
                to: paths.controlSocketURL
            )
        }
        try expectThrows("Expected socket endpoint to derive peer PID instead of trusting client PID") {
            _ = try UnixControlSocketClient.send(
                ControlRequest(token: token, eventID: "fake-pid", processID: 222, command: .status),
                to: paths.controlSocketURL
            )
        }
    }

    private static func controlServerComponentRotatesTokenAndClearsRuntime() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let store = ControlRuntimeStore(paths: paths)
        let component = ControlServerComponent(runtimeStore: store, router: RecordingControlRouter())
        component.start()

        try check(component.runState == .started, "Expected control server component to start")
        try check(FileManager.default.fileExists(atPath: paths.hookTokenURL.path), "Expected component start to rotate token")
        try check(FileManager.default.fileExists(atPath: paths.controlSocketURL.path), "Expected component start to bind socket")

        component.stop()

        try check(component.runState == .stopped, "Expected control server component to stop")
        try check(!FileManager.default.fileExists(atPath: paths.hookTokenURL.path), "Expected component stop to clear token")
        try check(!FileManager.default.fileExists(atPath: paths.controlSocketURL.path), "Expected component stop to clear socket")
    }

    private static func hookAdapterMapsAndRedactsClaudePayload() throws {
        let payload = """
        {
          "session_id": "session-1",
          "transcript_path": "/Users/tester/.claude/transcript.jsonl",
          "cwd": "/Users/tester/private-project",
          "hook_event_name": "PreToolUse",
          "tool_name": "Bash",
          "tool_input": { "command": "cat .env" },
          "prompt": "secret prompt"
        }
        """

        let event = try checkNotNil(
            HookAdapterMapper.claudeCodeEvent(
                from: Data(payload.utf8),
                context: HookAdapterContext(
                    agent: .claudeCode,
                    host: "claude-code",
                    processID: 42,
                    cwdHashSalt: "local-salt",
                    eventIDProvider: { "fallback" }
                )
            ),
            "Expected Claude hook payload to map to an AgentWake event"
        )

        let encoded = try String(data: JSONEncoder().encode(event), encoding: .utf8) ?? ""
        try check(event.event == .toolStarted, "Expected PreToolUse to map to tool_started")
        try check(event.integrationSessionId == "session-1", "Expected session id to be retained")
        try check(event.pid == 42, "Expected adapter process id to be included")
        try check(event.cwdHash == CWDHash.hmacSHA256("/Users/tester/private-project", salt: "local-salt"), "Expected cwd to be HMAC hashed")
        try check(!encoded.contains("secret prompt"), "Expected prompt text to be discarded")
        try check(!encoded.contains("cat .env"), "Expected tool arguments to be discarded")
        try check(!encoded.contains("private-project"), "Expected raw cwd to be discarded")
        try check(!encoded.contains("transcript"), "Expected transcript path to be discarded")
    }

    private static func hookAdapterMapsAndRedactsCodexNativeHookPayloads() throws {
        let payloads: [(payload: String, event: HookAdapterEventKind, sessionID: String)] = [
            (
                """
                {
                  "hook_event_name": "SessionStart",
                  "session_id": "codex-session-1",
                  "cwd": "/Users/tester/private-codex-project",
                  "transcript_path": "/Users/tester/.codex/sessions/session.jsonl",
                  "model": "gpt-5.5",
                  "permission_mode": "default",
                  "source": "startup"
                }
                """,
                .sessionStarted,
                "codex-session-1"
            ),
            (
                """
                {
                  "hook_event_name": "UserPromptSubmit",
                  "session_id": "codex-session-1",
                  "turn_id": "codex-turn-1",
                  "cwd": "/Users/tester/private-codex-project",
                  "transcript_path": "/Users/tester/.codex/sessions/session.jsonl",
                  "prompt": "secret prompt text"
                }
                """,
                .turnStarted,
                "codex-turn-1"
            ),
            (
                """
                {
                  "hook_event_name": "PreToolUse",
                  "session_id": "codex-session-1",
                  "turn_id": "codex-turn-1",
                  "cwd": "/Users/tester/private-codex-project",
                  "transcript_path": "/Users/tester/.codex/sessions/session.jsonl",
                  "tool_name": "shell",
                  "tool_input": { "command": "cat .env" },
                  "tool_use_id": "codex-tool-1"
                }
                """,
                .toolStarted,
                "codex-turn-1"
            ),
            (
                """
                {
                  "hook_event_name": "PostToolUse",
                  "session_id": "codex-session-1",
                  "turn_id": "codex-turn-1",
                  "cwd": "/Users/tester/private-codex-project",
                  "transcript_path": "/Users/tester/.codex/sessions/session.jsonl",
                  "tool_input": { "command": "cat .env" },
                  "tool_response": "SECRET_TOKEN=abc123",
                  "tool_use_id": "codex-tool-1"
                }
                """,
                .toolFinishedContinuing,
                "codex-turn-1"
            ),
            (
                """
                {
                  "hook_event_name": "Stop",
                  "session_id": "codex-session-1",
                  "turn_id": "codex-turn-1",
                  "cwd": "/Users/tester/private-codex-project",
                  "transcript_path": "/Users/tester/.codex/sessions/session.jsonl",
                  "last_assistant_message": "assistant message that must stay local",
                  "stop_hook_active": true
                }
                """,
                .turnFinished,
                "codex-turn-1"
            )
        ]

        for item in payloads {
            let event = try checkNotNil(
                HookAdapterMapper.codexHookEvent(
                    from: Data(item.payload.utf8),
                    context: HookAdapterContext(
                        agent: .codexCLI,
                        host: "codex-cli",
                        processID: 44,
                        cwdHashSalt: "local-salt",
                        eventIDProvider: { "fallback" }
                    )
                ),
                "Expected Codex native hook payload to map"
            )

            let encoded = try String(data: JSONEncoder().encode(event), encoding: .utf8) ?? ""
            try check(event.event == item.event, "Expected Codex native hook to map to \(item.event.rawValue)")
            try check(event.integrationSessionId == item.sessionID, "Expected Codex native hook to prefer turn id when present")
            try check(event.pid == 44, "Expected Codex native hook to include process id")
            try check(event.cwdHash == CWDHash.hmacSHA256("/Users/tester/private-codex-project", salt: "local-salt"), "Expected Codex cwd to be HMAC hashed")
            try check(event.eventID.hasPrefix("codex-"), "Expected Codex native hook replay ID to be namespaced")

            for sensitive in ["secret prompt text", "cat .env", "SECRET_TOKEN", "private-codex-project", "transcript", "assistant message"] {
                try check(!encoded.contains(sensitive), "Expected Codex native hook event to discard \(sensitive)")
            }
        }
    }

    private static func hookAdapterUsesStableReplayIDForNativeToolEventsOnly() throws {
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"session-1","tool_use_id":"tool-1","prompt":"do work"}"#
        let context = HookAdapterContext(
            agent: .claudeCode,
            host: "claude-code",
            processID: 42,
            cwdHashSalt: "local-salt",
            eventIDProvider: { "fallback-\(UUID().uuidString)" }
        )

        let first = try checkNotNil(
            HookAdapterMapper.claudeCodeEvent(from: Data(payload.utf8), context: context),
            "Expected first Claude event to map"
        )
        let second = try checkNotNil(
            HookAdapterMapper.claudeCodeEvent(from: Data(payload.utf8), context: context),
            "Expected replayed Claude event to map"
        )
        let fallback = try checkNotNil(
            HookAdapterMapper.claudeCodeEvent(
                from: Data(payload.utf8),
                context: HookAdapterContext(
                    agent: .claudeCode,
                    host: "claude-code",
                    processID: 42,
                    eventIDProvider: { "fallback" }
                )
            ),
            "Expected unsalted Claude event to map"
        )

        try check(first.eventID == second.eventID, "Expected salted Claude tool payloads with native tool IDs to get stable replay IDs")
        try check(first.eventID.hasPrefix("claude-"), "Expected synthesized Claude replay ID to be namespaced")
        try check(first.eventID != "fallback", "Expected salted Claude replay ID not to use random fallback")
        try check(fallback.eventID == "fallback", "Expected unsalted Claude payloads to keep fallback IDs")

        let codexPayload = #"{"hook_event_name":"PreToolUse","session_id":"session-1","turn_id":"turn-1","tool_use_id":"tool-1","prompt":"do work"}"#
        let codexContext = HookAdapterContext(
            agent: .codexCLI,
            host: "codex-cli",
            processID: 43,
            cwdHashSalt: "local-salt",
            eventIDProvider: { "fallback-\(UUID().uuidString)" }
        )
        let codexFirst = try checkNotNil(
            HookAdapterMapper.codexHookEvent(from: Data(codexPayload.utf8), context: codexContext),
            "Expected first Codex native hook event to map"
        )
        let codexSecond = try checkNotNil(
            HookAdapterMapper.codexHookEvent(from: Data(codexPayload.utf8), context: codexContext),
            "Expected replayed Codex native hook event to map"
        )
        try check(codexFirst.eventID == codexSecond.eventID, "Expected Codex native hook occurrence IDs to get stable replay IDs")
        try check(codexFirst.eventID.hasPrefix("codex-"), "Expected synthesized Codex replay ID to be namespaced")

        let rawCodexEventID = try checkNotNil(
            HookAdapterMapper.codexHookEvent(
                from: Data(#"{"hook_event_name":"PreToolUse","event_id":"raw-sensitive-event-id","session_id":"session-1","turn_id":"turn-1","tool_use_id":"tool-1"}"#.utf8),
                context: HookAdapterContext(
                    agent: .codexCLI,
                    host: "codex-cli",
                    processID: 43,
                    cwdHashSalt: "local-salt",
                    eventIDProvider: { "fallback" }
                )
            ),
            "Expected Codex native hook with raw event_id to map"
        )
        try check(rawCodexEventID.eventID.hasPrefix("codex-"), "Expected raw Codex event_id to be HMAC namespaced")
        try check(rawCodexEventID.eventID != "raw-sensitive-event-id", "Expected raw Codex event_id not to pass through")

        let startupSession = try checkNotNil(
            HookAdapterMapper.codexHookEvent(
                from: Data(#"{"hook_event_name":"SessionStart","session_id":"session-1","source":"startup"}"#.utf8),
                context: codexContext
            ),
            "Expected Codex startup session event to map"
        )
        let resumeSession = try checkNotNil(
            HookAdapterMapper.codexHookEvent(
                from: Data(#"{"hook_event_name":"SessionStart","session_id":"session-1","source":"resume"}"#.utf8),
                context: codexContext
            ),
            "Expected Codex resume session event to map"
        )
        try check(startupSession.eventID != resumeSession.eventID, "Expected Codex SessionStart replay IDs to include source")

        let promptPayload = #"{"hook_event_name":"UserPromptSubmit","session_id":"session-1","prompt":"do work"}"#
        let promptEvent = try checkNotNil(
            HookAdapterMapper.claudeCodeEvent(
                from: Data(promptPayload.utf8),
                context: HookAdapterContext(
                    agent: .claudeCode,
                    host: "claude-code",
                    processID: 42,
                    cwdHashSalt: "local-salt",
                    eventIDProvider: { "prompt-fallback" }
                )
            ),
            "Expected Claude prompt event to map"
        )
        try check(promptEvent.eventID == "prompt-fallback", "Expected Claude events without occurrence IDs to avoid payload-digest replay IDs")
    }

    private static func hookAdapterResolvesAgentAncestorThroughShellShim() throws {
        let codexStart = Date(timeIntervalSince1970: 9_010)
        let shellStart = Date(timeIntervalSince1970: 9_020)
        let resolved = HookAdapterProcessResolver.nearestAgentProcess(
            startingAt: 44,
            agent: .codexCLI,
            snapshots: [
                ProcessSnapshot(
                    pid: 43,
                    parentPID: 1,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: codexStart
                ),
                ProcessSnapshot(
                    pid: 44,
                    parentPID: 43,
                    processName: "sh",
                    executablePath: "/bin/sh",
                    processStartTime: shellStart
                )
            ]
        )

        try check(
            resolved == HookAdapterProcessIdentity(pid: 43, processStartTime: codexStart),
            "Expected adapter to resolve through shell shim to nearest agent ancestor"
        )
    }

    private static func hookAdapterNoOpsWhenAgentWakeIsUnavailable() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"session-2","prompt":"do work"}"#
        let startedAt = Date()
        let result = HookAdapterRunner(runtimeStore: ControlRuntimeStore(paths: paths))
            .runClaudeCodeHook(
                stdin: Data(payload.utf8),
                context: HookAdapterContext(agent: .claudeCode, host: "claude-code", processID: 43)
            )
        let elapsed = Date().timeIntervalSince(startedAt)

        try check(result == HookAdapterRunResult(), "Expected unavailable AgentWake adapter run to no-op")
        try check(elapsed < 0.25, "Expected no-op adapter path to complete within 250ms")

        let codexStartedAt = Date()
        let codexResult = HookAdapterRunner(runtimeStore: ControlRuntimeStore(paths: paths))
            .runCodexNotify(
                payload: #"{"type":"agent-turn-complete","turn-id":"turn-fast"}"#,
                context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", processID: 44),
                forwardNotifyCommand: ["/bin/sh", "-c", "sleep 1"]
            )
        let codexElapsed = Date().timeIntervalSince(codexStartedAt)
        try check(codexResult == HookAdapterRunResult(), "Expected Codex unavailable adapter run to no-op")
        try check(codexElapsed < 0.25, "Expected forwarded Codex notify to avoid blocking the no-op path")

        let codexHookStartedAt = Date()
        let codexHookResult = HookAdapterRunner(runtimeStore: ControlRuntimeStore(paths: paths))
            .runCodexHook(
                stdin: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"session-2","turn_id":"turn-2","prompt":"do work"}"#.utf8),
                context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", processID: 44)
            )
        let codexHookElapsed = Date().timeIntervalSince(codexHookStartedAt)
        try check(codexHookResult == HookAdapterRunResult(), "Expected unavailable Codex native hook adapter run to no-op")
        try check(codexHookElapsed < 0.25, "Expected unavailable Codex native hook no-op path to complete within 250ms")
    }

    private static func hookAdapterRoutesIntegrationEventsThroughControlServer() throws {
        let router = RecordingControlRouter()
        let server = ControlServer(token: "secret", router: router, now: { Date(timeIntervalSince1970: 9_000) })
        let event = HookAdapterEvent(
            agent: .codexCLI,
            host: "codex-cli",
            event: .turnFinished,
            pid: 44,
            integrationSessionId: "turn-1",
            eventID: "event-1"
        )

        _ = try server.handle(ControlRequest(token: "secret", eventID: "event-1", processID: 44, command: .integrationEvent(event)))

        try check(router.commands == [.integrationEvent(event)], "Expected integration events to route through the control server")
    }

    private static func integrationEventCanMoveProcessDetectedSessionToStandingBy() throws {
        let baseline = Date(timeIntervalSince1970: 9_100)
        let machine = AgentSessionStateMachine(graceInterval: 900)

        machine.applyProcessObservations(
            [observation(pid: 44, start: baseline, path: "/opt/homebrew/bin/codex", agent: .codexCLI)],
            at: baseline
        )
        machine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .codexCLI,
                host: "codex-cli",
                event: .turnFinished,
                pid: 44,
                processStartTime: baseline,
                integrationSessionId: "turn-2",
                eventID: "codex-turn-2"
            ),
            at: baseline.addingTimeInterval(10)
        )

        try check(machine.sessions.first?.state == .finished, "Expected Codex notify completion to finish the matching process session")
        try check(machine.sessions.first?.standingByExpiresAt == nil, "Expected Codex notify completion not to keep a grace hold")

        let staleMachine = AgentSessionStateMachine(graceInterval: 900)
        staleMachine.applyProcessObservations(
            [observation(pid: 44, start: baseline, path: "/opt/homebrew/bin/codex", agent: .codexCLI)],
            at: baseline
        )
        staleMachine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .codexCLI,
                host: "codex-cli",
                event: .turnFinished,
                pid: 44,
                processStartTime: baseline.addingTimeInterval(100),
                eventID: "codex-stale-pid"
            ),
            at: baseline.addingTimeInterval(10)
        )
        try check(staleMachine.sessions.first?.state == .active, "Expected stale pid reuse event not to mutate a process-scanned session")

        let integrationMachine = AgentSessionStateMachine(graceInterval: 900)
        integrationMachine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .codexCLI,
                host: "codex-cli",
                event: .turnStarted,
                pid: 44,
                processStartTime: baseline,
                integrationSessionId: "turn-3",
                eventID: "codex-turn-3-start"
            ),
            at: baseline
        )
        integrationMachine.applyIntegrationEvent(
            HookAdapterEvent(
                agent: .codexCLI,
                host: "codex-cli",
                event: .turnFinished,
                pid: 44,
                processStartTime: baseline.addingTimeInterval(100),
                integrationSessionId: "turn-3",
                eventID: "codex-turn-3-finish-stale"
            ),
            at: baseline.addingTimeInterval(10)
        )
        try check(integrationMachine.sessions.first?.state == .active, "Expected reused session IDs with mismatched process starts not to mutate sessions")

        integrationMachine.applyProcessObservations(
            [observation(pid: 44, start: baseline.addingTimeInterval(100), path: "/opt/homebrew/bin/codex", agent: .codexCLI)],
            at: baseline.addingTimeInterval(20)
        )
        try check(
            integrationMachine.sessions.contains { $0.source == .integrationEvent && $0.state == .finished },
            "Expected integration-created sessions to finish when the same pid reappears with a new start time"
        )
    }

    private static func claudePatcherPreservesExistingHooksAndRemovesOwnedHandlers() throws {
        let current = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  { "type": "command", "command": "/usr/local/bin/user-hook" }
                ]
              }
            ]
          }
        }
        """

        let patcher = ClaudeCodeConfigPatcher()
        let noOpRemoval = try patcher.removalPlan(currentData: Data(current.utf8))
        try check(noOpRemoval.patchedData == Data(current.utf8), "Expected Claude removal without owned hooks to be byte-stable")
        try check(!noOpRemoval.backupRequired, "Expected Claude no-op removal not to request backup")

        let install = try patcher.installPlan(currentData: Data(current.utf8), adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter")
        let installed = String(data: install.patchedData, encoding: .utf8) ?? ""

        try patcher.validate(install.patchedData)
        try check(installed.contains("user-hook"), "Expected Claude patcher to preserve existing hooks")
        try check(installed.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected Claude patcher to add owned hook marker")
        try check(installed.contains("UserPromptSubmit"), "Expected Claude patcher to add turn-start hook")
        try check(installed.contains("PostToolUse"), "Expected Claude patcher to add tool-continuing hook")

        let removal = try patcher.removalPlan(currentData: install.patchedData)
        let removed = String(data: removal.patchedData, encoding: .utf8) ?? ""
        try check(removed.contains("user-hook"), "Expected Claude removal to keep user hooks")
        try check(!removed.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected Claude removal to remove owned handlers")

        let legacyCurrent = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/Applications/ClawShell.app/Contents/MacOS/ClawShellHookAdapter' --mode claude-hook --agent claude-code --host claude-code --owner-marker com.clawshell.integration.claude-code.v1"
                  },
                  { "type": "command", "command": "/usr/local/bin/user-hook" }
                ]
              }
            ]
          }
        }
        """
        let legacyInstall = try patcher.installPlan(
            currentData: Data(legacyCurrent.utf8),
            adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
        )
        let legacyInstalled = String(data: legacyInstall.patchedData, encoding: .utf8) ?? ""
        try check(legacyInstalled.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected AgentWake install to add current Claude marker")
        try check(!legacyInstalled.contains("com.clawshell.integration.claude-code.v1"), "Expected AgentWake install to remove legacy Claude marker")
        try check(!legacyInstalled.contains("ClawShellHookAdapter"), "Expected AgentWake install to remove legacy Claude adapter command")
        try check(legacyInstalled.contains("user-hook"), "Expected AgentWake install to preserve user Claude hook beside legacy cleanup")
        let legacyRemoval = try patcher.removalPlan(currentData: Data(legacyCurrent.utf8))
        let legacyRemoved = String(data: legacyRemoval.patchedData, encoding: .utf8) ?? ""
        try check(!legacyRemoved.contains("com.clawshell.integration.claude-code.v1"), "Expected Claude removal to clean legacy owned hook")
        try check(!legacyRemoved.contains("ClawShellHookAdapter"), "Expected Claude removal to clean legacy adapter command")
        try check(legacyRemoved.contains("user-hook"), "Expected Claude legacy removal to preserve user hook")
    }

    private static func codexPatcherPreservesExistingNotifyAndRestoresItOnRemoval() throws {
        let current = """
        # user config
        model = "gpt-5.5"
        notify = ["/usr/local/bin/notify-user", "Codex"]

        [profiles.work]
        model = "gpt-5.4"
        """

        let patcher = CodexConfigPatcher()
        let install = try patcher.installPlan(currentData: Data(current.utf8), adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter")
        let installed = String(data: install.patchedData, encoding: .utf8) ?? ""

        try patcher.validate(install.patchedData)
        try check(installed.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex patcher to add owned block")
        try check(installed.contains("--forward-notify"), "Expected Codex patcher to forward previous notify command")
        try check(installed.contains("--mode codex-hook"), "Expected Codex patcher to add native hook command")
        try check(installed.contains("[[hooks.SessionStart]]"), "Expected Codex patcher to add session-start hook")
        try check(installed.contains("[[hooks.UserPromptSubmit]]"), "Expected Codex patcher to add turn-start hook")
        try check(installed.contains("[[hooks.PreToolUse]]"), "Expected Codex patcher to add pre-tool hook")
        try check(installed.contains("[[hooks.PostToolUse]]"), "Expected Codex patcher to add post-tool hook")
        try check(installed.contains("[[hooks.Stop]]"), "Expected Codex patcher to add stop hook")
        try check(installed.contains("timeout = 1"), "Expected Codex native hook command to have a short timeout")
        try check(installed.contains("[profiles.work]"), "Expected Codex patcher to preserve unrelated tables")

        let removal = try patcher.removalPlan(currentData: install.patchedData)
        let removed = String(data: removal.patchedData, encoding: .utf8) ?? ""
        try patcher.validate(removal.patchedData)
        try check(removed.contains(#"notify = ["/usr/local/bin/notify-user", "Codex"]"#), "Expected Codex removal to restore previous notify line")
        try check(!removed.contains(#""Codex"][profiles.work]"#), "Expected Codex removal not to glue restored notify to next table")
        try check(!removed.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex removal to remove owned block")
        try check(!removed.contains("[[hooks.UserPromptSubmit]]"), "Expected Codex removal to remove owned native hooks")
        let reinstall = try patcher.installPlan(currentData: install.patchedData, adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter")
        let reinstalled = String(data: reinstall.patchedData, encoding: .utf8) ?? ""
        try patcher.validate(reinstall.patchedData)
        try check(!reinstalled.contains("\(CodexConfigPatcher.manifest.ownerMarker)[profiles.work]"), "Expected Codex reinstall not to glue owned marker to next table")
        let endMarkerLine = "# END \(CodexConfigPatcher.manifest.ownerMarker)"
        let gluedEndMarker = installed
            .replacingOccurrences(of: "\(endMarkerLine)\n\n[profiles.work]", with: "\(endMarkerLine)[profiles.work]")
            .replacingOccurrences(of: "\(endMarkerLine)\n[profiles.work]", with: "\(endMarkerLine)[profiles.work]")
        try check(gluedEndMarker != installed, "Expected portable check fixture to contain a glueable owned end marker")
        let recoveredInstall = try patcher.installPlan(
            currentData: Data(gluedEndMarker.utf8),
            adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
        )
        let recoveredInstalled = String(data: recoveredInstall.patchedData, encoding: .utf8) ?? ""
        try patcher.validate(recoveredInstall.patchedData)
        try check(recoveredInstalled.contains("[profiles.work]"), "Expected Codex reinstall to preserve table glued to old end marker")
        try check(!recoveredInstalled.contains("\(CodexConfigPatcher.manifest.ownerMarker)[profiles.work]"), "Expected Codex reinstall to repair glued old end marker")

        let withUserHook = """
        [hooks.state."/tmp/user-hook:pre_tool_use:0:0"]
        enabled = true

        [[hooks.PreToolUse]]
        matcher = "^Bash$"

        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "/usr/local/bin/user-codex-hook"
        """
        let userHookInstall = try patcher.installPlan(
            currentData: Data(withUserHook.utf8),
            adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
        )
        let userHookInstalled = String(data: userHookInstall.patchedData, encoding: .utf8) ?? ""
        try check(userHookInstalled.contains("/usr/local/bin/user-codex-hook"), "Expected Codex install to preserve user native hook")
        try check(userHookInstalled.contains(#"[hooks.state."/tmp/user-hook:pre_tool_use:0:0"]"#), "Expected Codex install to preserve user hook state table")
        try check(userHookInstalled.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex install to add owned block beside user hooks")
        let userHookRemoval = try patcher.removalPlan(currentData: userHookInstall.patchedData)
        let userHookRemoved = String(data: userHookRemoval.patchedData, encoding: .utf8) ?? ""
        try patcher.validate(userHookRemoval.patchedData)
        try check(userHookRemoved.contains("/usr/local/bin/user-codex-hook"), "Expected Codex removal to preserve user native hook")
        try check(userHookRemoved.contains(#"[hooks.state."/tmp/user-hook:pre_tool_use:0:0"]"#), "Expected Codex removal to preserve user hook state table")
        try check(!userHookRemoved.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex removal to remove only owned native hook block")

        let legacyPreviousNotify = #"notify = ["/usr/local/bin/legacy-notify", "Codex"]"#
        let legacyPreviousNotifyBase64 = Data(legacyPreviousNotify.utf8).base64EncodedString()
        let legacyCodex = """
        # user config
        # BEGIN com.clawshell.integration.codex-cli.v1
        # ClawShell owns this top-level Codex notify fallback.
        # clawshell-previous-notify-base64: \(legacyPreviousNotifyBase64)
        notify = ["/Applications/ClawShell.app/Contents/MacOS/ClawShellHookAdapter", "--mode", "codex-notify", "--owner-marker", "com.clawshell.integration.codex-cli.v1"]
        # END com.clawshell.integration.codex-cli.v1

        # BEGIN com.clawshell.integration.codex-cli.v1
        # ClawShell owns these Codex native hooks.

        [[hooks.UserPromptSubmit]]
        [[hooks.UserPromptSubmit.hooks]]
        type = "command"
        command = "'/Applications/ClawShell.app/Contents/MacOS/ClawShellHookAdapter' --mode codex-hook --owner-marker 'com.clawshell.integration.codex-cli.v1'"
        timeout = 1

        # END com.clawshell.integration.codex-cli.v1

        [profiles.work]
        model = "gpt-5.4"
        """
        let legacyInstall = try patcher.installPlan(
            currentData: Data(legacyCodex.utf8),
            adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
        )
        let legacyInstalled = String(data: legacyInstall.patchedData, encoding: .utf8) ?? ""
        try patcher.validate(legacyInstall.patchedData)
        try check(legacyInstalled.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected AgentWake install to add current Codex marker")
        try check(legacyInstalled.contains("--forward-notify"), "Expected AgentWake install to forward notify restored from legacy block")
        try check(legacyInstalled.contains("[profiles.work]"), "Expected AgentWake legacy cleanup to preserve unrelated tables")
        try check(!legacyInstalled.contains("com.clawshell.integration.codex-cli.v1"), "Expected AgentWake install to remove legacy Codex marker")
        try check(!legacyInstalled.contains("ClawShellHookAdapter"), "Expected AgentWake install to remove legacy Codex adapter command")
        let legacyRemoval = try patcher.removalPlan(currentData: Data(legacyCodex.utf8))
        let legacyRemoved = String(data: legacyRemoval.patchedData, encoding: .utf8) ?? ""
        try patcher.validate(legacyRemoval.patchedData)
        try check(legacyRemoved.contains(legacyPreviousNotify), "Expected Codex legacy removal to restore previous notify")
        try check(legacyRemoved.contains("[profiles.work]"), "Expected Codex legacy removal to preserve unrelated tables")
        try check(!legacyRemoved.contains("com.clawshell.integration.codex-cli.v1"), "Expected Codex removal to clean legacy owned block")
        try check(!legacyRemoved.contains("ClawShellHookAdapter"), "Expected Codex removal to clean legacy adapter command")
    }

    private static func codexPatcherHandlesMultilineAndSingleQuotedNotify() throws {
        let current = """
        model = "gpt-5.5"
        notify = [
          '/usr/local/bin/notify-user', # comment with ] should not close the array
          'Codex',
        ]

        [profiles.work]
        model = "gpt-5.4"
        """

        let patcher = CodexConfigPatcher()
        let install = try patcher.installPlan(
            currentData: Data(current.utf8),
            adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
        )
        let installed = String(data: install.patchedData, encoding: .utf8) ?? ""

        try patcher.validate(install.patchedData)
        try check(installed.contains("--forward-notify"), "Expected multiline single-quoted notify to be forwarded")
        try check(installed.contains("[profiles.work]"), "Expected multiline notify install to preserve tables")

        let removal = try patcher.removalPlan(currentData: install.patchedData)
        let removed = String(data: removal.patchedData, encoding: .utf8) ?? ""
        try patcher.validate(removal.patchedData)
        try check(removed.contains("notify = ["), "Expected removal to restore multiline notify assignment")
        try check(removed.contains("'/usr/local/bin/notify-user'"), "Expected removal to restore single-quoted command")
        try check(removed.contains("'Codex'"), "Expected removal to restore single-quoted argument")
        try check(!removed.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected removal to delete owned block")

        let malformedOwnedBlock = """
        # BEGIN \(CodexConfigPatcher.manifest.ownerMarker)
        # BEGIN \(CodexConfigPatcher.manifest.ownerMarker)
        notify = ["/usr/local/bin/notify-user"]
        # END \(CodexConfigPatcher.manifest.ownerMarker)
        # END \(CodexConfigPatcher.manifest.ownerMarker)
        """
        try expectThrows("Expected nested owned Codex markers to be rejected") {
            try patcher.validate(Data(malformedOwnedBlock.utf8))
        }
    }

    private static func configPatchersRejectInvalidEncodingAndPreserveMarkerLookalikes() throws {
        let codexPatcher = CodexConfigPatcher()
        try expectThrows("Expected non-UTF-8 Codex config to be rejected") {
            _ = try codexPatcher.installPlan(
                currentData: Data([0xff, 0xfe, 0xfd]),
                adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
            )
        }

        let markerLookalike = """
        # BEGIN \(CodexConfigPatcher.manifest.ownerMarker) but user-owned
        notify = ["/usr/local/bin/notify-user"]
        # END \(CodexConfigPatcher.manifest.ownerMarker) but user-owned
        """
        let removal = try codexPatcher.removalPlan(currentData: Data(markerLookalike.utf8))
        let removed = String(data: removal.patchedData, encoding: .utf8) ?? ""
        try check(removed.contains("but user-owned"), "Expected marker lookalikes not to be treated as owned blocks")
        try check(removed.contains(#"notify = ["/usr/local/bin/notify-user"]"#), "Expected marker lookalike notify to remain")

        let claudeLookalike = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/local/bin/user-hook --note \(ClaudeCodeConfigPatcher.manifest.ownerMarker)"
                  }
                ]
              }
            ]
          }
        }
        """
        let claudeRemoval = try ClaudeCodeConfigPatcher().removalPlan(currentData: Data(claudeLookalike.utf8))
        let claudeRemoved = String(data: claudeRemoval.patchedData, encoding: .utf8) ?? ""
        try check(claudeRemoved.contains("user-hook"), "Expected Claude marker lookalike command to remain")
        try check(claudeRemoved.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected user-owned marker text to remain")
    }

    private static func integrationManagerRecordsRemovalSuppressionAndStatus() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let logStore = LogStore(paths: paths, now: { Date(timeIntervalSince1970: 9_500) })
        let settingsStore = SettingsStore(paths: paths, logStore: logStore)
        logStore.start()
        settingsStore.start()

        let manager = IntegrationManager(
            settingsStore: settingsStore,
            logStore: logStore,
            now: { Date(timeIntervalSince1970: 9_500) }
        )
        let message = try manager.removeIntegration(agentID: "codex-cli")

        try check(message.contains("suppressed"), "Expected removal message to mention suppression")
        try check(settingsStore.settings.integrationSuppressions["codex-cli"]?.doNotAutoInstall == true, "Expected removal to suppress auto-install")
        try check(settingsStore.settings.integrationStates["codex-cli"]?.status == .removed, "Expected removal state to be persisted")
        try check(logStore.events.contains { $0.kind == .integrationRemoval }, "Expected integration removal to be audited")
    }

    private static func integrationManagerAppliesConfigPatchesAndRemovesThem() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let configDirectory = paths.applicationSupportDirectory.appendingPathComponent("configs", isDirectory: true)
        let claudeURL = configDirectory.appendingPathComponent("claude-settings.json")
        let codexURL = configDirectory.appendingPathComponent("codex-config.toml")
        let locations = IntegrationInstallLocations(
            claudeSettingsURL: claudeURL,
            codexConfigURL: codexURL,
            adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
        )

        let logStore = LogStore(paths: paths, now: { Date(timeIntervalSince1970: 9_600) })
        let settingsStore = SettingsStore(paths: paths, logStore: logStore)
        logStore.start()
        settingsStore.start()

        let manager = IntegrationManager(
            settingsStore: settingsStore,
            logStore: logStore,
            autoInstallOnStart: true,
            installLocations: locations,
            homeDirectory: paths.applicationSupportDirectory.path,
            now: { Date(timeIntervalSince1970: 9_600) }
        )
        manager.start()

        let previews = manager.installPreviews()
        try check(previews.map(\.agentID) == ["claude-code", "codex-cli"], "Expected integration previews for built-in agents")
        try check(previews.allSatisfy { !$0.settingsFile.isEmpty }, "Expected integration previews to expose config paths")
        try check(previews.flatMap(\.dryRunDiff).contains { $0.contains("owned") }, "Expected integration previews to expose dry-run hook changes")

        let claudeInstalled = try String(contentsOf: claudeURL, encoding: .utf8)
        let codexInstalled = try String(contentsOf: codexURL, encoding: .utf8)
        try check(claudeInstalled.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected manager start to install Claude hooks")
        try check(codexInstalled.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected manager start to install Codex notify")
        try check(settingsStore.settings.integrationStates["claude-code"]?.status == .installed, "Expected Claude install state")
        try check(settingsStore.settings.integrationStates["codex-cli"]?.status == .installed, "Expected Codex install state")
        try check(!manager.statusMessage().contains(paths.applicationSupportDirectory.path), "Expected integration status to redact local home paths")
        try check(manager.statusMessage().contains("~/configs"), "Expected integration status to show redacted settings path")

        manager.start()
        let backupFilesAfterSecondStart = try FileManager.default.contentsOfDirectory(atPath: configDirectory.path)
            .filter { $0.contains(".agentwake-backup.") }
        try check(backupFilesAfterSecondStart.isEmpty, "Expected repeated auto-install to avoid backup churn when configs are unchanged")

        let removeMessage = try manager.removeAllIntegrations(at: Date(timeIntervalSince1970: 9_700))
        let claudeRemoved = try String(contentsOf: claudeURL, encoding: .utf8)
        let codexRemoved = try String(contentsOf: codexURL, encoding: .utf8)
        try check(removeMessage.contains("claude-code"), "Expected remove-all message to include Claude")
        try check(removeMessage.contains("codex-cli"), "Expected remove-all message to include Codex")
        try check(!claudeRemoved.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected Claude owned hook to be removed")
        try check(!codexRemoved.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex owned block to be removed")
        try check(settingsStore.settings.integrationSuppressions["claude-code"]?.doNotAutoInstall == true, "Expected Claude suppression after removal")
        try check(settingsStore.settings.integrationSuppressions["codex-cli"]?.doNotAutoInstall == true, "Expected Codex suppression after removal")

        let enableMessage = try manager.enableAutoInstall(agentID: "codex-cli")
        let codexReinstalled = try String(contentsOf: codexURL, encoding: .utf8)
        try check(enableMessage.contains("installed"), "Expected enable-auto to reinstall when locations are configured")
        try check(codexReinstalled.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex integration to reinstall")
        try check(settingsStore.settings.integrationSuppressions["codex-cli"] == nil, "Expected enable-auto to clear Codex suppression")
    }

    private static func integrationManagerSurfacesFailedInstallReasons() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let configDirectory = paths.applicationSupportDirectory.appendingPathComponent("configs", isDirectory: true)
        let claudeURL = configDirectory.appendingPathComponent("claude-settings.json")
        let codexURL = configDirectory.appendingPathComponent("codex-config.toml")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0xfd]).write(to: codexURL)

        let logStore = LogStore(paths: paths, now: { Date(timeIntervalSince1970: 9_800) })
        let settingsStore = SettingsStore(paths: paths, logStore: logStore)
        logStore.start()
        settingsStore.start()

        let manager = IntegrationManager(
            settingsStore: settingsStore,
            logStore: logStore,
            autoInstallOnStart: true,
            installLocations: IntegrationInstallLocations(
                claudeSettingsURL: claudeURL,
                codexConfigURL: codexURL,
                adapterPath: "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"
            ),
            now: { Date(timeIntervalSince1970: 9_800) }
        )
        manager.start()

        let failedState = settingsStore.settings.integrationStates["codex-cli"]
        try check(failedState?.status == .failed, "Expected failed Codex install state")
        try check(failedState?.failureReason?.contains("UTF-8") == true, "Expected failed install reason to be persisted")
        try check(manager.statusMessage().contains("reason="), "Expected integration status to surface failure reason")
        try check(
            logStore.events.contains {
                $0.kind == .integrationSetup && $0.metadata["failureReason"]?.contains("UTF-8") == true
            },
            "Expected failed install reason to be audited"
        )

        try expectThrows("Expected removal cleanup to fail on invalid Codex config") {
            _ = try manager.removeIntegration(agentID: "codex-cli")
        }
        try check(settingsStore.settings.integrationSuppressions["codex-cli"]?.doNotAutoInstall == true, "Expected failed removal cleanup to still suppress auto-install")
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
        try check(!store.settings.launchAtLogin, "Expected launch at login to default off until the user opts in")
        try check(store.settings.defaultGraceSeconds == 900, "Expected default grace to be 900 seconds")
        try check(store.settings.agents.map(\.id) == ["claude-code", "codex-cli"], "Expected Claude and Codex agent defaults")
        try check(
            store.settings.agents.first?.executableNames == ["claude", "claude-code"],
            "Expected Claude executable aliases to include claude and claude-code"
        )
        try check(store.settings.safety.batteryFloorPercent == 15, "Expected default battery floor")
        try check(!store.settings.hasCompletedOnboarding, "Expected onboarding to be incomplete by default")

        try store.setSafety(
            SafetySettings(
                temperatureWarningCelsius: 80,
                temperatureCutoffCelsius: 90,
                batteryFloorPercent: 20
            )
        )
        try check(store.settings.safety.batteryFloorPercent == 20, "Expected settings store to persist battery floor changes")
        try check(store.settings.safety.temperatureWarningCelsius == 80, "Expected settings store to persist temperature warning changes")
        try check(store.settings.safety.temperatureCutoffCelsius == 90, "Expected settings store to persist temperature cutoff changes")

        try store.pauseSleepProtection()
        try check(
            store.settings.manualOverrides.contains { $0.overrideKind == .pauseAll && $0.id == "user-pause" },
            "Expected settings store to persist user pause override"
        )
        try store.resumeSleepProtection()
        try check(
            !store.settings.manualOverrides.contains { $0.overrideKind == .pauseAll },
            "Expected settings store to clear user pause override"
        )
        try store.setAgentEnabled(agentID: "codex-cli", isEnabled: false)
        try check(
            store.settings.agents.first(where: { $0.id == "codex-cli" })?.isEnabled == false,
            "Expected settings store to disable an agent"
        )
        try store.setAgentEnabled(agentID: "codex-cli", isEnabled: true)
        try check(
            store.settings.agents.first(where: { $0.id == "codex-cli" })?.isEnabled == true,
            "Expected settings store to re-enable an agent"
        )
        try store.setLaunchAtLogin(true)
        try check(store.settings.launchAtLogin, "Expected settings store to persist launch-at-login opt-in")
        try store.setLaunchAtLogin(false)
        try check(!store.settings.launchAtLogin, "Expected settings store to persist launch-at-login opt-out")

        let settingsJSON = try String(contentsOf: paths.settingsURL, encoding: .utf8)
        try check(settingsJSON.contains("\"helperOwnership\" : null"), "Expected helperOwnership null placeholder")
        try check(settingsJSON.contains("\"hasCompletedOnboarding\" : false"), "Expected onboarding completion to be persisted")
    }

    private static func freshInstallSettingsCleanupClearsAutoInstallSuppressions() throws {
        let paths = try makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

        let logStore = LogStore(paths: paths)
        let store = SettingsStore(paths: paths, logStore: logStore)
        logStore.start()
        store.start()

        try store.recordIntegrationSuppression(agentID: "claude-code", reason: "removed-by-user")
        try store.recordIntegrationState(
            IntegrationState(
                agentID: "claude-code",
                status: .removed,
                integrationID: "com.agentwake.integration.claude-code.v1",
                settingsFile: "/Users/tester/.claude/settings.json"
            )
        )
        try check(FileManager.default.fileExists(atPath: paths.settingsURL.path), "Expected settings file before fresh cleanup")
        try check(store.settings.integrationSuppressions["claude-code"]?.doNotAutoInstall == true, "Expected removed hook to suppress auto-install")

        try store.removeSavedSettingsForFreshInstall()

        try check(!FileManager.default.fileExists(atPath: paths.settingsURL.path), "Expected fresh cleanup to remove settings file")
        try check(store.settings.integrationSuppressions.isEmpty, "Expected fresh cleanup to clear auto-install suppressions")
        try check(store.settings.integrationStates.isEmpty, "Expected fresh cleanup to clear removed integration state")

        let reloadedStore = SettingsStore(paths: paths, logStore: logStore)
        reloadedStore.start()
        try check(reloadedStore.settings.integrationSuppressions.isEmpty, "Expected next launch to recreate default settings without suppressions")
        try check(FileManager.default.fileExists(atPath: paths.settingsURL.path), "Expected next launch to recreate settings file")
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

        try check(store.settings == AgentWakeSettings(), "Expected corrupt settings to recover to defaults")
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

        var invalidGrace = AgentWakeSettings()
        invalidGrace.defaultGraceSeconds = -1
        try expectThrows("Expected invalid grace settings to be rejected") {
            try store.save(invalidGrace)
        }

        var invalidSafety = AgentWakeSettings()
        invalidSafety.safety = SafetySettings(
            temperatureWarningCelsius: 100,
            temperatureCutoffCelsius: 90,
            batteryFloorPercent: 150
        )
        try expectThrows("Expected invalid safety settings to be rejected") {
            try store.save(invalidSafety)
        }

        var invalidAgent = AgentWakeSettings()
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

        var settings = AgentWakeSettings()
        settings.defaultGraceSeconds = 1200
        settings.integrationSuppressions["codex-cli"] = IntegrationSuppression(reason: "user removed integration")
        settings.integrationStates["codex-cli"] = IntegrationState(
            agentID: "codex-cli",
            status: .installed,
            integrationID: "com.agentwake.integration.codex-cli.v1",
            settingsFile: "/Users/tester/.codex/config.toml"
        )
        settings.helperOwnership = HelperOwnership(owner: "root", installedAt: Date(timeIntervalSince1970: 1))
        try store.save(settings)

        let exportData = try store.exportData()
        let exportJSON = String(decoding: exportData, as: UTF8.self)

        try check(exportJSON.contains("defaultGraceSeconds"), "Expected grace settings in export")
        try check(exportJSON.contains("integrationSuppressions"), "Expected integration suppressions in export")
        try check(!exportJSON.contains("integrationStates"), "Expected local integration states to be excluded from export")
        try check(!exportJSON.contains(".codex/config.toml"), "Expected integration status paths to be excluded from export")
        try check(!exportJSON.contains("helperOwnership"), "Expected helper ownership to be excluded from export")
        try check(!exportJSON.contains("manualOverrides"), "Expected manual overrides to be excluded from export")
        try check(!exportJSON.contains("customAgents"), "Expected post-v1 custom agents to be excluded from export")
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
        try check(store.settings.integrationStates == settings.integrationStates, "Expected import to preserve local integration states")
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

    private static func makeTemporaryPaths() throws -> AgentWakePaths {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return AgentWakePaths(applicationSupportDirectory: url)
    }

    private static func safetyInput(
        temperature: Double,
        pressure: BagModeAppThermalPressure? = nil,
        battery: Int,
        now: Date
    ) -> BagModeSafetyInput {
        BagModeSafetyInput(
            temperature: .sample(BagModeTemperatureSample(celsius: temperature, capturedAt: now)),
            appThermalPressure: pressure,
            batteryPercent: battery,
            now: now
        )
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

    private static func observationWithMissingPath(
        pid: Int32,
        start: Date,
        processName: String = "codex",
        agent: AgentKind = .codexCLI
    ) -> AgentProcessObservation {
        let snapshot = ProcessSnapshot(
            pid: pid,
            processName: processName,
            executablePath: nil,
            processStartTime: start
        )

        return AgentProcessObservation(
            agent: agent,
            snapshot: snapshot,
            key: SessionKey(
                pid: pid,
                processStartTime: start,
                executablePathHash: StablePathHash.sha256("process:\(processName)"),
                executablePathHashIsVerified: false
            )
        )
    }

    private static func hookEvent(
        _ event: HookAdapterEventKind,
        integrationSessionId: String,
        pid: Int32,
        processStartTime: Date,
        agent: AgentKind = .codexCLI
    ) -> HookAdapterEvent {
        HookAdapterEvent(
            agent: agent,
            host: agent.rawValue,
            event: event,
            pid: pid,
            processStartTime: processStartTime,
            integrationSessionId: integrationSessionId
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

struct ThrowingSnapshotProvider: ProcessSnapshotProviding {
    func snapshots() throws -> [ProcessSnapshot] {
        throw CheckFailure("snapshot failure")
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

final class RecordingControlRouter: ControlCommandRouting {
    var commands: [ControlCommand] = []
    var receivedAt: [Date] = []

    func route(_ command: ControlCommand, receivedAt: Date) throws -> ControlResponse {
        commands.append(command)
        self.receivedAt.append(receivedAt)
        return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: "ok")
    }
}

final class RecordingControlClient: ControlClient {
    var commands: [ControlCommand] = []

    func send(_ command: ControlCommand) throws -> ControlResponse {
        commands.append(command)
        return ControlResponse(accepted: true, receiptTimestamp: Date(timeIntervalSince1970: 1), message: "ok")
    }
}

final class RecordingClosedLidModeCommandRunner: ClosedLidModeCommandRunning, @unchecked Sendable {
    var currentValue: Int
    var setValues: [Int] = []
    var readError: Error?
    var setError: Error?

    init(initialValue: Int, readError: Error? = nil, setError: Error? = nil) {
        self.currentValue = initialValue
        self.readError = readError
        self.setError = setError
    }

    func currentDisablesleep() throws -> Int {
        if let readError {
            throw readError
        }
        return currentValue
    }

    func setDisablesleep(_ value: Int) throws {
        setValues.append(value)
        if let setError {
            throw setError
        }
        currentValue = value
    }
}

final class RecordingPowerAssertionController: PowerAssertionControlling {
    var createdTypes: [PowerAssertionType] = []
    var releasedIDs: [PowerAssertionID] = []
    var createFailures: [PowerAssertionType: Error] = [:]
    var releaseFailures: Set<PowerAssertionID> = []
    private var nextID: UInt32 = 1

    func createAssertion(type: PowerAssertionType, reason: String) throws -> PowerAssertionID {
        createdTypes.append(type)
        if let failure = createFailures[type] {
            throw failure
        }
        defer { nextID += 1 }
        return PowerAssertionID(rawValue: nextID)
    }

    func releaseAssertion(_ id: PowerAssertionID) throws {
        releasedIDs.append(id)
        if releaseFailures.contains(id) {
            throw PowerAssertionError.releaseFailed(id: id, code: -1)
        }
    }
}
