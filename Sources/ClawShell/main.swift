import AppKit
import ClawShellCore

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--smoke-test") {
    let smokeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClawShellSmoke-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: smokeDirectory)
    }

    let app = MenuBarApp(
        services: ClawShellServices(
            paths: ClawShellPaths(applicationSupportDirectory: smokeDirectory)
        )
    )
    app.start()
    app.stop()
    print("ClawShell launch smoke passed")
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
