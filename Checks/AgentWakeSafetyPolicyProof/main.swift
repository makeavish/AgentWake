import AgentWakeCore
import Darwin
import Foundation

@main
struct AgentWakeSafetyPolicyProof {
    static func main() {
        do {
            try run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let options = try ProofOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let outputDirectory = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
        try prepareOutputDirectory(outputDirectory)

        let now = Date(timeIntervalSince1970: 4_500)
        let policy = BagModeSafetyPolicy(
            settings: SafetySettings(
                temperatureWarningCelsius: 85,
                temperatureCutoffCelsius: 95,
                batteryFloorPercent: 15
            )
        )

        let rows = try proofCases(now: now).map { proofCase in
            let decision = policy.evaluate(
                previous: proofCase.previousState,
                input: proofCase.input,
                isBagModeArmed: proofCase.isBagModeArmed
            )
            let row = ProofRow(proofCase: proofCase, decision: decision)
            try row.assertExpected()
            return row
        }

        let failClosedRows = rows.filter { $0.proofCase.category == .failClosed }
        try check(!failClosedRows.isEmpty, "Expected fail-closed proof rows")
        try check(
            failClosedRows.allSatisfy { !$0.decision.canArmBagMode },
            "Expected every fail-closed row to block arming"
        )
        try check(
            failClosedRows.contains { $0.decision.action == .failClosedBeforeArming },
            "Expected at least one pre-arm fail-closed row"
        )
        try check(
            failClosedRows.contains { $0.decision.action == .releaseIfArmed },
            "Expected at least one armed release fail-closed row"
        )

        try writeValidationConfig(to: outputDirectory, failClosedRows: failClosedRows)
        try writeCaseTable(rows, to: outputDirectory.appendingPathComponent("fail-closed-cases.tsv"))
        try writeSummary(rows: rows, failClosedRows: failClosedRows, to: outputDirectory)

        print("Safety policy fail-closed proof written to \(outputDirectory.path)")
    }

    private static func proofCases(now: Date) -> [ProofCase] {
        let cases = [
            ProofCase(
                id: "warning-temperature",
                category: .warningOnly,
                input: safetyInput(temperature: 86, battery: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .warning,
                expectedAction: .warn,
                expectedReason: nil,
                expectedCanArm: true
            ),
            ProofCase(
                id: "supplemental-thermal-pressure",
                category: .warningOnly,
                input: safetyInput(temperature: 60, pressure: .serious, battery: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .warning,
                expectedAction: .warn,
                expectedReason: nil,
                expectedCanArm: true
            ),
            ProofCase(
                id: "temperature-cutoff-pre-arm",
                category: .failClosed,
                input: safetyInput(temperature: 96, battery: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .temperature,
                expectedCanArm: false
            ),
            ProofCase(
                id: "temperature-cutoff-armed",
                category: .failClosed,
                input: safetyInput(temperature: 96, battery: 80, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .temperature,
                expectedCanArm: false
            ),
            ProofCase(
                id: "battery-floor-pre-arm",
                category: .failClosed,
                input: safetyInput(temperature: 70, battery: 15, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .battery,
                expectedCanArm: false
            ),
            ProofCase(
                id: "battery-floor-armed",
                category: .failClosed,
                input: safetyInput(temperature: 70, battery: 15, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .battery,
                expectedCanArm: false
            ),
            ProofCase(
                id: "stale-reading-pre-arm",
                category: .failClosed,
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
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .staleSensor,
                expectedCanArm: false
            ),
            ProofCase(
                id: "stale-reading-armed",
                category: .failClosed,
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
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .staleSensor,
                expectedCanArm: false
            ),
            ProofCase(
                id: "nan-reading-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: .nan, capturedAt: now)),
                    batteryPercent: 80,
                    now: now
                ),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .parseFailed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "nan-reading-armed",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: .nan, capturedAt: now)),
                    batteryPercent: 80,
                    now: now
                ),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .parseFailed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "future-reading-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now.addingTimeInterval(1))),
                    batteryPercent: 80,
                    now: now
                ),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .parseFailed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "future-reading-armed",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now.addingTimeInterval(1))),
                    batteryPercent: 80,
                    now: now
                ),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .parseFailed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "unavailable-provider-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .unavailable, batteryPercent: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .unavailableSensor,
                expectedCanArm: false
            ),
            ProofCase(
                id: "unavailable-provider-armed",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .unavailable, batteryPercent: 80, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .unavailableSensor,
                expectedCanArm: false
            ),
            ProofCase(
                id: "permission-denied-provider-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .permissionDenied, batteryPercent: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .permissionDenied,
                expectedCanArm: false
            ),
            ProofCase(
                id: "permission-denied-provider-armed",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .permissionDenied, batteryPercent: 80, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .permissionDenied,
                expectedCanArm: false
            ),
            ProofCase(
                id: "parse-failed-provider-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .parseFailed, batteryPercent: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .parseFailed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "parse-failed-provider-armed",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .parseFailed, batteryPercent: 80, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .parseFailed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "helper-crashed-provider-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .helperCrashed, batteryPercent: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .helperCrashed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "helper-crashed-provider-armed",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .helperCrashed, batteryPercent: 80, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .helperCrashed,
                expectedCanArm: false
            ),
            ProofCase(
                id: "unsupported-hardware-provider-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .unsupportedHardware, batteryPercent: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .unsupportedHardware,
                expectedCanArm: false
            ),
            ProofCase(
                id: "unsupported-hardware-provider-armed",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .unsupportedHardware, batteryPercent: 80, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .unsupportedHardware,
                expectedCanArm: false
            ),
            ProofCase(
                id: "timeout-provider-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .timedOut, batteryPercent: 80, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .timedOut,
                expectedCanArm: false
            ),
            ProofCase(
                id: "timeout-provider-armed",
                category: .failClosed,
                input: BagModeSafetyInput(temperature: .timedOut, batteryPercent: 80, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .timedOut,
                expectedCanArm: false
            ),
            ProofCase(
                id: "closed-bag-coverage-insufficient-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(
                        BagModeTemperatureSample(celsius: 70, capturedAt: now, coversClosedBagRisk: false)
                    ),
                    batteryPercent: 80,
                    now: now
                ),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .coverageInsufficient,
                expectedCanArm: false
            ),
            ProofCase(
                id: "closed-bag-coverage-insufficient-armed",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(
                        BagModeTemperatureSample(celsius: 70, capturedAt: now, coversClosedBagRisk: false)
                    ),
                    batteryPercent: 80,
                    now: now
                ),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .coverageInsufficient,
                expectedCanArm: false
            ),
            ProofCase(
                id: "missing-battery-pre-arm",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now)),
                    batteryPercent: nil,
                    now: now
                ),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .batteryUnavailable,
                expectedCanArm: false
            ),
            ProofCase(
                id: "missing-battery-armed",
                category: .failClosed,
                input: BagModeSafetyInput(
                    temperature: .sample(BagModeTemperatureSample(celsius: 70, capturedAt: now)),
                    batteryPercent: nil,
                    now: now
                ),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .batteryUnavailable,
                expectedCanArm: false
            ),
            ProofCase(
                id: "invalid-battery-pre-arm",
                category: .failClosed,
                input: safetyInput(temperature: 70, battery: 999, now: now),
                isBagModeArmed: false,
                expectedMode: .cutoffLockedOut,
                expectedAction: .failClosedBeforeArming,
                expectedReason: .batteryInvalid,
                expectedCanArm: false
            ),
            ProofCase(
                id: "invalid-battery-armed",
                category: .failClosed,
                input: safetyInput(temperature: 70, battery: 999, now: now),
                isBagModeArmed: true,
                expectedMode: .cutoffLockedOut,
                expectedAction: .releaseIfArmed,
                expectedReason: .batteryInvalid,
                expectedCanArm: false
            )
        ]
        return cases
    }

    private static func prepareOutputDirectory(_ outputDirectory: URL) throws {
        let fileManager = FileManager.default
        let ownedArtifactNames = Set(["validation-config.txt", "fail-closed-cases.tsv", "summary.md"])
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory) {
            let values = try outputDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ProofError("output directory must not be a symlink: \(outputDirectory.path)")
            }
            guard isDirectory.boolValue else {
                throw ProofError("output path is not a directory: \(outputDirectory.path)")
            }

            let existingNames = try fileManager.contentsOfDirectory(atPath: outputDirectory.path)
            let unexpectedNames = existingNames.filter { $0 != ".DS_Store" && !ownedArtifactNames.contains($0) }
            guard unexpectedNames.isEmpty else {
                throw ProofError("output directory contains unexpected files: \(unexpectedNames.sorted().joined(separator: ", "))")
            }

            for name in existingNames where ownedArtifactNames.contains(name) {
                try fileManager.removeItem(at: outputDirectory.appendingPathComponent(name))
            }
            return
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private static func writeValidationConfig(to outputDirectory: URL, failClosedRows: [ProofRow]) throws {
        let config = """
        evidenceFormat=safety-policy-fail-closed-proof-v1
        metadataRedacted=true
        providerRuntime=mocked-policy-inputs
        helperOwned=false
        numericCutoffSource=false
        failClosedContract=covered
        failClosedCaseCount=\(failClosedRows.count)
        preArmBlockCovered=\(failClosedRows.contains { $0.decision.action == .failClosedBeforeArming })
        armedReleaseCovered=\(failClosedRows.contains { $0.decision.action == .releaseIfArmed })
        userFacingDiagnosticsCovered=\(failClosedRows.allSatisfy { BagModeSafetyDiagnostic.userFacing(for: $0.decision) != nil })
        result=pass
        """
        try write(config + "\n", to: outputDirectory.appendingPathComponent("validation-config.txt"))
    }

    private static func writeCaseTable(_ rows: [ProofRow], to url: URL) throws {
        var lines = [
            [
                "caseID",
                "category",
                "armed",
                "expectedMode",
                "actualMode",
                "expectedReason",
                "actualReason",
                "expectedAction",
                "actualAction",
                "expectedCanArm",
                "actualCanArm",
                "shouldReleaseIfArmed",
                "diagnosticTitle",
                "diagnosticDetail",
                "diagnosticRecoveryAction",
                "result"
            ].joined(separator: "\t")
        ]
        lines.append(contentsOf: rows.map(\.tsvLine))
        try write(lines.joined(separator: "\n") + "\n", to: url)
    }

    private static func writeSummary(rows: [ProofRow], failClosedRows: [ProofRow], to outputDirectory: URL) throws {
        let failClosedCases = failClosedRows
            .map { row in
                let diagnostic = BagModeSafetyDiagnostic.userFacing(for: row.decision)
                return "- \(row.proofCase.id): \(row.decision.state.cutoffReason?.rawValue ?? "none") -> \(row.decision.action.rawValue) — \(diagnostic?.title ?? "no diagnostic")"
            }
            .joined(separator: "\n")
        let summary = """
        # Safety Policy Fail-Closed Proof

        This artifact exercises `BagModeSafetyPolicy` with mocked provider and battery inputs.
        It does not select or validate a production numeric provider.

        ## Result

        - Result: pass
        - Total cases: \(rows.count)
        - Fail-closed cases: \(failClosedRows.count)
        - Pre-arm block covered: \(failClosedRows.contains { $0.decision.action == .failClosedBeforeArming })
        - Armed release covered: \(failClosedRows.contains { $0.decision.action == .releaseIfArmed })
        - User-facing diagnostics covered: \(failClosedRows.allSatisfy { BagModeSafetyDiagnostic.userFacing(for: $0.decision) != nil })

        ## Fail-Closed Cases

        \(failClosedCases)

        ## Boundary

        This proves the policy contract for unsupported, stale, malformed, timed-out, insufficient-coverage, and missing battery states. It is not helper-owned provider freshness, cadence, closed-bag hardware coverage, or numeric scale proof.
        """
        try write(summary, to: outputDirectory.appendingPathComponent("summary.md"))
    }

    private static func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw ProofError("failed to encode \(url.path)")
        }
        try data.write(to: url, options: [.atomic])
    }
}

private struct ProofOptions {
    var outputDirectory: String

    init(arguments: [String]) throws {
        var outputDirectory: String?
        var remaining = arguments

        while !remaining.isEmpty {
            let argument = remaining.removeFirst()
            switch argument {
            case "--output-dir":
                guard let value = remaining.first else {
                    throw ProofError("--output-dir requires a value")
                }
                remaining.removeFirst()
                outputDirectory = value
            default:
                throw ProofError("unknown option: \(argument)")
            }
        }

        guard let outputDirectory else {
            throw ProofError("--output-dir is required")
        }
        self.outputDirectory = outputDirectory
    }
}

private enum ProofCategory: String {
    case warningOnly = "warning-only"
    case failClosed = "fail-closed"
}

private struct ProofCase {
    var id: String
    var category: ProofCategory
    var input: BagModeSafetyInput
    var isBagModeArmed: Bool
    var previousState: BagModeSafetyState = BagModeSafetyState()
    var expectedMode: BagModeSafetyMode
    var expectedAction: BagModeSafetyAction
    var expectedReason: BagModeSafetyCutoffReason?
    var expectedCanArm: Bool
}

private struct ProofRow {
    var proofCase: ProofCase
    var decision: BagModeSafetyDecision

    var tsvLine: String {
        let diagnostic = BagModeSafetyDiagnostic.userFacing(for: decision)
        return [
            proofCase.id,
            proofCase.category.rawValue,
            String(proofCase.isBagModeArmed),
            proofCase.expectedMode.rawValue,
            decision.state.mode.rawValue,
            proofCase.expectedReason?.rawValue ?? "none",
            decision.state.cutoffReason?.rawValue ?? "none",
            proofCase.expectedAction.rawValue,
            decision.action.rawValue,
            String(proofCase.expectedCanArm),
            String(decision.canArmBagMode),
            String(decision.shouldReleaseIfArmed),
            diagnostic?.title ?? "",
            diagnostic?.detail ?? "",
            diagnostic?.recoveryAction ?? "",
            "pass"
        ].map(escapeTSV).joined(separator: "\t")
    }

    func assertExpected() throws {
        try check(decision.state.mode == proofCase.expectedMode, "\(proofCase.id) mode mismatch")
        try check(decision.action == proofCase.expectedAction, "\(proofCase.id) action mismatch")
        try check(decision.state.cutoffReason == proofCase.expectedReason, "\(proofCase.id) reason mismatch")
        try check(decision.canArmBagMode == proofCase.expectedCanArm, "\(proofCase.id) can-arm mismatch")
        if proofCase.category == .failClosed || proofCase.category == .warningOnly {
            let diagnostic = try checkNotNil(
                BagModeSafetyDiagnostic.userFacing(for: decision),
                "\(proofCase.id) missing user-facing diagnostic"
            )
            try check(!diagnostic.title.isEmpty, "\(proofCase.id) diagnostic title is empty")
            try check(!diagnostic.detail.isEmpty, "\(proofCase.id) diagnostic detail is empty")
            try check(diagnostic.recoveryAction?.isEmpty == false, "\(proofCase.id) diagnostic recovery action is empty")
        }
    }
}

private func escapeTSV(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

private func checkNotNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw ProofError(message)
    }
    return value
}

private func safetyInput(
    temperature: Double,
    pressure: BagModeAppThermalPressure? = nil,
    battery: Int?,
    now: Date
) -> BagModeSafetyInput {
    BagModeSafetyInput(
        temperature: .sample(BagModeTemperatureSample(celsius: temperature, capturedAt: now)),
        appThermalPressure: pressure,
        batteryPercent: battery,
        now: now
    )
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw ProofError(message)
    }
}

private struct ProofError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
