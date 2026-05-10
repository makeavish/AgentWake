import AppKit
import ClawShellCore

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--smoke-test") {
    let app = MenuBarApp(services: ClawShellServices())
    app.start()
    app.stop()
    print("ClawShell launch smoke passed")
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
