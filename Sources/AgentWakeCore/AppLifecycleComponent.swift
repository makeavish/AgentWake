import Foundation

public enum ComponentRunState: Equatable, Sendable {
    case stopped
    case started
}

public protocol AppLifecycleComponent: AnyObject {
    var componentName: String { get }
    var runState: ComponentRunState { get }

    func start()
    func stop()
}

open class StubLifecycleComponent: AppLifecycleComponent {
    public let componentName: String
    public private(set) var runState: ComponentRunState

    public init(componentName: String, runState: ComponentRunState = .stopped) {
        self.componentName = componentName
        self.runState = runState
    }

    open func start() {
        runState = .started
    }

    open func stop() {
        runState = .stopped
    }
}
