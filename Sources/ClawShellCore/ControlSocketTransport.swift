import Darwin
import Foundation

public final class ControlSocketServer: @unchecked Sendable {
    public let runtimeStore: ControlRuntimeStore

    private let queue: DispatchQueue
    private let maxRequestBytes: Int
    private let stateLock = NSLock()
    private var listenFileDescriptor: Int32?

    public init(
        runtimeStore: ControlRuntimeStore = ControlRuntimeStore(),
        queue: DispatchQueue = DispatchQueue(label: "wtf.vishal.clawshell.control-socket"),
        maxRequestBytes: Int = 64 * 1024
    ) {
        self.runtimeStore = runtimeStore
        self.queue = queue
        self.maxRequestBytes = maxRequestBytes
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenFileDescriptor != nil
    }

    public func start(controlServer: ControlServer) throws {
        try runtimeStore.prepareRuntimeDirectory()

        stateLock.lock()
        let alreadyRunning = listenFileDescriptor != nil
        stateLock.unlock()

        guard !alreadyRunning else {
            throw ControlServerError.invalidRequest("control socket server is already running")
        }

        let socketURL = runtimeStore.paths.controlSocketURL
        try? runtimeStore.fileManager.removeItem(at: socketURL)

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw ControlServerError.invalidRequest(socketErrorMessage("create control socket"))
        }

        do {
            _ = Darwin.fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC)
            try withUnixSocketAddress(path: socketURL.path) { address, length in
                guard Darwin.bind(fileDescriptor, address, length) == 0 else {
                    throw ControlServerError.invalidRequest(socketErrorMessage("bind control socket"))
                }
            }

            guard Darwin.listen(fileDescriptor, 16) == 0 else {
                throw ControlServerError.invalidRequest(socketErrorMessage("listen on control socket"))
            }

            _ = Darwin.chmod(socketURL.path, 0o600)

            stateLock.lock()
            listenFileDescriptor = fileDescriptor
            stateLock.unlock()

            queue.async { [weak self] in
                self?.acceptLoop(fileDescriptor: fileDescriptor, controlServer: controlServer)
            }
        } catch {
            Darwin.close(fileDescriptor)
            try? runtimeStore.fileManager.removeItem(at: socketURL)
            throw error
        }
    }

    public func stop() {
        stateLock.lock()
        let fileDescriptor = listenFileDescriptor
        listenFileDescriptor = nil
        stateLock.unlock()

        if let fileDescriptor {
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
        }

        try? runtimeStore.fileManager.removeItem(at: runtimeStore.paths.controlSocketURL)
    }

    private func acceptLoop(fileDescriptor: Int32, controlServer: ControlServer) {
        while true {
            let clientDescriptor = Darwin.accept(fileDescriptor, nil, nil)

            if clientDescriptor >= 0 {
                handleClient(fileDescriptor: clientDescriptor, controlServer: controlServer)
                Darwin.close(clientDescriptor)
                continue
            }

            if errno == EINTR {
                continue
            }

            break
        }
    }

    private func handleClient(fileDescriptor: Int32, controlServer: ControlServer) {
        do {
            try validatePeerUser(fileDescriptor: fileDescriptor)
            let data = try readData(from: fileDescriptor, maxBytes: maxRequestBytes)
            var request = try JSONDecoder().decode(ControlRequest.self, from: data)
            request.processID = peerProcessID(fileDescriptor: fileDescriptor)

            let response = try controlServer.handle(request)
            try writeResponse(.success(response), to: fileDescriptor)
        } catch {
            try? writeResponse(.failure(error.localizedDescription), to: fileDescriptor)
        }
    }

    private func validatePeerUser(fileDescriptor: Int32) throws {
        var uid = uid_t()
        var gid = gid_t()

        guard Darwin.getpeereid(fileDescriptor, &uid, &gid) == 0 else {
            throw ControlServerError.unauthenticated
        }

        guard uid == Darwin.getuid() else {
            throw ControlServerError.unauthenticated
        }
    }

    private func writeResponse(_ response: ControlSocketReply, to fileDescriptor: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try writeData(data, to: fileDescriptor)
    }
}

public enum UnixControlSocketClient {
    public static func send(
        _ request: ControlRequest,
        to socketURL: URL,
        maxResponseBytes: Int = 64 * 1024
    ) throws -> ControlResponse {
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw ControlServerError.notRunning
        }

        defer {
            Darwin.close(fileDescriptor)
        }

        do {
            try withUnixSocketAddress(path: socketURL.path) { address, length in
                guard Darwin.connect(fileDescriptor, address, length) == 0 else {
                    throw ControlServerError.notRunning
                }
            }

            let data = try JSONEncoder().encode(request)
            try writeData(data, to: fileDescriptor)
            Darwin.shutdown(fileDescriptor, SHUT_WR)

            let responseData = try readData(from: fileDescriptor, maxBytes: maxResponseBytes)
            let reply = try JSONDecoder().decode(ControlSocketReply.self, from: responseData)

            switch reply {
            case .success(let response):
                return response
            case .failure(let message):
                throw ControlServerError.invalidRequest(message)
            }
        } catch ControlServerError.notRunning {
            throw ControlServerError.notRunning
        } catch {
            throw error
        }
    }
}

private enum ControlSocketReply: Codable {
    case success(ControlResponse)
    case failure(String)

    private enum CodingKeys: String, CodingKey {
        case status
        case response
        case message
    }

    private enum Status: String, Codable {
        case success
        case failure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(Status.self, forKey: .status)

        switch status {
        case .success:
            self = .success(try container.decode(ControlResponse.self, forKey: .response))
        case .failure:
            self = .failure(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .success(let response):
            try container.encode(Status.success, forKey: .status)
            try container.encode(response, forKey: .response)
        case .failure(let message):
            try container.encode(Status.failure, forKey: .status)
            try container.encode(message, forKey: .message)
        }
    }
}

private func peerProcessID(fileDescriptor: Int32) -> Int32? {
    var pid = pid_t()
    var length = socklen_t(MemoryLayout<pid_t>.size)

    let result = withUnsafeMutablePointer(to: &pid) { pointer in
        Darwin.getsockopt(fileDescriptor, SOL_LOCAL, LOCAL_PEERPID, pointer, &length)
    }

    guard result == 0 else {
        return nil
    }

    return Int32(pid)
}

private func readData(from fileDescriptor: Int32, maxBytes: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)

        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)

            guard data.count <= maxBytes else {
                throw ControlServerError.invalidRequest("control socket payload is too large")
            }

            continue
        }

        if bytesRead == 0 {
            break
        }

        if errno == EINTR {
            continue
        }

        throw ControlServerError.invalidRequest(socketErrorMessage("read control socket"))
    }

    guard !data.isEmpty else {
        throw ControlServerError.invalidRequest("control socket payload is empty")
    }

    return data
}

private func writeData(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            throw ControlServerError.invalidRequest("control socket payload is empty")
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

            throw ControlServerError.invalidRequest(socketErrorMessage("write control socket"))
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
        throw ControlServerError.invalidRequest("control socket path is too long: \(path)")
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
