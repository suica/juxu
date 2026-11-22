import AppKit
import InputMethodKit

final class JuxuAppDelegate: NSObject, NSApplicationDelegate {
    private var imkServer: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        let bundleId = bundle.bundleIdentifier ?? "com.hcyue.inputmethod.juxu"

        // On macOS 27+, `+[IMKServer connectionNameFor:]` enforces `<bundleIdentifier>.Connection`
        // for all third-party input methods (rejecting custom names in IMKInputSession_Modern).
        let connSel = NSSelectorFromString("connectionNameFor:")
        let resolvedConnName: String
        if IMKServer.responds(to: connSel),
           let obj = IMKServer.perform(connSel, with: bundle)?.takeUnretainedValue() as? String,
           !obj.isEmpty {
            resolvedConnName = obj
        } else {
            resolvedConnName = (bundle.infoDictionary?["InputMethodConnectionName"] as? String)
                ?? "\(bundleId).Connection"
        }

        self.imkServer = IMKServer(name: resolvedConnName, bundleIdentifier: bundleId)

        // Initialize shared Rust mmap core eagerly (< 1ms) so first keystroke has 0ms cold latency
        _ = JuxuBridge.shared

        // Allow launching standalone settings UI via `--settings`
        if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        JuxuBridge.shared.flushUserDataIfNeeded()
    }
}

let app = NSApplication.shared
let delegate = JuxuAppDelegate()
app.delegate = delegate
app.run()
