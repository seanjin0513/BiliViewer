import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedController: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = BrowserWindowController()
        controller.showWindow(nil)
        AppDelegate.sharedController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// 应用启动入口
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
