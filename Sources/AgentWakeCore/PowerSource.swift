import Foundation

public enum PowerSource: String, Equatable, Sendable {
    case ac
    case battery
    case unknown
}

public enum PowerSourceReader {
    public static func current() -> PowerSource {
        parse(pmsetBatteryOutput: pmsetBatteryOutput() ?? "")
    }

    public static func currentBatteryPercent() -> Int? {
        guard let output = pmsetBatteryOutput() else {
            return nil
        }

        return parseBatteryPercent(pmsetBatteryOutput: output)
    }

    private static func pmsetBatteryOutput() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    public static func parse(pmsetBatteryOutput output: String) -> PowerSource {
        if output.localizedCaseInsensitiveContains("Battery Power") {
            return .battery
        }

        if output.localizedCaseInsensitiveContains("AC Power") {
            return .ac
        }

        return .unknown
    }

    public static func parseBatteryPercent(pmsetBatteryOutput output: String) -> Int? {
        let pattern = #"(\d{1,3})%;"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output),
              let percent = Int(output[range]),
              (0...100).contains(percent) else {
            return nil
        }

        return percent
    }
}
