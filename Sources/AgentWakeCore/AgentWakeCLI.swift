import Darwin
import Foundation

public protocol ControlClient {
    func send(_ command: ControlCommand) throws -> ControlResponse
}

public struct AgentWakeCLI {
    public var client: ControlClient

    public init(client: ControlClient) {
        self.client = client
    }

    public func run(arguments: [String]) throws -> String {
        let command = try parse(arguments: Array(arguments.dropFirst()))
        let response = try client.send(command)
        return response.message
    }

    public func parse(arguments: [String]) throws -> ControlCommand {
        guard let first = arguments.first else {
            throw ControlServerError.invalidRequest("missing command")
        }

        switch first {
        case "status":
            try requireArgumentCount(arguments, 1, usage: "status takes no arguments")
            return .status
        case "pause":
            try requireArgumentCount(arguments, 2, usage: "pause requires a duration like 1h or 15m")
            guard let duration = arguments.dropFirst().first.flatMap(parseDuration) else {
                throw ControlServerError.invalidRequest("pause requires a duration like 1h or 15m")
            }
            return .pause(duration: duration)
        case "release":
            try requireArgumentCount(arguments, 2, usage: "release requires `now`")
            guard arguments.dropFirst().first == "now" else {
                throw ControlServerError.invalidRequest("release requires `now`")
            }
            return .releaseNow
        case "protect":
            try requireArgumentCount(arguments, 2, usage: "protect requires `detected`")
            guard arguments.dropFirst().first == "detected" else {
                throw ControlServerError.invalidRequest("protect requires `detected`")
            }
            return .protectDetectedSessions
        case "list":
            try requireArgumentCount(arguments, 1, usage: "list takes no arguments")
            return .list
        case "add":
            try requireArgumentCount(arguments, 2, usage: "add requires a binary path")
            guard let binary = arguments.dropFirst().first else {
                throw ControlServerError.invalidRequest("add requires a binary path")
            }
            return .add(binary: binary)
        case "integrations":
            return try parseIntegrations(Array(arguments.dropFirst()))
        case "closed-lid":
            return try parseClosedLidMode(Array(arguments.dropFirst()))
        case "helper":
            return try parseHelper(Array(arguments.dropFirst()))
        case "uninstall":
            let flags = Array(arguments.dropFirst())
            let allowedFlags = Set(["--remove-helper", "--remove-integrations"])
            guard flags.allSatisfy({ allowedFlags.contains($0) }) else {
                let unknownFlag = flags.first { !allowedFlags.contains($0) } ?? ""
                throw ControlServerError.invalidRequest("unknown uninstall flag: \(unknownFlag)")
            }
            guard Set(flags).count == flags.count else {
                throw ControlServerError.invalidRequest("duplicate uninstall flag")
            }
            return .uninstall(
                removeHelper: flags.contains("--remove-helper"),
                removeIntegrations: flags.contains("--remove-integrations")
            )
        default:
            throw ControlServerError.invalidRequest("unknown command: \(first)")
        }
    }

    private func parseIntegrations(_ arguments: [String]) throws -> ControlCommand {
        guard let first = arguments.first else {
            throw ControlServerError.invalidRequest("integrations requires a subcommand")
        }

        switch first {
        case "list":
            try requireArgumentCount(arguments, 1, usage: "integrations list takes no arguments")
            return .integrationsList
        case "status":
            try requireArgumentCount(arguments, 1, usage: "integrations status takes no arguments")
            return .integrationsStatus
        case "remove":
            try requireArgumentCount(arguments, 2, usage: "integrations remove requires an agent")
            guard let agent = arguments.dropFirst().first else {
                throw ControlServerError.invalidRequest("integrations remove requires an agent")
            }
            return .integrationsRemove(agentID: agent)
        case "enable-auto":
            try requireArgumentCount(arguments, 2, usage: "integrations enable-auto requires an agent")
            guard let agent = arguments.dropFirst().first else {
                throw ControlServerError.invalidRequest("integrations enable-auto requires an agent")
            }
            return .integrationsEnableAuto(agentID: agent)
        default:
            throw ControlServerError.invalidRequest("unknown integrations subcommand: \(first)")
        }
    }

    private func parseHelper(_ arguments: [String]) throws -> ControlCommand {
        guard let first = arguments.first else {
            throw ControlServerError.invalidRequest("helper requires a subcommand")
        }

        switch first {
        case "status":
            try requireArgumentCount(arguments, 1, usage: "helper status takes no arguments")
            return .helperStatus
        case "enable":
            try requireArgumentCount(arguments, 1, usage: "helper enable takes no arguments")
            return .helperEnableBagMode
        case "enable-closed-lid":
            try requireArgumentCount(arguments, 1, usage: "helper enable-closed-lid takes no arguments")
            return .helperEnableBagMode
        case "disable":
            try requireArgumentCount(arguments, 1, usage: "helper disable takes no arguments")
            return .helperDisableBagMode
        case "disable-closed-lid":
            try requireArgumentCount(arguments, 1, usage: "helper disable-closed-lid takes no arguments")
            return .helperDisableBagMode
        case "repair":
            try requireArgumentCount(arguments, 1, usage: "helper repair takes no arguments")
            return .helperRepair
        case "uninstall":
            try requireArgumentCount(arguments, 1, usage: "helper uninstall takes no arguments")
            return .helperUninstall
        default:
            throw ControlServerError.invalidRequest("unknown helper subcommand: \(first)")
        }
    }

    private func parseClosedLidMode(_ arguments: [String]) throws -> ControlCommand {
        guard let first = arguments.first else {
            throw ControlServerError.invalidRequest("closed-lid requires a subcommand")
        }

        switch first {
        case "status":
            try requireArgumentCount(arguments, 1, usage: "closed-lid status takes no arguments")
            return .closedLidStatus
        case "enable":
            try requireArgumentCount(arguments, 1, usage: "closed-lid enable takes no arguments")
            return .closedLidEnable
        case "disable":
            try requireArgumentCount(arguments, 1, usage: "closed-lid disable takes no arguments")
            return .closedLidDisable
        default:
            throw ControlServerError.invalidRequest("unknown closed-lid subcommand: \(first)")
        }
    }

    private func requireArgumentCount(_ arguments: [String], _ count: Int, usage: String) throws {
        guard arguments.count == count else {
            throw ControlServerError.invalidRequest(usage)
        }
    }

    private func parseDuration(_ value: String) -> TimeInterval? {
        guard let suffix = value.last else {
            return nil
        }

        let numberPart = value.dropLast()
        guard let amount = Double(numberPart), amount > 0 else {
            return nil
        }

        switch suffix {
        case "m":
            return amount * 60
        case "h":
            return amount * 60 * 60
        case "d":
            return amount * 24 * 60 * 60
        default:
            return nil
        }
    }
}

public struct LocalControlClient: ControlClient {
    public let runtimeStore: ControlRuntimeStore

    public init(runtimeStore: ControlRuntimeStore = ControlRuntimeStore()) {
        self.runtimeStore = runtimeStore
    }

    public func send(_ command: ControlCommand) throws -> ControlResponse {
        guard runtimeStore.fileManager.fileExists(atPath: runtimeStore.paths.controlSocketURL.path) else {
            throw ControlServerError.notRunning
        }

        let token = try runtimeStore.loadToken().trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ControlRequest(
            token: token,
            processID: Darwin.getpid(),
            clientTimestamp: Date(),
            command: command
        )
        return try UnixControlSocketClient.send(request, to: runtimeStore.paths.controlSocketURL)
    }
}
