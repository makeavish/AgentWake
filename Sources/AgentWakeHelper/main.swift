import AgentWakeCore
import Darwin
import Foundation

private let maxRequestBytes = 64 * 1024

@main
struct AgentWakeHelperMain {
    static func main() {
        if CommandLine.arguments.contains("--daemon") {
            AgentWakeHelperDaemon().run()
        }

        let response = AgentWakeHelperDaemon().perform(command: .status, restoreDisablesleep: nil)
        print(response.message)
    }
}

private final class AgentWakeHelperDaemon {
    private let socketPath = AgentWakeHelperConstants.socketPath

    func run() -> Never {
        let listenFileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFileDescriptor >= 0 else {
            fatalError(socketErrorMessage("create helper socket"))
        }

        _ = Darwin.fcntl(listenFileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = Darwin.unlink(socketPath)

        do {
            try withUnixSocketAddress(path: socketPath) { address, length in
                guard Darwin.bind(listenFileDescriptor, address, length) == 0 else {
                    throw HelperFailure(socketErrorMessage("bind helper socket"))
                }
            }

            guard Darwin.listen(listenFileDescriptor, 16) == 0 else {
                throw HelperFailure(socketErrorMessage("listen on helper socket"))
            }
            _ = Darwin.chmod(socketPath, 0o666)
        } catch {
            Darwin.close(listenFileDescriptor)
            fatalError(error.localizedDescription)
        }

        while true {
            let clientDescriptor = Darwin.accept(listenFileDescriptor, nil, nil)
            if clientDescriptor >= 0 {
                handleClient(fileDescriptor: clientDescriptor)
                Darwin.close(clientDescriptor)
                continue
            }

            if errno == EINTR {
                continue
            }

            Darwin.close(listenFileDescriptor)
            _ = Darwin.unlink(socketPath)
            exit(1)
        }
    }

    func perform(command: AgentWakeHelperCommand, restoreDisablesleep: Int?) -> AgentWakeHelperResponse {
        do {
            switch command {
            case .status, .repair:
                let current = try currentDisablesleep()
                return AgentWakeHelperResponse(
                    accepted: true,
                    message: "Runtime: helper running as uid=\(getuid()) euid=\(geteuid())\nSleepDisabled=\(current)",
                    sleepDisabled: current
                )
            case .enableClosedLid:
                try setDisablesleep(1)
                let current = try currentDisablesleep()
                return AgentWakeHelperResponse(
                    accepted: true,
                    message: "Runtime: helper enabled Lid-Closed Awake\nSleepDisabled=\(current)",
                    sleepDisabled: current
                )
            case .disableClosedLid, .uninstall:
                let restoreValue = restoreDisablesleep ?? 0
                guard restoreValue == 0 || restoreValue == 1 else {
                    throw HelperFailure("Invalid restore disablesleep value: \(restoreValue)")
                }
                try setDisablesleep(restoreValue)
                let current = try currentDisablesleep()
                return AgentWakeHelperResponse(
                    accepted: true,
                    message: "Runtime: helper restored Lid-Closed Awake\nSleepDisabled=\(current)",
                    sleepDisabled: current
                )
            }
        } catch {
            return AgentWakeHelperResponse(accepted: false, message: error.localizedDescription)
        }
    }

    private func handleClient(fileDescriptor: Int32) {
        do {
            let data = try readData(from: fileDescriptor, maxBytes: maxRequestBytes)
            let request = try JSONDecoder().decode(AgentWakeHelperRequest.self, from: data)
            try validate(request: request, fileDescriptor: fileDescriptor)
            let response = perform(command: request.command, restoreDisablesleep: request.restoreDisablesleep)
            try writeResponse(response, to: fileDescriptor)
        } catch {
            try? writeResponse(
                AgentWakeHelperResponse(accepted: false, message: error.localizedDescription),
                to: fileDescriptor
            )
        }
    }

    private func validate(request: AgentWakeHelperRequest, fileDescriptor: Int32) throws {
        guard request.schemaVersion == 1 else {
            throw HelperFailure("Unsupported helper request schema version: \(request.schemaVersion)")
        }

        var uid = uid_t()
        var gid = gid_t()
        guard Darwin.getpeereid(fileDescriptor, &uid, &gid) == 0 else {
            throw HelperFailure("Helper request could not identify its peer.")
        }

        if uid == 0 {
            return
        }

        guard let expectedToken = tokenForPeer(uid: uid), !expectedToken.isEmpty else {
            throw HelperFailure("AgentWake is not running for uid=\(uid).")
        }

        guard constantTimeEquals(request.token, expectedToken) else {
            throw HelperFailure("Helper request was not paired with the running AgentWake app.")
        }
    }

    private func tokenForPeer(uid: uid_t) -> String? {
        guard let passwd = Darwin.getpwuid(uid),
              let home = passwd.pointee.pw_dir else {
            return nil
        }

        let homeDirectory = String(cString: home)
        let tokenURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AgentWake", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("hook-token", isDirectory: false)

        return try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentDisablesleep() throws -> Int {
        let output = try runProcess("/usr/bin/pmset", arguments: ["-g", "live"])
        return PmsetClosedLidModeCommandRunner.parseDisablesleepValue(from: output) ?? 0
    }

    private func setDisablesleep(_ value: Int) throws {
        guard value == 0 || value == 1 else {
            throw HelperFailure("Invalid disablesleep value: \(value)")
        }
        _ = try runProcess("/usr/bin/pmset", arguments: ["disablesleep", String(value)])
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> String {
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
            throw HelperFailure(error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw HelperFailure(stderr.isEmpty ? output : stderr)
        }
        return output
    }

    private func writeResponse(_ response: AgentWakeHelperResponse, to fileDescriptor: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try writeData(data, to: fileDescriptor)
    }
}

private struct HelperFailure: Error, LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorDescription: String? {
        message.isEmpty ? "Privileged helper command failed." : message
    }
}

private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    var diff = lhsBytes.count ^ rhsBytes.count
    for index in 0..<max(lhsBytes.count, rhsBytes.count) {
        let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
        let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
        diff |= Int(lhsByte ^ rhsByte)
    }
    return diff == 0
}

private func readData(from fileDescriptor: Int32, maxBytes: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)

        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)
            guard data.count <= maxBytes else {
                throw HelperFailure("Helper socket payload is too large.")
            }
            continue
        }

        if bytesRead == 0 {
            break
        }

        if errno == EINTR {
            continue
        }

        throw HelperFailure(socketErrorMessage("read helper socket"))
    }

    guard !data.isEmpty else {
        throw HelperFailure("Helper socket payload is empty.")
    }
    return data
}

private func writeData(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            throw HelperFailure("Helper socket payload is empty.")
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

            throw HelperFailure(socketErrorMessage("write helper socket"))
        }
    }
}

private func withUnixSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)

    guard bytes.count < pathCapacity else {
        throw HelperFailure("Helper socket path is too long: \(path)")
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

private func socketErrorMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: Darwin.strerror(errno)))"
}
