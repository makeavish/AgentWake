import Darwin
import Foundation
import ServiceManagement

public enum AgentWakeHelperCommand: String, Codable, Equatable, Sendable {
    case status
    case enableClosedLid
    case disableClosedLid
    case repair
    case uninstall
}

public enum AgentWakeHelperConstants {
    public static let label = "com.makeavish.AgentWake.Helper"
    public static let plistName = "\(label).plist"
    public static let socketPath = "/var/run/agentwake-helper.sock"
    public static let helperToolRelativePath = "Contents/Library/PrivilegedHelperTools/AgentWakeHelper"
    public static let fallbackHelperPath = "/Library/PrivilegedHelperTools/\(label)"
    public static let fallbackPlistPath = "/Library/LaunchDaemons/\(plistName)"
}

public struct AgentWakeHelperRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var command: AgentWakeHelperCommand
    public var token: String
    public var restoreDisablesleep: Int?

    public init(
        schemaVersion: Int = 1,
        command: AgentWakeHelperCommand,
        token: String,
        restoreDisablesleep: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.command = command
        self.token = token
        self.restoreDisablesleep = restoreDisablesleep
    }
}

public struct AgentWakeHelperResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String
    public var sleepDisabled: Int?

    public init(accepted: Bool, message: String, sleepDisabled: Int? = nil) {
        self.accepted = accepted
        self.message = message
        self.sleepDisabled = sleepDisabled
    }
}

public enum AgentWakeHelperError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case invalidResponse(String)
    case rejected(String)
    case serviceManagementUnavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        case .invalidResponse(let message):
            message
        case .rejected(let message):
            message
        case .serviceManagementUnavailable:
            "Privileged helper registration requires macOS 13 or newer."
        }
    }
}

public protocol AgentWakePrivilegedHelperManaging: Sendable {
    func statusMessage() -> String
    func repair() throws -> String
    func unregister() throws -> String
}

public struct AgentWakePrivilegedHelperClient: Sendable {
    public let paths: AgentWakePaths
    public let socketPath: String
    public let maxResponseBytes: Int

    public init(
        paths: AgentWakePaths = .defaultPaths(),
        socketPath: String = AgentWakeHelperConstants.socketPath,
        maxResponseBytes: Int = 64 * 1024
    ) {
        self.paths = paths
        self.socketPath = socketPath
        self.maxResponseBytes = maxResponseBytes
    }

    public func send(_ command: AgentWakeHelperCommand, restoreDisablesleep: Int? = nil) throws -> AgentWakeHelperResponse {
        let token = try loadToken()
        let request = AgentWakeHelperRequest(
            command: command,
            token: token,
            restoreDisablesleep: restoreDisablesleep
        )
        return try send(request)
    }

    public func send(_ request: AgentWakeHelperRequest) throws -> AgentWakeHelperResponse {
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AgentWakeHelperError.unavailable("Privileged helper socket is unavailable.")
        }

        defer {
            Darwin.close(fileDescriptor)
        }

        do {
            try AgentWakeUnixSocket.withAddress(path: socketPath) { address, length in
                guard Darwin.connect(fileDescriptor, address, length) == 0 else {
                    throw AgentWakeHelperError.unavailable(
                        "Privileged helper is not running yet. Run `agentwake helper repair`, then approve the helper or enter an administrator password if macOS asks."
                    )
                }
            }

            let data = try JSONEncoder().encode(request)
            try AgentWakeUnixSocket.write(data, to: fileDescriptor)
            Darwin.shutdown(fileDescriptor, SHUT_WR)

            let responseData = try AgentWakeUnixSocket.read(from: fileDescriptor, maxBytes: maxResponseBytes)
            let response = try JSONDecoder().decode(AgentWakeHelperResponse.self, from: responseData)
            guard response.accepted else {
                throw AgentWakeHelperError.rejected(response.message)
            }
            return response
        } catch let error as AgentWakeHelperError {
            throw error
        } catch {
            throw AgentWakeHelperError.invalidResponse(error.localizedDescription)
        }
    }

    private func loadToken() throws -> String {
        let token = try String(contentsOf: paths.hookTokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AgentWakeHelperError.unavailable("AgentWake helper token is empty. Restart AgentWake and try again.")
        }
        return token
    }
}

public struct HelperBackedClosedLidModeCommandRunner: ClosedLidModeCommandRunning {
    private let reader: PmsetClosedLidModeCommandRunner
    private let helperClient: AgentWakePrivilegedHelperClient

    public init(
        reader: PmsetClosedLidModeCommandRunner = PmsetClosedLidModeCommandRunner(),
        helperClient: AgentWakePrivilegedHelperClient = AgentWakePrivilegedHelperClient()
    ) {
        self.reader = reader
        self.helperClient = helperClient
    }

    public func currentDisablesleep() throws -> Int {
        try reader.currentDisablesleep()
    }

    public func setDisablesleep(_ value: Int) throws {
        guard value == 0 || value == 1 else {
            throw ClosedLidModeError.invalidDisablesleepValue(String(value))
        }

        do {
            if value == 1 {
                _ = try helperClient.send(.enableClosedLid)
            } else {
                _ = try helperClient.send(.disableClosedLid, restoreDisablesleep: value)
            }
        } catch {
            throw ClosedLidModeError.authorizationFailed(error.localizedDescription)
        }
    }
}

public final class AgentWakePrivilegedHelperManager: AgentWakePrivilegedHelperManaging, @unchecked Sendable {
    private let client: AgentWakePrivilegedHelperClient

    public init(client: AgentWakePrivilegedHelperClient = AgentWakePrivilegedHelperClient()) {
        self.client = client
    }

    public func statusMessage() -> String {
        let service = serviceStatusMessage()
        let runtime: String
        do {
            runtime = try client.send(.status).message
        } catch {
            runtime = "Runtime: \(error.localizedDescription)"
        }

        return "\(service)\n\(runtime)"
    }

    public func repair() throws -> String {
        guard #available(macOS 13.0, *) else {
            throw AgentWakeHelperError.serviceManagementUnavailable
        }

        if let response = try? client.send(.status) {
            return "\(serviceStatusMessage())\n\(response.message)"
        }

        if usesAdHocSignature(Bundle.main.bundleURL) {
            try? SMAppService.daemon(plistName: AgentWakeHelperConstants.plistName).unregister()
            Thread.sleep(forTimeInterval: 0.2)
            return try installFallbackHelper()
        }

        let service = SMAppService.daemon(plistName: AgentWakeHelperConstants.plistName)
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                if service.status == .requiresApproval {
                    return try installFallbackHelper()
                }
                throw error
            }
        }

        let message = statusMessage()
        if message.contains("Runtime: helper running") {
            return message
        }

        try? service.unregister()
        Thread.sleep(forTimeInterval: 0.2)
        return try installFallbackHelper()
    }

    public func unregister() throws -> String {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: AgentWakeHelperConstants.plistName)
            try? service.unregister()
        }

        return try uninstallFallbackHelper()
    }

    private func serviceStatusMessage() -> String {
        guard #available(macOS 13.0, *) else {
            return "Privileged helper service: unavailable on this macOS version"
        }

        let service = SMAppService.daemon(plistName: AgentWakeHelperConstants.plistName)
        let status = service.status
        return "Privileged helper service: \(Self.describe(status))"
    }

    @available(macOS 13.0, *)
    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "not registered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires approval in System Settings"
        case .notFound:
            return "not registered"
        @unknown default:
            return "unknown (\(status.rawValue))"
        }
    }

    private func installFallbackHelper() throws -> String {
        let bundledHelperURL = Bundle.main.bundleURL.appendingPathComponent(
            AgentWakeHelperConstants.helperToolRelativePath,
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: bundledHelperURL.path) else {
            throw AgentWakeHelperError.unavailable("Bundled helper missing: \(bundledHelperURL.path)")
        }

        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.makeavish.AgentWake.Helper.\(UUID().uuidString).plist")
        try fallbackLaunchDaemonPlist().write(to: plistURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: plistURL)
        }

        let script = """
        set -e
        /bin/mkdir -p /Library/PrivilegedHelperTools
        /usr/bin/ditto \(shellQuote(bundledHelperURL.path)) \(shellQuote(AgentWakeHelperConstants.fallbackHelperPath))
        /usr/sbin/chown root:wheel \(shellQuote(AgentWakeHelperConstants.fallbackHelperPath))
        /bin/chmod 755 \(shellQuote(AgentWakeHelperConstants.fallbackHelperPath))
        /bin/cp \(shellQuote(plistURL.path)) \(shellQuote(AgentWakeHelperConstants.fallbackPlistPath))
        /usr/sbin/chown root:wheel \(shellQuote(AgentWakeHelperConstants.fallbackPlistPath))
        /bin/chmod 644 \(shellQuote(AgentWakeHelperConstants.fallbackPlistPath))
        /bin/launchctl bootout \(shellQuote("system/\(AgentWakeHelperConstants.label)")) >/dev/null 2>&1 || true
        /bin/launchctl bootout system \(shellQuote(AgentWakeHelperConstants.fallbackPlistPath)) >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system \(shellQuote(AgentWakeHelperConstants.fallbackPlistPath))
        /bin/launchctl kickstart -k system/\(shellQuote(AgentWakeHelperConstants.label))
        """

        try runAdministratorShellScript(script)
        Thread.sleep(forTimeInterval: 0.5)
        return statusMessage()
    }

    private func uninstallFallbackHelper() throws -> String {
        let script = """
        /bin/launchctl bootout \(shellQuote("system/\(AgentWakeHelperConstants.label)")) >/dev/null 2>&1 || true
        /bin/launchctl bootout system \(shellQuote(AgentWakeHelperConstants.fallbackPlistPath)) >/dev/null 2>&1 || true
        /bin/rm -f \(shellQuote(AgentWakeHelperConstants.fallbackPlistPath)) \(shellQuote(AgentWakeHelperConstants.fallbackHelperPath))
        """
        try runAdministratorShellScript(script)
        return "\(serviceStatusMessage())\nRuntime: fallback helper removed"
    }

    private func fallbackLaunchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xmlEscape(AgentWakeHelperConstants.label))</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(xmlEscape(AgentWakeHelperConstants.fallbackHelperPath))</string>
            <string>--daemon</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>/var/log/agentwake-helper.stdout.log</string>
          <key>StandardErrorPath</key>
          <string>/var/log/agentwake-helper.stderr.log</string>
        </dict>
        </plist>
        """
    }

    private func usesAdHocSignature(_ url: URL) -> Bool {
        guard let output = try? runProcess(
            "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", url.path],
            allowNonZeroExit: true
        ) else {
            return false
        }

        return output.contains("Signature=adhoc") || !output.contains("TeamIdentifier=")
    }

    private func runAdministratorShellScript(_ script: String) throws {
        let normalizedScript = script
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        let appleScript = "do shell script \(appleScriptString(normalizedScript)) with administrator privileges"
        _ = try runProcess("/usr/bin/osascript", arguments: ["-e", appleScript])
    }

    private func runProcess(
        _ executable: String,
        arguments: [String],
        allowNonZeroExit: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AgentWakeHelperError.unavailable(error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = output + error
        guard allowNonZeroExit || process.terminationStatus == 0 else {
            throw AgentWakeHelperError.unavailable(combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return combined
    }
}

enum AgentWakeUnixSocket {
    static func read(from fileDescriptor: Int32, maxBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)

            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
                guard data.count <= maxBytes else {
                    throw AgentWakeHelperError.invalidResponse("Helper socket payload is too large.")
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            if errno == EINTR {
                continue
            }

            throw AgentWakeHelperError.invalidResponse(socketErrorMessage("read helper socket"))
        }

        guard !data.isEmpty else {
            throw AgentWakeHelperError.invalidResponse("Helper socket payload is empty.")
        }
        return data
    }

    static func write(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw AgentWakeHelperError.invalidResponse("Helper socket payload is empty.")
            }

            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: bytesWritten),
                    data.count - bytesWritten
                )

                if result > 0 {
                    bytesWritten += result
                    continue
                }

                if result == -1 && errno == EINTR {
                    continue
                }

                throw AgentWakeHelperError.invalidResponse(socketErrorMessage("write helper socket"))
            }
        }
    }

    static func withAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)

        guard bytes.count < pathCapacity else {
            throw AgentWakeHelperError.invalidResponse("Helper socket path is too long: \(path)")
        }

        address.sun_family = sa_family_t(AF_UNIX)

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for (index, byte) in bytes.enumerated() {
                rawBuffer[index] = byte
            }
            rawBuffer[bytes.count] = 0
        }

        let length = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count + 1
        address.sun_len = UInt8(length)

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(length))
            }
        }
    }

    private static func socketErrorMessage(_ operation: String) -> String {
        "\(operation) failed: \(String(cString: Darwin.strerror(errno)))"
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleScriptString(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    + "\""
}

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
