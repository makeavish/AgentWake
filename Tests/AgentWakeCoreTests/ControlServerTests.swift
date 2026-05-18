import Foundation

#if canImport(Testing)
import Testing
@testable import AgentWakeCore

struct ControlServerTests {
    @Test func runtimeStoreCreatesPrivateDirectoryAndRotatingToken() throws {
        try runRuntimeStoreCreatesPrivateDirectoryAndRotatingToken()
    }

    @Test func controlServerRejectsAuthReplayAndRateLimitFailures() throws {
        try runControlServerRejectsAuthReplayAndRateLimitFailures()
    }

    @Test func controlServerRateLimitsPerProcessAndTokenBackstop() throws {
        try runControlServerRateLimitsPerProcessAndTokenBackstop()
    }

    @Test func replayCacheExpiresOldEvents() throws {
        try runReplayCacheExpiresOldEvents()
    }

    @Test func controlServerRejectsInvalidPauseDurations() throws {
        try runControlServerRejectsInvalidPauseDurations()
    }

    @Test func serverUsesReceiptTimeInsteadOfClientTimestamp() throws {
        try runServerUsesReceiptTimeInsteadOfClientTimestamp()
    }

    @Test func cliParsesCommandsAndSendsThroughClient() throws {
        try runCLIParsesCommandsAndSendsThroughClient()
    }

    @Test func cliRejectsExtraArgumentsAndUnknownFlags() throws {
        try runCLIRejectsExtraArgumentsAndUnknownFlags()
    }

    @Test func controlRouterSurfacesHelperCommandOutcomes() throws {
        try runControlRouterSurfacesHelperCommandOutcomes()
    }

    @Test func localControlClientSendsThroughUnixSocket() throws {
        try runLocalControlClientSendsThroughUnixSocket()
    }

    @Test func socketEndpointRejectsAuthReplayAndClientPIDRotation() throws {
        try runSocketEndpointRejectsAuthReplayAndClientPIDRotation()
    }

    @Test func controlServerComponentRotatesTokenAndClearsRuntime() throws {
        try runControlServerComponentRotatesTokenAndClearsRuntime()
    }
}

#elseif canImport(XCTest)
import XCTest
@testable import AgentWakeCore

final class ControlServerTests: XCTestCase {
    func testRuntimeStoreCreatesPrivateDirectoryAndRotatingToken() throws {
        try runRuntimeStoreCreatesPrivateDirectoryAndRotatingToken()
    }

    func testControlServerRejectsAuthReplayAndRateLimitFailures() throws {
        try runControlServerRejectsAuthReplayAndRateLimitFailures()
    }

    func testControlServerRateLimitsPerProcessAndTokenBackstop() throws {
        try runControlServerRateLimitsPerProcessAndTokenBackstop()
    }

    func testReplayCacheExpiresOldEvents() throws {
        try runReplayCacheExpiresOldEvents()
    }

    func testControlServerRejectsInvalidPauseDurations() throws {
        try runControlServerRejectsInvalidPauseDurations()
    }

    func testServerUsesReceiptTimeInsteadOfClientTimestamp() throws {
        try runServerUsesReceiptTimeInsteadOfClientTimestamp()
    }

    func testCLIParsesCommandsAndSendsThroughClient() throws {
        try runCLIParsesCommandsAndSendsThroughClient()
    }

    func testCLIRejectsExtraArgumentsAndUnknownFlags() throws {
        try runCLIRejectsExtraArgumentsAndUnknownFlags()
    }

    func testControlRouterSurfacesHelperCommandOutcomes() throws {
        try runControlRouterSurfacesHelperCommandOutcomes()
    }

    func testLocalControlClientSendsThroughUnixSocket() throws {
        try runLocalControlClientSendsThroughUnixSocket()
    }

    func testSocketEndpointRejectsAuthReplayAndClientPIDRotation() throws {
        try runSocketEndpointRejectsAuthReplayAndClientPIDRotation()
    }

    func testControlServerComponentRotatesTokenAndClearsRuntime() throws {
        try runControlServerComponentRotatesTokenAndClearsRuntime()
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run AgentWakeCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private func runRuntimeStoreCreatesPrivateDirectoryAndRotatingToken() throws {
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

private func runControlServerRejectsAuthReplayAndRateLimitFailures() throws {
    let now = Date(timeIntervalSince1970: 5_000)
    let router = RecordingRouter()
    let server = ControlServer(
        token: "secret",
        router: router,
        maxEventsPerWindow: 2,
        rateLimitWindow: 60,
        now: { now }
    )

    try expectThrows(ControlServerError.unauthenticated) {
        _ = try server.handle(ControlRequest(token: "wrong", eventID: "bad", command: .releaseNow))
    }
    try check(router.commands.isEmpty, "Expected unauthenticated commands not to reach the router")

    _ = try server.handle(ControlRequest(token: "secret", eventID: "a", processID: 1, command: .status))
    try expectThrows(ControlServerError.replayedEvent) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "a", processID: 1, command: .status))
    }

    _ = try server.handle(ControlRequest(token: "secret", eventID: "b", processID: 1, command: .status))
    try expectThrows(ControlServerError.rateLimited) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "c", processID: 1, command: .status))
    }
}

private func runControlServerRateLimitsPerProcessAndTokenBackstop() throws {
    var current = Date(timeIntervalSince1970: 5_000)
    let server = ControlServer(
        token: "secret",
        router: RecordingRouter(),
        maxEventsPerWindow: 2,
        maxTokenEventsPerWindow: 4,
        rateLimitWindow: 60,
        now: { current }
    )

    _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-a", processID: 1, command: .status))
    _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-b", processID: 1, command: .status))
    try expectThrows(ControlServerError.rateLimited) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-c", processID: 1, command: .status))
    }

    _ = try server.handle(ControlRequest(token: "secret", eventID: "p2-a", processID: 2, command: .status))
    _ = try server.handle(ControlRequest(token: "secret", eventID: "p3-a", processID: 3, command: .status))
    try expectThrows(ControlServerError.rateLimited) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "p4-a", processID: 4, command: .status))
    }

    current = current.addingTimeInterval(61)
    _ = try server.handle(ControlRequest(token: "secret", eventID: "p1-d", processID: 1, command: .status))
}

private func runReplayCacheExpiresOldEvents() throws {
    var current = Date(timeIntervalSince1970: 7_000)
    let server = ControlServer(
        token: "secret",
        router: RecordingRouter(),
        replayTTL: 10,
        now: { current }
    )

    _ = try server.handle(ControlRequest(token: "secret", eventID: "repeatable", command: .status))
    try expectThrows(ControlServerError.replayedEvent) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "repeatable", command: .status))
    }

    current = current.addingTimeInterval(11)
    _ = try server.handle(ControlRequest(token: "secret", eventID: "repeatable", command: .status))
}

private func runControlServerRejectsInvalidPauseDurations() throws {
    let router = RecordingRouter()
    let server = ControlServer(token: "secret", router: router)

    try expectThrows(ControlServerError.invalidRequest("pause requires a positive finite duration")) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "zero-pause", command: .pause(duration: 0)))
    }
    try expectThrows(ControlServerError.invalidRequest("pause requires a positive finite duration")) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "negative-pause", command: .pause(duration: -1)))
    }
    try expectThrows(ControlServerError.invalidRequest("pause requires a positive finite duration")) {
        _ = try server.handle(ControlRequest(token: "secret", eventID: "infinite-pause", command: .pause(duration: .infinity)))
    }

    try check(router.commands.isEmpty, "Expected invalid pause commands not to reach router")
}

private func runServerUsesReceiptTimeInsteadOfClientTimestamp() throws {
    let receiptTime = Date(timeIntervalSince1970: 6_000)
    let clientTime = Date(timeIntervalSince1970: 1)
    let router = RecordingRouter()
    let server = ControlServer(token: "secret", router: router, now: { receiptTime })

    let response = try server.handle(
        ControlRequest(
            token: "secret",
            eventID: "receipt",
            clientTimestamp: clientTime,
            command: .pause(duration: 3_600)
        )
    )

    try check(response.receiptTimestamp == receiptTime, "Expected response to use server receipt time")
    try check(router.receivedAt == [receiptTime], "Expected router to receive server receipt time")
}

private func runCLIParsesCommandsAndSendsThroughClient() throws {
    let client = RecordingClient()
    let cli = AgentWakeCLI(client: client)

    let statusOutput = try cli.run(arguments: ["agentwake", "status"])
    try check(statusOutput == "ok", "Expected status output from client")
    try check(client.commands.last == .status, "Expected status command")
    _ = try cli.run(arguments: ["agentwake", "pause", "1h"])
    try check(client.commands.last == .pause(duration: 3_600), "Expected pause command")
    _ = try cli.run(arguments: ["agentwake", "release", "now"])
    try check(client.commands.last == .releaseNow, "Expected release now command")
    _ = try cli.run(arguments: ["agentwake", "protect", "detected"])
    try check(client.commands.last == .protectDetectedSessions, "Expected protect detected command")
    _ = try cli.run(arguments: ["agentwake", "list"])
    try check(client.commands.last == .list, "Expected list command")
    _ = try cli.run(arguments: ["agentwake", "add", "/usr/local/bin/agent"])
    try check(client.commands.last == .add(binary: "/usr/local/bin/agent"), "Expected add command")
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
    _ = try cli.run(arguments: ["agentwake", "helper", "enable-closed-lid"])
    try check(client.commands.last == .helperEnableBagMode, "Expected helper closed-lid enable command")
    _ = try cli.run(arguments: ["agentwake", "helper", "disable-closed-lid"])
    try check(client.commands.last == .helperDisableBagMode, "Expected helper closed-lid disable command")
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

private func runCLIRejectsExtraArgumentsAndUnknownFlags() throws {
    let cli = AgentWakeCLI(client: RecordingClient())

    try expectThrows(ControlServerError.invalidRequest("status takes no arguments")) {
        _ = try cli.parse(arguments: ["status", "extra"])
    }
    try expectThrows(ControlServerError.invalidRequest("release requires `now`")) {
        _ = try cli.parse(arguments: ["release", "now", "again"])
    }
    try expectThrows(ControlServerError.invalidRequest("protect requires `detected`")) {
        _ = try cli.parse(arguments: ["protect", "seen"])
    }
    try expectThrows(ControlServerError.invalidRequest("integrations list takes no arguments")) {
        _ = try cli.parse(arguments: ["integrations", "list", "--verbose"])
    }
    try expectThrows(ControlServerError.invalidRequest("helper status takes no arguments")) {
        _ = try cli.parse(arguments: ["helper", "status", "--json"])
    }
    try expectThrows(ControlServerError.invalidRequest("closed-lid status takes no arguments")) {
        _ = try cli.parse(arguments: ["closed-lid", "status", "--json"])
    }
    try expectThrows(ControlServerError.invalidRequest("unknown closed-lid subcommand: arm")) {
        _ = try cli.parse(arguments: ["closed-lid", "arm"])
    }
    try expectThrows(ControlServerError.invalidRequest("helper uninstall takes no arguments")) {
        _ = try cli.parse(arguments: ["helper", "uninstall", "--force"])
    }
    try expectThrows(ControlServerError.invalidRequest("unknown uninstall flag: --everything")) {
        _ = try cli.parse(arguments: ["uninstall", "--everything"])
    }
    try expectThrows(ControlServerError.invalidRequest("uninstall --remove-settings requires --remove-integrations")) {
        _ = try cli.parse(arguments: ["uninstall", "--remove-settings"])
    }
}

private func runControlRouterSurfacesHelperCommandOutcomes() throws {
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

    try check(defaultStatus.message == ClosedLidModeAvailability.helperCommandMessage("status"), "Expected default helper status outcome")
    try check(defaultEnable.message == ClosedLidModeAvailability.helperCommandMessage("enable"), "Expected default helper enable outcome")
    try check(defaultDisable.message == ClosedLidModeAvailability.helperCommandMessage("disable"), "Expected default helper disable outcome")
    try check(defaultRepair.message == ClosedLidModeAvailability.helperCommandMessage("repair"), "Expected default helper repair outcome")
    try check(defaultUninstall.message == ClosedLidModeAvailability.helperCommandMessage("uninstall"), "Expected default helper uninstall outcome")
    try check(defaultClosedLidStatus.message == ClosedLidModeAvailability.helperCommandMessage("status"), "Expected default closed-lid status outcome")
    try check(defaultClosedLidEnable.message == ClosedLidModeAvailability.helperCommandMessage("enable"), "Expected default closed-lid enable outcome")
    try check(defaultClosedLidDisable.message == ClosedLidModeAvailability.helperCommandMessage("disable"), "Expected default closed-lid disable outcome")
    try check(defaultProtectDetected.message == "No detected sessions to protect", "Expected default protect-detected outcome")

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

private func runLocalControlClientSendsThroughUnixSocket() throws {
    let paths = try makeTemporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

    let store = ControlRuntimeStore(paths: paths)
    let token = try store.rotateToken()
    let router = RecordingRouter()
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

private func runSocketEndpointRejectsAuthReplayAndClientPIDRotation() throws {
    let paths = try makeTemporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

    let store = ControlRuntimeStore(paths: paths)
    let token = try store.rotateToken()
    let server = ControlServer(
        token: token,
        router: RecordingRouter(),
        maxEventsPerWindow: 1,
        maxTokenEventsPerWindow: 10,
        rateLimitWindow: 60,
        now: { Date(timeIntervalSince1970: 8_500) }
    )
    let socketServer = ControlSocketServer(runtimeStore: store)
    try socketServer.start(controlServer: server)
    defer { socketServer.stop() }

    try expectThrows(ControlServerError.invalidRequest("Control request was not authenticated.")) {
        _ = try UnixControlSocketClient.send(
            ControlRequest(token: "wrong", eventID: "wrong-token", processID: 111, command: .status),
            to: paths.controlSocketURL
        )
    }

    _ = try UnixControlSocketClient.send(
        ControlRequest(token: token, eventID: "accepted", processID: 111, command: .status),
        to: paths.controlSocketURL
    )
    try expectThrows(ControlServerError.invalidRequest("Control request was already processed.")) {
        _ = try UnixControlSocketClient.send(
            ControlRequest(token: token, eventID: "accepted", processID: 111, command: .status),
            to: paths.controlSocketURL
        )
    }
    try expectThrows(ControlServerError.invalidRequest("Too many control requests. Try again in a moment.")) {
        _ = try UnixControlSocketClient.send(
            ControlRequest(token: token, eventID: "fake-pid", processID: 222, command: .status),
            to: paths.controlSocketURL
        )
    }
}

private func runControlServerComponentRotatesTokenAndClearsRuntime() throws {
    let paths = try makeTemporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

    let store = ControlRuntimeStore(paths: paths)
    let component = ControlServerComponent(runtimeStore: store, router: RecordingRouter())
    component.start()

    try check(component.runState == .started, "Expected control server component to start: \(String(describing: component.lastError))")
    try check(FileManager.default.fileExists(atPath: paths.hookTokenURL.path), "Expected component start to rotate token")
    try check(FileManager.default.fileExists(atPath: paths.controlSocketURL.path), "Expected component start to bind socket")

    component.stop()

    try check(component.runState == .stopped, "Expected control server component to stop")
    try check(!FileManager.default.fileExists(atPath: paths.hookTokenURL.path), "Expected component stop to clear token")
    try check(!FileManager.default.fileExists(atPath: paths.controlSocketURL.path), "Expected component stop to clear socket")
}

private final class RecordingRouter: ControlCommandRouting {
    var commands: [ControlCommand] = []
    var receivedAt: [Date] = []

    func route(_ command: ControlCommand, receivedAt: Date) throws -> ControlResponse {
        commands.append(command)
        self.receivedAt.append(receivedAt)
        return ControlResponse(accepted: true, receiptTimestamp: receivedAt, message: "ok")
    }
}

private final class RecordingClient: ControlClient {
    var commands: [ControlCommand] = []

    func send(_ command: ControlCommand) throws -> ControlResponse {
        commands.append(command)
        return ControlResponse(accepted: true, receiptTimestamp: Date(timeIntervalSince1970: 1), message: "ok")
    }
}

private func makeTemporaryPaths() throws -> AgentWakePaths {
    let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("cs-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return AgentWakePaths(applicationSupportDirectory: url)
}

private func expectThrows<E: Error & Equatable>(_ expected: E, operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as E {
        try check(error == expected, "Expected \(expected), got \(error)")
        return
    }

    throw TestFailure("Expected \(expected) to be thrown")
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(message)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
