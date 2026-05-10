import ClawShellCore
import Foundation

@main
struct ClawShellPowerValidation {
    static func main() throws {
        let options = try ValidationOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let heldSessionID = UUID()
        let manager = AssertionManager(
            holdStateProvider: {
                AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [heldSessionID])
            },
            reconcileInterval: max(options.duration, 1)
        )

        manager.start()
        manager.reconcile()

        let snapshot = manager.snapshot
        guard snapshot.isHolding else {
            throw ValidationError("normal power assertions were not acquired")
        }

        if let readyFile = options.readyFile {
            let parent = readyFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("ready\n".utf8).write(to: readyFile, options: [.atomic])
        }

        print("Holding normal assertions for \(Int(options.duration)) seconds")
        let assertionNames = snapshot.heldAssertions.map { $0.type.iopmAssertionType }.joined(separator: ", ")
        print("Assertions: \(assertionNames)")
        Thread.sleep(forTimeInterval: options.duration)
        manager.stop()
        print("Released normal assertions")
    }
}

private struct ValidationOptions {
    var duration: TimeInterval = 10
    var readyFile: URL?

    init(arguments: [String]) throws {
        var remaining = arguments

        while !remaining.isEmpty {
            let option = remaining.removeFirst()

            switch option {
            case "--duration":
                guard let value = remaining.first else {
                    throw ValidationError("--duration requires a value")
                }
                remaining.removeFirst()

                guard let duration = TimeInterval(value), duration > 0 else {
                    throw ValidationError("--duration must be a positive number of seconds")
                }

                self.duration = duration

            case "--ready-file":
                guard let value = remaining.first else {
                    throw ValidationError("--ready-file requires a path")
                }
                remaining.removeFirst()
                self.readyFile = URL(fileURLWithPath: value)

            default:
                throw ValidationError("unknown option: \(option)")
            }
        }
    }
}

private struct ValidationError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
