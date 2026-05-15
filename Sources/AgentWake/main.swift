import AppKit
import AgentWakeCore

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--smoke-test") {
    let smokeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentWakeSmoke-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: smokeDirectory)
    }

    let app = MenuBarApp(
        services: AgentWakeServices(
            paths: AgentWakePaths(applicationSupportDirectory: smokeDirectory)
        )
    )
    app.start()
    app.stop()
    print("AgentWake launch smoke passed")
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
