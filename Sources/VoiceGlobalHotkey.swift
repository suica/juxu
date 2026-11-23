import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Optional: the voice key works in any app, even when 句序 is not the current input method.
// Nothing in this file allocates, listens or asks for a permission until the user turns it on.

// MARK: - Key Routing

public enum VoiceGlobalKeyDecision: Equatable {
    case forward
    case ignore
    case cancelChord
}

public enum VoiceGlobalKeyRouter {
    private static let escape: UInt16 = 0x35

    private static func modifier(for trigger: VoiceTriggerKey) -> NSEvent.ModifierFlags? {
        switch trigger {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .fnKey: return .function
        case .optionSpace: return nil
        }
    }

    /// The listener cannot swallow keys, so only hold-to-talk triggers are supported:
    /// Option+Space would also type into the app.
    public static func decide(
        isKeyDown: Bool,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        trigger: VoiceTriggerKey,
        isSecureInput: Bool,
        isRecording: Bool
    ) -> VoiceGlobalKeyDecision {
        guard let modifier = modifier(for: trigger) else { return .ignore }
        if isKeyDown {
            if isRecording, keyCode == escape { return .forward }
            if isSecureInput { return .ignore }
            // A shortcut pressed while held is the user's shortcut, not dictation.
            if isRecording { return flags.contains(modifier) ? .cancelChord : .ignore }
            return .forward
        }
        // During secure input only the release of a recording already in progress is seen.
        if isSecureInput, !isRecording { return .ignore }
        return .forward
    }
}

// MARK: - Permissions

public struct VoiceGlobalPermissions: Equatable {
    public let inputMonitoring: Bool
    public let accessibility: Bool

    public static func current() -> VoiceGlobalPermissions {
        VoiceGlobalPermissions(inputMonitoring: CGPreflightListenEventAccess(), accessibility: AXIsProcessTrusted())
    }

    /// Shows the system prompts. Only called when the user turns the feature on.
    public static func request() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static let inputMonitoringPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    public static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}

// MARK: - Clipboard

/// A full copy of a pasteboard, including every type of every item.
public struct VoiceClipboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    public init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            entries.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

// MARK: - Commit Without an Input Method Client

public enum VoiceGlobalInsertRoute: Equatable {
    case inputMethod
    case accessibility
    case clipboardOnly(String)
}

public enum VoiceGlobalCommitPolicy {
    public static func route(
        isSecure: Bool,
        focusUnchanged: Bool,
        hasInputMethodClient: Bool,
        hasAccessibility: Bool,
        hasTextField: Bool
    ) -> VoiceGlobalInsertRoute {
        if isSecure { return .clipboardOnly("密码框不会写入，文字已放到剪贴板") }
        if !focusUnchanged { return .clipboardOnly("焦点已变化，文字已放到剪贴板") }
        if hasInputMethodClient { return .inputMethod }
        if !hasAccessibility { return .clipboardOnly("未授权辅助功能，文字已放到剪贴板") }
        if !hasTextField { return .clipboardOnly("没有可输入的位置，文字已放到剪贴板") }
        return .accessibility
    }
}

@MainActor
final class VoiceGlobalCommitter {
    /// Set by the input controller while 句序 is the active input method.
    private(set) static var inputMethodSink: ((String) -> Bool)?
    private static weak var inputMethodOwner: AnyObject?

    static func setInputMethodSink(owner: AnyObject, _ sink: @escaping (String) -> Bool) {
        inputMethodOwner = owner
        inputMethodSink = sink
    }

    /// Activation of the next app can arrive before deactivation of the previous one.
    static func clearInputMethodSink(owner: AnyObject) {
        guard inputMethodOwner === owner else { return }
        inputMethodOwner = nil
        inputMethodSink = nil
    }

    private struct Target {
        let pid: pid_t?
        let element: AXUIElement?
    }

    private var target = Target(pid: nil, element: nil)

    private static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        // These calls run on the main thread, so a hung app must not be able to stall typing.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isTextField(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        let role = string(element, kAXRoleAttribute) ?? ""
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }

    /// Remembers where the user was when recording started.
    func captureTarget() {
        target = Target(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier, element: Self.focusedElement())
    }

    /// A rect on the screen the user is working on, for placing the HUD.
    func anchorRect() -> NSRect {
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 20)
    }

    private func focusUnchanged(_ current: AXUIElement?) -> Bool {
        guard let pid = target.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if let before = target.element, let current { return CFEqual(before, current) }
        return target.element == nil && current == nil
    }

    /// Inserts `text` into the original field, or leaves it on the clipboard. Returns a notice, if any.
    func commit(_ text: String, completion: @escaping @MainActor (String?) -> Void) {
        let current = Self.focusedElement()
        let isSecure = IsSecureEventInputEnabled()
            || current.flatMap { Self.string($0, kAXSubroleAttribute) } == kAXSecureTextFieldSubrole
        let route = VoiceGlobalCommitPolicy.route(
            isSecure: isSecure,
            focusUnchanged: focusUnchanged(current),
            hasInputMethodClient: Self.inputMethodSink != nil,
            hasAccessibility: AXIsProcessTrusted(),
            hasTextField: Self.isTextField(current)
        )
        switch route {
        case .inputMethod:
            if Self.inputMethodSink?(text) == true {
                completion(nil)
            } else {
                Self.leaveOnClipboard(text)
                completion("无法写入，文字已放到剪贴板")
            }
        case .clipboardOnly(let notice):
            Self.leaveOnClipboard(text)
            completion(notice)
        case .accessibility:
            guard let current else {
                Self.leaveOnClipboard(text)
                completion("没有可输入的位置，文字已放到剪贴板")
                return
            }
            if Self.insertWithAccessibility(text, into: current) {
                completion(nil)
            } else {
                Self.paste(text, into: current, completion: completion)
            }
        }
    }

    private static func leaveOnClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Many apps report success without inserting, so the field's value is read back.
    private static func insertWithAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        guard let before = string(element, kAXValueAttribute) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
              let after = string(element, kAXValueAttribute) else { return false }
        return after != before && after.contains(text)
    }

    /// Pastes, then restores the user's clipboard only if the text is confirmed in the field.
    /// If it cannot be confirmed the text stays on the clipboard, so it is never lost.
    private static func paste(_ text: String, into element: AXUIElement, completion: @escaping @MainActor (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = VoiceClipboardSnapshot(pasteboard)
        let before = string(element, kAXValueAttribute)
        leaveOnClipboard(text)
        let stamp = pasteboard.changeCount
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated {
                let after = string(element, kAXValueAttribute)
                let confirmed = after != nil && after != before && after?.contains(text) == true
                if confirmed {
                    // The user may have copied something else in the meantime.
                    if pasteboard.changeCount == stamp { snapshot.restore(to: pasteboard) }
                    completion(nil)
                } else {
                    completion("已粘贴；无法确认，文字也留在剪贴板")
                }
            }
        }
    }
}

// MARK: - Listener

/// Exists only while the feature is on and voice is enabled.
@MainActor
public final class VoiceGlobalHotkeyController {
    private static var _shared: VoiceGlobalHotkeyController?
    static var testingForceListening = false

    public static var isLoaded: Bool { _shared != nil }
    /// While true the global listener is the only source of voice key events.
    public static var isListening: Bool { testingForceListening || _shared?.tap != nil }

    public static func sync(with prefs: VoicePreferences) {
        guard prefs.enabled, prefs.isGlobalHotkeyEnabled else {
            unload()
            return
        }
        if _shared == nil { _shared = VoiceGlobalHotkeyController() }
        _shared?.refresh()
    }

    public static func unload() {
        _shared?.teardown()
        _shared = nil
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var recheck: Timer?
    private let committer = VoiceGlobalCommitter()

    private init() {
        // Picks up a grant given later, and notices one that was revoked or invalidated by a re-sign.
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { VoiceGlobalHotkeyController._shared?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recheck = timer
    }

    private func refresh() {
        let allowed = CGPreflightListenEventAccess()
        if allowed, tap == nil {
            startTap()
        } else if !allowed, tap != nil {
            VoiceSessionController.sharedIfLoaded?.cancelForChord()
            stopTap()
        }
    }

    private func startTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                MainActor.assumeIsolated { VoiceGlobalHotkeyController._shared?.receive(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = loopSource
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    private func teardown() {
        recheck?.invalidate()
        recheck = nil
        stopTap()
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged || type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else { return }
        let prefs = VoicePreferencesStore.shared.prefs
        guard prefs.enabled, prefs.isGlobalHotkeyEnabled else { return }
        let session = VoiceSessionController.shared
        let decision = VoiceGlobalKeyRouter.decide(
            isKeyDown: type == .keyDown,
            keyCode: nsEvent.keyCode,
            flags: nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask),
            trigger: prefs.triggerKey,
            isSecureInput: IsSecureEventInputEnabled(),
            isRecording: session.isRecording
        )
        switch decision {
        case .ignore:
            return
        case .cancelChord:
            session.cancelForChord()
        case .forward:
            let committer = self.committer
            _ = session.handleEvent(
                nsEvent,
                caretRectProvider: {
                    committer.captureTarget()
                    return committer.anchorRect()
                },
                windowLevel: nil,
                contextProvider: {
                    VoiceContext(
                        bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        personalVocabulary: prefs.parsedCustomVocabulary
                    )
                },
                onCommit: { text, _ in
                    committer.commit(text) { notice in
                        if let notice { VoiceSessionController.sharedIfLoaded?.showExternalNotice(notice) }
                    }
                }
            )
        }
    }
}
