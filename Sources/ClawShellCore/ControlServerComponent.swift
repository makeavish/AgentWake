import Foundation

public final class ControlServerComponent: AppLifecycleComponent {
    public let componentName = "ControlServer"

    public var runState: ComponentRunState {
        lock.lock()
        defer { lock.unlock() }
        return storedRunState
    }

    public var lastError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastError
    }

    public let runtimeStore: ControlRuntimeStore
    public let socketServer: ControlSocketServer

    private let router: ControlCommandRouting
    private let lock = NSLock()
    private var storedRunState: ComponentRunState = .stopped
    private var storedLastError: Error?
    private var activeControlServer: ControlServer?

    public init(
        runtimeStore: ControlRuntimeStore = ControlRuntimeStore(),
        router: ControlCommandRouting = DefaultControlCommandRouter(),
        socketServer: ControlSocketServer? = nil
    ) {
        self.runtimeStore = runtimeStore
        self.router = router
        self.socketServer = socketServer ?? ControlSocketServer(runtimeStore: runtimeStore)
    }

    public func start() {
        lock.lock()
        let alreadyStarted = storedRunState == .started
        lock.unlock()

        guard !alreadyStarted else {
            return
        }

        do {
            let token = try runtimeStore.rotateToken()
            let controlServer = ControlServer(token: token, router: router)
            try socketServer.start(controlServer: controlServer)

            lock.lock()
            activeControlServer = controlServer
            storedLastError = nil
            storedRunState = .started
            lock.unlock()
        } catch {
            socketServer.stop()
            try? runtimeStore.clearRuntimeFiles()

            lock.lock()
            activeControlServer = nil
            storedLastError = error
            storedRunState = .stopped
            lock.unlock()
        }
    }

    public func stop() {
        socketServer.stop()
        try? runtimeStore.clearRuntimeFiles()

        lock.lock()
        activeControlServer = nil
        storedRunState = .stopped
        lock.unlock()
    }
}
