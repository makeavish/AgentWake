import AgentWakeCore
import Foundation

let cli = AgentWakeCLI(client: LocalControlClient())

do {
    let output = try cli.run(arguments: CommandLine.arguments)
    print(output)
} catch {
    fputs("agentwake: \(error.localizedDescription)\n", stderr)
    exit(1)
}
