import AppKit
import Carbon
import InputMethodKit

private func isInputModeEnabledInActiveList(_ modeId: String) -> Bool {
    guard let list = TISCreateInputSourceList(
        [kTISPropertyInputSourceID as String: modeId] as CFDictionary,
        false
    )?.takeRetainedValue() as? [TISInputSource] else {
        return false
    }
    for src in list {
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled) {
            let val = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
            if CFBooleanGetValue(val) {
                return true
            }
        }
    }
    return false
}

if CommandLine.arguments.contains("--register-system-cache") {
    // Must be invoked as root (euid == 0): CarbonCore's `OpenCCFFile` only writes the global
    // `/System/Library/Caches/com.apple.IntlDataCache.le.kbdx` (read by sandboxed `KeyboardSettings.appex`
    // before reboot) when `geteuid() == 0`.
    let bundleURL = Bundle.main.bundleURL
    let regStatus = TISRegisterInputSource(bundleURL as CFURL)
    if regStatus != noErr {
        fputs("TISRegisterInputSource (system) returned \(regStatus)\n", stderr)
    }
    _ = TISCreateInputSourceList(nil, true)
    exit(0)
}

if CommandLine.arguments.contains("--register-and-enable") {
    _ = NSApplication.shared
    let bundle = Bundle.main
    let bundleURL = bundle.bundleURL
    let bundleId = bundle.bundleIdentifier ?? "im.juxu.inputmethod.Juxu"
    let modeId = ((bundle.infoDictionary?["ComponentInputModeDict"] as? [String: Any])?["tsVisibleInputModeOrderedArrayKey"] as? [String])?.first
        ?? "\(bundleId).Hans"
    let shouldSelect = CommandLine.arguments.contains("--select")

    let regStatus = TISRegisterInputSource(bundleURL as CFURL)
    if regStatus != noErr {
        fputs("TISRegisterInputSource returned \(regStatus)\n", stderr)
    }

    // Fast path for upgrades: if already enabled in user's active input source list
    // (`com.apple.inputsources.plist` on macOS 27+), avoid re-triggering System Settings.
    if isInputModeEnabledInActiveList(modeId) {
        if shouldSelect,
           let list = TISCreateInputSourceList(
               [kTISPropertyInputSourceID as String: modeId] as CFDictionary,
               false
           )?.takeRetainedValue() as? [TISInputSource],
           let src = list.first {
            _ = TISSelectInputSource(src)
        }
        exit(0)
    }

    var foundSource: TISInputSource?
    for attempt in 0..<20 {
        if attempt == 5 || attempt == 12 {
            _ = TISRegisterInputSource(bundleURL as CFURL)
        }
        for filterDict in [
            [kTISPropertyBundleID as String: bundleId],
            [kTISPropertyInputSourceID as String: bundleId],
            [kTISPropertyInputSourceID as String: modeId],
        ] {
            if let list = TISCreateInputSourceList(filterDict as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] {
                for src in list {
                    _ = TISEnableInputSource(src)
                    if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                        if id == modeId {
                            foundSource = src
                        }
                    }
                }
            }
        }
        if foundSource != nil {
            break
        }
        usleep(150_000)
    }

    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    // On macOS 26/27+, `com.apple.inputsources.plist` is protected by `com.apple.macl` and
    // `TISEnableInputSource` delegates third-party enablement to `KeyboardSettings.appex` via AppleEvent.
    // If not yet enabled silently, open Keyboard Settings and re-send `TISEnableInputSource` so macOS
    // presents the one-click enable sheet directly.
    if !isInputModeEnabledInActiveList(modeId), let src = foundSource {
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources") {
            NSWorkspace.shared.open(settingsURL)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            _ = TISEnableInputSource(src)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }

    if shouldSelect, isInputModeEnabledInActiveList(modeId), let src = foundSource {
        _ = TISSelectInputSource(src)
    }
    exit(0)
}

final class JuxuAppDelegate: NSObject, NSApplicationDelegate {
    private var imkServer: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        let bundleId = bundle.bundleIdentifier ?? "im.juxu.inputmethod.Juxu"

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
        VoiceWhisperServerManager.sharedIfLoaded?.stop()
        JuxuBridge.shared.flushUserDataIfNeeded()
    }
}

let app = NSApplication.shared
let delegate = JuxuAppDelegate()
app.delegate = delegate
app.run()
