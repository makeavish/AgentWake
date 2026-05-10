import ClawShellCore
import Foundation

let cli = ClawShellCLI(client: LocalControlClient())

do {
    let output = try cli.run(arguments: CommandLine.arguments)
    print(output)
} catch {
    fputs("clawshell: \(error.localizedDescription)\n", stderr)
    exit(1)
}
