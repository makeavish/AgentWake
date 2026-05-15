import AgentWakeCore
import Darwin
import Foundation

@main
struct AgentWakeHookAdapterMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let parser = HookAdapterArgumentParser(arguments: arguments)

        guard let mode = parser.value(for: "--mode"),
              let agentID = parser.value(for: "--agent"),
              let agent = AgentKind(agentID: agentID) else {
            exit(0)
        }

        let host = parser.value(for: "--host") ?? agent.rawValue
        let parentPID = Int32(Darwin.getppid())
        let processIdentity = adapterProcessIdentity(parentPID: parentPID, agent: agent)
        let salt = try? CWDHashSaltStore().loadOrCreateSalt()
        let context = HookAdapterContext(
            agent: agent,
            host: host,
            processID: processIdentity.pid,
            processStartTime: processIdentity.processStartTime,
            cwdHashSalt: salt
        )
        let runner = HookAdapterRunner()
        let result: HookAdapterRunResult

        switch mode {
        case "claude-hook":
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            result = runner.runClaudeCodeHook(stdin: stdin, context: context)
        case "codex-hook":
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            result = runner.runCodexHook(stdin: stdin, context: context)
        case "codex-notify":
            let payload = parser.trailingArgument ?? "{}"
            let forward = parser.forwardNotifyCommand()
            result = runner.runCodexNotify(payload: payload, context: context, forwardNotifyCommand: forward)
        default:
            result = HookAdapterRunResult()
        }

        if !result.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
        }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        exit(result.exitCode)
    }
}

private func adapterProcessIdentity(parentPID: Int32, agent: AgentKind) -> HookAdapterProcessIdentity {
    guard let snapshots = try? LibprocProcessSnapshotProvider().snapshots() else {
        return HookAdapterProcessIdentity(pid: parentPID)
    }

    return HookAdapterProcessResolver.nearestAgentProcess(
        startingAt: parentPID,
        agent: agent,
        snapshots: snapshots
    )
}

private struct HookAdapterArgumentParser {
    var arguments: [String]

    func value(for name: String) -> String? {
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }

        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        return arguments[valueIndex]
    }

    var trailingArgument: String? {
        var consumed = Set<Int>()
        for index in arguments.indices where arguments[index].hasPrefix("--") {
            consumed.insert(index)
            let next = arguments.index(after: index)
            if next < arguments.endIndex, !arguments[next].hasPrefix("--") {
                consumed.insert(next)
            }
        }

        return arguments.indices
            .filter { !consumed.contains($0) }
            .map { arguments[$0] }
            .last
    }

    func forwardNotifyCommand() -> [String] {
        guard let encoded = value(for: "--forward-notify"),
              let data = Data(base64Encoded: encoded),
              let command = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return command
    }
}
