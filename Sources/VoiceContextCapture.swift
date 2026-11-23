import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// MARK: - Typeless-Style macOS Native Context Capture (AXUIElement + AXEnhancedUserInterface)

public struct VoiceContextCaptureOptions: Equatable, Sendable {
    /// Maximum time allowed for each expensive AX read phase (visible screen text, surrounding context).
    public var timeoutMs: Int
    /// Maximum characters to collect for `visible_screen_content` (~10K tokens ≈ 20K chars).
    public var maxVisibleChars: Int
    /// Maximum characters before/after cursor in `cursor_state` (~1K tokens ≈ 2K chars each).
    public var maxCursorBeforeChars: Int
    public var maxCursorAfterChars: Int
    /// Maximum characters for `selected_text` (~5K tokens ≈ 12K chars).
    public var maxSelectedChars: Int
    /// Maximum characters before/after the input area in `surrounding_context`.
    public var maxSurroundingBeforeChars: Int
    public var maxSurroundingAfterChars: Int
    /// Whether to enforce the check-before-read app/URL blacklist for visible & surrounding content.
    public var respectBlacklist: Bool
    /// Additional user-configured bundle IDs to blacklist.
    public var extraBlacklistedBundleIds: [String]
    /// Additional user-configured URL prefixes to blacklist.
    public var extraBlacklistedURLPrefixes: [String]

    public init(
        timeoutMs: Int = 500,
        maxVisibleChars: Int = 20_000,
        maxCursorBeforeChars: Int = 2_000,
        maxCursorAfterChars: Int = 2_000,
        maxSelectedChars: Int = 12_000,
        maxSurroundingBeforeChars: Int = 2_000,
        maxSurroundingAfterChars: Int = 2_000,
        respectBlacklist: Bool = true,
        extraBlacklistedBundleIds: [String] = [],
        extraBlacklistedURLPrefixes: [String] = []
    ) {
        self.timeoutMs = max(50, timeoutMs)
        self.maxVisibleChars = max(0, maxVisibleChars)
        self.maxCursorBeforeChars = max(0, maxCursorBeforeChars)
        self.maxCursorAfterChars = max(0, maxCursorAfterChars)
        self.maxSelectedChars = max(0, maxSelectedChars)
        self.maxSurroundingBeforeChars = max(0, maxSurroundingBeforeChars)
        self.maxSurroundingAfterChars = max(0, maxSurroundingAfterChars)
        self.respectBlacklist = respectBlacklist
        self.extraBlacklistedBundleIds = extraBlacklistedBundleIds
        self.extraBlacklistedURLPrefixes = extraBlacklistedURLPrefixes
    }
}

public struct VoiceCapturedContext: Codable, Equatable, Sendable {
    public struct ActiveApplication: Codable, Equatable, Sendable {
        public struct AppMetadata: Codable, Equatable, Sendable {
            public var processId: Int32
            public var appPath: String?

            public enum CodingKeys: String, CodingKey {
                case processId = "process_id"
                case appPath = "app_path"
            }

            public init(processId: Int32, appPath: String?) {
                self.processId = processId
                self.appPath = appPath
            }
        }

        public var appName: String
        public var appIdentifier: String
        public var windowTitle: String
        public var webURL: String?
        public var appType: String
        public var isWebBrowser: Bool
        public var appMetadata: AppMetadata
        public var visibleScreenContent: String?

        public enum CodingKeys: String, CodingKey {
            case appName = "app_name"
            case appIdentifier = "app_identifier"
            case windowTitle = "window_title"
            case webURL = "web_url"
            case appType = "app_type"
            case isWebBrowser = "is_web_browser"
            case appMetadata = "app_metadata"
            case visibleScreenContent = "visible_screen_content"
        }

        public init(
            appName: String,
            appIdentifier: String,
            windowTitle: String,
            webURL: String?,
            appType: String,
            isWebBrowser: Bool,
            appMetadata: AppMetadata,
            visibleScreenContent: String?
        ) {
            self.appName = appName
            self.appIdentifier = appIdentifier
            self.windowTitle = windowTitle
            self.webURL = webURL
            self.appType = appType
            self.isWebBrowser = isWebBrowser
            self.appMetadata = appMetadata
            self.visibleScreenContent = visibleScreenContent
        }
    }

    public struct TextInsertionPoint: Codable, Equatable, Sendable {
        public struct InputCapabilities: Codable, Equatable, Sendable {
            public var isEditable: Bool
            public var isSecure: Bool

            public enum CodingKeys: String, CodingKey {
                case isEditable = "is_editable"
                case isSecure = "is_secure"
            }

            public init(isEditable: Bool, isSecure: Bool) {
                self.isEditable = isEditable
                self.isSecure = isSecure
            }
        }

        public struct CursorState: Codable, Equatable, Sendable {
            public var cursorPosition: Int?
            public var selectionLength: Int
            public var hasTextSelected: Bool
            public var selectedText: String
            public var textBeforeCursor: String
            public var textAfterCursor: String

            public enum CodingKeys: String, CodingKey {
                case cursorPosition = "cursor_position"
                case selectionLength = "selection_length"
                case hasTextSelected = "has_text_selected"
                case selectedText = "selected_text"
                case textBeforeCursor = "text_before_cursor"
                case textAfterCursor = "text_after_cursor"
            }

            public init(
                cursorPosition: Int? = nil,
                selectionLength: Int = 0,
                hasTextSelected: Bool = false,
                selectedText: String = "",
                textBeforeCursor: String = "",
                textAfterCursor: String = ""
            ) {
                self.cursorPosition = cursorPosition
                self.selectionLength = selectionLength
                self.hasTextSelected = hasTextSelected
                self.selectedText = selectedText
                self.textBeforeCursor = textBeforeCursor
                self.textAfterCursor = textAfterCursor
            }
        }

        public struct SurroundingContext: Codable, Equatable, Sendable {
            public var textBeforeInputArea: String
            public var textAfterInputArea: String

            public enum CodingKeys: String, CodingKey {
                case textBeforeInputArea = "text_before_input_area"
                case textAfterInputArea = "text_after_input_area"
            }

            public init(textBeforeInputArea: String = "", textAfterInputArea: String = "") {
                self.textBeforeInputArea = textBeforeInputArea
                self.textAfterInputArea = textAfterInputArea
            }
        }

        public var inputAreaType: String
        public var accessibilityRole: String
        public var accessibilitySubrole: String?
        public var inputCapabilities: InputCapabilities
        public var cursorState: CursorState
        public var surroundingContext: SurroundingContext

        public enum CodingKeys: String, CodingKey {
            case inputAreaType = "input_area_type"
            case accessibilityRole = "accessibility_role"
            case accessibilitySubrole = "accessibility_subrole"
            case inputCapabilities = "input_capabilities"
            case cursorState = "cursor_state"
            case surroundingContext = "surrounding_context"
        }

        public init(
            inputAreaType: String = "unknown",
            accessibilityRole: String = "",
            accessibilitySubrole: String? = nil,
            inputCapabilities: InputCapabilities = InputCapabilities(isEditable: false, isSecure: false),
            cursorState: CursorState = CursorState(),
            surroundingContext: SurroundingContext = SurroundingContext()
        ) {
            self.inputAreaType = inputAreaType
            self.accessibilityRole = accessibilityRole
            self.accessibilitySubrole = accessibilitySubrole
            self.inputCapabilities = inputCapabilities
            self.cursorState = cursorState
            self.surroundingContext = surroundingContext
        }
    }

    public struct ContextMetadata: Codable, Equatable, Sendable {
        public var isOwnApplication: Bool
        public var isAccessibilityTrusted: Bool
        public var enhancedUIEnabled: Bool
        public var isBlacklisted: Bool
        public var blacklistReason: String?
        public var isSecureInput: Bool
        public var timedOutVisible: Bool
        public var timedOutSurrounding: Bool
        public var elapsedMs: Int
        public var captureTimestamp: String

        public enum CodingKeys: String, CodingKey {
            case isOwnApplication = "is_own_application"
            case isAccessibilityTrusted = "is_accessibility_trusted"
            case enhancedUIEnabled = "enhanced_ui_enabled"
            case isBlacklisted = "is_blacklisted"
            case blacklistReason = "blacklist_reason"
            case isSecureInput = "is_secure_input"
            case timedOutVisible = "timed_out_visible"
            case timedOutSurrounding = "timed_out_surrounding"
            case elapsedMs = "elapsed_ms"
            case captureTimestamp = "capture_timestamp"
        }

        public init(
            isOwnApplication: Bool = false,
            isAccessibilityTrusted: Bool = false,
            enhancedUIEnabled: Bool = false,
            isBlacklisted: Bool = false,
            blacklistReason: String? = nil,
            isSecureInput: Bool = false,
            timedOutVisible: Bool = false,
            timedOutSurrounding: Bool = false,
            elapsedMs: Int = 0,
            captureTimestamp: String = ""
        ) {
            self.isOwnApplication = isOwnApplication
            self.isAccessibilityTrusted = isAccessibilityTrusted
            self.enhancedUIEnabled = enhancedUIEnabled
            self.isBlacklisted = isBlacklisted
            self.blacklistReason = blacklistReason
            self.isSecureInput = isSecureInput
            self.timedOutVisible = timedOutVisible
            self.timedOutSurrounding = timedOutSurrounding
            self.elapsedMs = elapsedMs
            self.captureTimestamp = captureTimestamp
        }
    }

    public var activeApplication: ActiveApplication
    public var textInsertionPoint: TextInsertionPoint
    public var contextMetadata: ContextMetadata

    public enum CodingKeys: String, CodingKey {
        case activeApplication = "active_application"
        case textInsertionPoint = "text_insertion_point"
        case contextMetadata = "context_metadata"
    }

    public init(
        activeApplication: ActiveApplication,
        textInsertionPoint: TextInsertionPoint,
        contextMetadata: ContextMetadata
    ) {
        self.activeApplication = activeApplication
        self.textInsertionPoint = textInsertionPoint
        self.contextMetadata = contextMetadata
    }

    public func prettyJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    public func compactJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - Policy & Pure Helpers (Unit-Testable Without Live AX)

public enum VoiceContextPolicy {
    /// Always blocked (even cursor state) to prevent reading credentials.
    public static let hardBlockedBundleIds: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "org.keepassxc.keepassxc",
    ]

    /// Default check-before-read blacklist for large screen/surrounding captures (matches Typeless defaults).
    public static let defaultBlacklistedBundleIds: Set<String> = [
        "com.sublimetext.4",
        "com.tencent.xinWeChat",
        "com.microsoft.Excel",
        "com.kingsoft.wpsoffice.mac",
        "dev.zed.Zed",
    ]

    public static let defaultBlacklistedURLPrefixes: [String] = [
        "https://docs.google.com/document/d",
        "https://docs.qq.com/doc/",
        "https://docs.qq.com/sheet/",
    ]

    public static let knownBrowserBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "app.zen-browser.zen",
        "com.kagi.kagimacOS",
        "com.openai.atlas",
        "ai.perplexity.comet",
        "com.jackwener.kaze",
    ]

    public static let geckoBrowserBundleIds: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "app.zen-browser.zen",
    ]

    public static let knownElectronOrChromiumBundleIds: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.figma.Desktop",
        "notion.id",
        "md.obsidian",
        "com.hnc.Discord",
        "com.electron.lark",
        "com.bytedance.feishu",
        "com.linear",
        "com.openai.chat",
    ]

    public static let knownCodeEditorHints: [String] = [
        "vscode", "cursor", "xcode", "jetbrains", "intellij", "pycharm",
        "zed", "sublimetext", "terminal", "iterm", "ghostty", "warp", "alacritty", "kitty",
    ]

    public static func isHardBlocked(bundleId: String) -> Bool {
        hardBlockedBundleIds.contains(bundleId)
    }

    public static func blacklistReason(
        bundleId: String,
        webURL: String?,
        options: VoiceContextCaptureOptions
    ) -> String? {
        if isHardBlocked(bundleId: bundleId) {
            return "password_manager:\(bundleId)"
        }
        guard options.respectBlacklist else { return nil }
        if defaultBlacklistedBundleIds.contains(bundleId) || options.extraBlacklistedBundleIds.contains(bundleId) {
            return "app_blacklist:\(bundleId)"
        }
        if let url = webURL, !url.isEmpty {
            let allPrefixes = defaultBlacklistedURLPrefixes + options.extraBlacklistedURLPrefixes
            for prefix in allPrefixes where !prefix.isEmpty && url.hasPrefix(prefix) {
                return "url_blacklist:\(prefix)"
            }
        }
        return nil
    }

    public static func isWebBrowser(bundleId: String) -> Bool {
        knownBrowserBundleIds.contains(bundleId)
    }

    public static func isElectronOrChromiumApp(bundleId: String, appPath: String?) -> Bool {
        if knownBrowserBundleIds.contains(bundleId) || knownElectronOrChromiumBundleIds.contains(bundleId) {
            return true
        }
        guard let appPath, !appPath.isEmpty else { return false }
        let fm = FileManager.default
        let markers = [
            "Contents/Frameworks/Electron Framework.framework",
            "Contents/Frameworks/Google Chrome Framework.framework",
            "Contents/Frameworks/Chromium Embedded Framework.framework",
        ]
        for rel in markers {
            if fm.fileExists(atPath: (appPath as NSString).appendingPathComponent(rel)) {
                return true
            }
        }
        return false
    }

    public static func classifyAppType(bundleId: String, appPath: String?) -> String {
        if isWebBrowser(bundleId: bundleId) { return "web_browser" }
        if isElectronOrChromiumApp(bundleId: bundleId, appPath: appPath) { return "electron_app" }
        return "native_app"
    }

    public static func classifyInputAreaType(
        bundleId: String,
        role: String,
        isEditable: Bool,
        isInsideWebArea: Bool
    ) -> String {
        if !isEditable && role.isEmpty { return "unknown" }
        let lower = bundleId.lowercased()
        if knownCodeEditorHints.contains(where: { lower.contains($0) }) {
            return "code_editor"
        }
        if role == "AXWebArea" || isInsideWebArea {
            return "web_area"
        }
        if role == kAXTextAreaRole as String {
            if lower.contains("mail") || lower.contains("notes") || lower.contains("pages")
                || lower.contains("word") || lower.contains("slack") || lower.contains("notion") {
                return "rich_text"
            }
            return "plain_text"
        }
        if role == kAXTextFieldRole as String || role == kAXComboBoxRole as String || role == "AXSearchField" {
            return "plain_text"
        }
        return isEditable ? "plain_text" : "unknown"
    }

    /// Typeless hardcoded guard: in Notion web pages when focus lands on the whole `AXWebArea`,
    /// do not treat the entire document as cursor state.
    public static func shouldClearNotionWebAreaCursor(
        isWebBrowser: Bool,
        webURL: String?,
        role: String
    ) -> Bool {
        guard isWebBrowser, role == "AXWebArea", let url = webURL else { return false }
        return url.hasPrefix("https://www.notion.so/") || url.hasPrefix("https://notion.so/")
    }

    /// Safe UTF-16 slicing around a `CFRange` (never crashes on surrogate pairs or out-of-range indices).
    public static func sliceCursorContext(
        fullText: String,
        selectionLocationUTF16: Int,
        selectionLengthUTF16: Int,
        maxBeforeChars: Int,
        maxAfterChars: Int,
        maxSelectedChars: Int
    ) -> (before: String, selected: String, after: String) {
        let ns = fullText as NSString
        let total = ns.length
        let loc = max(0, min(selectionLocationUTF16, total))
        let len = max(0, min(selectionLengthUTF16, total - loc))

        let selectedRaw = len > 0 ? ns.substring(with: NSRange(location: loc, length: len)) : ""
        let selected = String(selectedRaw.prefix(maxSelectedChars))

        let beforeUTF16Cap = min(loc, maxBeforeChars * 2)
        let beforeStart = max(0, loc - beforeUTF16Cap)
        let beforeRaw = beforeStart < loc
            ? ns.substring(with: NSRange(location: beforeStart, length: loc - beforeStart))
            : ""
        let before = String(beforeRaw.suffix(maxBeforeChars))

        let afterStart = loc + len
        let afterUTF16Cap = min(total - afterStart, maxAfterChars * 2)
        let afterRaw = afterUTF16Cap > 0
            ? ns.substring(with: NSRange(location: afterStart, length: afterUTF16Cap))
            : ""
        let after = String(afterRaw.prefix(maxAfterChars))

        return (before, selected, after)
    }

    public static func normalizeURLCandidate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains(" "), trimmed.count <= 2048 else {
            return nil
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") {
            return trimmed
        }
        // Address bar values in Safari/Chrome often omit `https://` (e.g. `github.com/nameoverflow/juxu`)
        if trimmed.contains(".") && !trimmed.hasPrefix(".") && !trimmed.hasSuffix(".") {
            let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
            if hostPart.contains(".") && hostPart.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) {
                return "https://\(trimmed)"
            }
        }
        return nil
    }
}

// MARK: - Live AX Capture Engine

public enum VoiceContextCapture {
    private static let captureQueue = DispatchQueue(
        label: "im.juxu.voice.context-capture",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private struct FrontmostSnapshot: Sendable {
        let appName: String
        let bundleId: String
        let pid: pid_t
        let appPath: String?
        let isOwnApp: Bool
        let isSecureEventInput: Bool
    }

    /// Captures frontmost app metadata on MainActor, then performs all AXUIElement queries off the main thread
    /// with strict per-phase deadlines so a frozen target app never blocks the UI or typing.
    public static func captureAsync(
        options: VoiceContextCaptureOptions = VoiceContextCaptureOptions()
    ) async -> VoiceCapturedContext {
        let frontmost: FrontmostSnapshot = await MainActor.run {
            snapshotFrontmost()
        }
        return await withCheckedContinuation { cont in
            captureQueue.async {
                let result = performCapture(frontmost: frontmost, options: options)
                cont.resume(returning: result)
            }
        }
    }

    /// Synchronous entry point (for CLI / background threads).
    public static func captureSync(
        options: VoiceContextCaptureOptions = VoiceContextCaptureOptions()
    ) -> VoiceCapturedContext {
        let frontmost: FrontmostSnapshot
        if Thread.isMainThread {
            frontmost = snapshotFrontmost()
        } else {
            frontmost = DispatchQueue.main.sync { snapshotFrontmost() }
        }
        return performCapture(frontmost: frontmost, options: options)
    }

    private static func snapshotFrontmost() -> FrontmostSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let pid = app?.processIdentifier ?? 0
        return FrontmostSnapshot(
            appName: app?.localizedName ?? "",
            bundleId: app?.bundleIdentifier ?? "",
            pid: pid,
            appPath: app?.bundleURL?.path,
            isOwnApp: pid == ownPid && pid != 0,
            isSecureEventInput: IsSecureEventInputEnabled()
        )
    }

    private static func performCapture(
        frontmost: FrontmostSnapshot,
        options: VoiceContextCaptureOptions
    ) -> VoiceCapturedContext {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let isoTimestamp = ISO8601DateFormatter().string(from: Date())
        let trusted = AXIsProcessTrusted()
        let isBrowser = VoiceContextPolicy.isWebBrowser(bundleId: frontmost.bundleId)
        let appType = VoiceContextPolicy.classifyAppType(bundleId: frontmost.bundleId, appPath: frontmost.appPath)

        var activeApp = VoiceCapturedContext.ActiveApplication(
            appName: frontmost.appName,
            appIdentifier: frontmost.bundleId,
            windowTitle: "",
            webURL: nil,
            appType: appType,
            isWebBrowser: isBrowser,
            appMetadata: .init(processId: frontmost.pid, appPath: frontmost.appPath),
            visibleScreenContent: nil
        )
        var insertion = VoiceCapturedContext.TextInsertionPoint()
        var meta = VoiceCapturedContext.ContextMetadata(
            isOwnApplication: frontmost.isOwnApp,
            isAccessibilityTrusted: trusted,
            enhancedUIEnabled: false,
            isBlacklisted: false,
            blacklistReason: nil,
            isSecureInput: frontmost.isSecureEventInput,
            timedOutVisible: false,
            timedOutSurrounding: false,
            elapsedMs: 0,
            captureTimestamp: isoTimestamp
        )

        func finish() -> VoiceCapturedContext {
            let endNs = DispatchTime.now().uptimeNanoseconds
            meta.elapsedMs = Int((endNs >= startNs ? endNs - startNs : 0) / 1_000_000)
            return VoiceCapturedContext(
                activeApplication: activeApp,
                textInsertionPoint: insertion,
                contextMetadata: meta
            )
        }

        guard trusted, frontmost.pid > 0 else {
            return finish()
        }

        let appElement = AXUIElementCreateApplication(frontmost.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        // Step 1: Enable AXEnhancedUserInterface for browsers / Electron / Chromium apps so DOM & editor AX trees are exposed.
        if VoiceContextPolicy.isElectronOrChromiumApp(bundleId: frontmost.bundleId, appPath: frontmost.appPath) {
            meta.enhancedUIEnabled = enableEnhancedUI(
                on: appElement,
                bundleId: frontmost.bundleId
            )
        }

        // Step 2: Focused window & focused element.
        let focusedWindow = copyElement(appElement, kAXFocusedWindowAttribute)
            ?? copyElement(appElement, kAXMainWindowAttribute)
        if let focusedWindow {
            AXUIElementSetMessagingTimeout(focusedWindow, 0.25)
            activeApp.windowTitle = copyString(focusedWindow, kAXTitleAttribute) ?? ""
        }

        var focusedElement = resolveFocusedElement(appElement: appElement)
        let focusedRoleBeforeEnhance = focusedElement.flatMap { copyString($0, kAXRoleAttribute) } ?? ""
        let needsEnhancedFallback = focusedElement == nil
            || focusedRoleBeforeEnhance.isEmpty
            || focusedRoleBeforeEnhance == (kAXWindowRole as String)
            || focusedRoleBeforeEnhance == (kAXApplicationRole as String)
            || focusedRoleBeforeEnhance == (kAXGroupRole as String)
            || focusedRoleBeforeEnhance == (kAXUnknownRole as String)
        if needsEnhancedFallback, !meta.enhancedUIEnabled {
            // Fallback: some Chromium/Electron apps don't expose standard frameworks at top level;
            // enable AXEnhancedUserInterface once and re-query the focused element.
            if enableEnhancedUI(on: appElement, bundleId: frontmost.bundleId) {
                meta.enhancedUIEnabled = true
                focusedElement = resolveFocusedElement(appElement: appElement)
            }
        }
        if let focusedElement {
            AXUIElementSetMessagingTimeout(focusedElement, 0.25)
        }

        // Step 3: Browser URL (pure AX, zero AppleScript / Automation prompts).
        if isBrowser || appType == "electron_app" {
            let urlDeadline = deadlineAfter(ms: min(180, options.timeoutMs))
            activeApp.webURL = extractWebURL(
                focusedElement: focusedElement,
                focusedWindow: focusedWindow,
                deadline: urlDeadline
            )
        }

        // Step 4: Check security & blacklist BEFORE reading text.
        let hardBlocked = VoiceContextPolicy.isHardBlocked(bundleId: frontmost.bundleId)
        let subrole = focusedElement.flatMap { copyString($0, kAXSubroleAttribute) }
        let isSecureElement = (subrole == (kAXSecureTextFieldSubrole as String))
        let isSecure = frontmost.isSecureEventInput || isSecureElement || hardBlocked
        meta.isSecureInput = frontmost.isSecureEventInput || isSecureElement

        let blacklistReason = VoiceContextPolicy.blacklistReason(
            bundleId: frontmost.bundleId,
            webURL: activeApp.webURL,
            options: options
        )
        meta.isBlacklisted = (blacklistReason != nil)
        meta.blacklistReason = blacklistReason

        let role = focusedElement.flatMap { copyString($0, kAXRoleAttribute) } ?? ""
        let isInsideWebArea = focusedElement.map { hasAncestor(of: $0, role: "AXWebArea", maxHops: 24) } ?? false
        let isEditable = focusedElement.map { isElementEditable($0, role: role) } ?? false

        insertion.accessibilityRole = role
        insertion.accessibilitySubrole = subrole
        insertion.inputCapabilities = .init(isEditable: isEditable, isSecure: isSecureElement)
        insertion.inputAreaType = VoiceContextPolicy.classifyInputAreaType(
            bundleId: frontmost.bundleId,
            role: role,
            isEditable: isEditable,
            isInsideWebArea: isInsideWebArea
        )

        if isSecure {
            return finish()
        }

        // Step 5: Cursor state (collected for non-secure focused field, matching Typeless's `getCurrentInputState`).
        if let focusedElement, !frontmost.isOwnApp {
            var cursorState = readCursorState(element: focusedElement, options: options)
            if VoiceContextPolicy.shouldClearNotionWebAreaCursor(
                isWebBrowser: isBrowser,
                webURL: activeApp.webURL,
                role: role
            ) {
                cursorState.cursorPosition = 0
                cursorState.selectionLength = 0
                cursorState.hasTextSelected = false
                cursorState.textBeforeCursor = ""
                cursorState.textAfterCursor = ""
            }
            insertion.cursorState = cursorState
        }

        // Step 6: Blacklist gate BEFORE reading surrounding_context and visible_screen_content.
        guard !meta.isBlacklisted, !frontmost.isOwnApp else {
            return finish()
        }

        // Run surrounding context & visible screen content concurrently under the timeout budget.
        let group = DispatchGroup()
        let resultLock = NSLock()
        var surroundingResult = VoiceCapturedContext.TextInsertionPoint.SurroundingContext()
        var timedOutSurrounding = false
        var visibleResult: String? = nil
        var timedOutVisible = false

        if let focusedElement,
           (options.maxSurroundingBeforeChars > 0 || options.maxSurroundingAfterChars > 0) {
            group.enter()
            let elemBox = UncheckedAXBox(element: focusedElement)
            let dl = deadlineAfter(ms: options.timeoutMs)
            captureQueue.async {
                let (ctx, timedOut) = readSurroundingContext(
                    focusedElement: elemBox.element,
                    maxBeforeChars: options.maxSurroundingBeforeChars,
                    maxAfterChars: options.maxSurroundingAfterChars,
                    deadline: dl
                )
                resultLock.lock()
                surroundingResult = ctx
                timedOutSurrounding = timedOut
                resultLock.unlock()
                group.leave()
            }
        }

        if let rootWindow = focusedWindow, options.maxVisibleChars > 0 {
            group.enter()
            let winBox = UncheckedAXBox(element: rootWindow)
            let dl = deadlineAfter(ms: options.timeoutMs)
            captureQueue.async {
                let (text, timedOut) = readVisibleScreenText(
                    window: winBox.element,
                    maxChars: options.maxVisibleChars,
                    deadline: dl
                )
                resultLock.lock()
                visibleResult = text.isEmpty ? nil : text
                timedOutVisible = timedOut
                resultLock.unlock()
                group.leave()
            }
        }

        let waitLimit = DispatchTime.now() + .milliseconds(options.timeoutMs + 80)
        if group.wait(timeout: waitLimit) == .timedOut {
            resultLock.lock()
            timedOutVisible = timedOutVisible || (visibleResult == nil && focusedWindow != nil && options.maxVisibleChars > 0)
            timedOutSurrounding = timedOutSurrounding || (focusedElement != nil && options.maxSurroundingBeforeChars > 0)
            resultLock.unlock()
        }

        resultLock.lock()
        insertion.surroundingContext = surroundingResult
        activeApp.visibleScreenContent = visibleResult
        meta.timedOutSurrounding = timedOutSurrounding
        meta.timedOutVisible = timedOutVisible
        resultLock.unlock()

        return finish()
    }

    // MARK: - AXEnhancedUserInterface

    private static func enableEnhancedUI(on appElement: AXUIElement, bundleId: String) -> Bool {
        let attr = "AXEnhancedUserInterface" as CFString
        if copyBool(appElement, attr) == true {
            return true
        }
        let status = AXUIElementSetAttributeValue(appElement, attr, kCFBooleanTrue)
        var enabled = (status == .success)

        if VoiceContextPolicy.geckoBrowserBundleIds.contains(bundleId) {
            let manualAttr = "AXManualAccessibility" as CFString
            if AXUIElementSetAttributeValue(appElement, manualAttr, kCFBooleanTrue) == .success {
                enabled = true
            }
        }
        if enabled {
            // Brief settle time on first enablement so Chromium/Electron populates its AX tree.
            usleep(35_000)
        }
        return enabled
    }

    // MARK: - Focused Element & Capabilities

    private static func resolveFocusedElement(appElement: AXUIElement) -> AXUIElement? {
        if let elem = copyElement(appElement, kAXFocusedUIElementAttribute) {
            return elem
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        return copyElement(system, kAXFocusedUIElementAttribute)
    }

    private static func isElementEditable(_ element: AXUIElement, role: String) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if copyBool(element, "AXEditable" as CFString) == true {
            return true
        }
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        return editableRoles.contains(role)
    }

    private static func hasAncestor(of element: AXUIElement, role targetRole: String, maxHops: Int) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<maxHops {
            guard let node = current else { return false }
            if copyString(node, kAXRoleAttribute) == targetRole {
                return true
            }
            current = copyElement(node, kAXParentAttribute)
        }
        return false
    }

    // MARK: - Browser URL Extraction (Pure AX)

    private static func extractWebURL(
        focusedElement: AXUIElement?,
        focusedWindow: AXUIElement?,
        deadline: UInt64
    ) -> String? {
        // 1. Walk up from focusedElement to find AXWebArea / AXURL.
        if let focusedElement {
            var current: AXUIElement? = focusedElement
            for _ in 0..<32 {
                if isPast(deadline) { break }
                guard let node = current else { break }
                if let url = copyURLString(node, "AXURL" as CFString) {
                    return url
                }
                current = copyElement(node, kAXParentAttribute)
            }
        }

        guard let focusedWindow else { return nil }

        // 2. Window document URL (e.g. Safari/some browsers expose it directly).
        if let doc = copyString(focusedWindow, kAXDocumentAttribute),
           let normalized = VoiceContextPolicy.normalizeURLCandidate(doc) {
            return normalized
        }

        // 3. Bounded BFS on window tree for AXWebArea -> AXURL or address bar AXTextField.
        var queue: [(AXUIElement, Int)] = [(focusedWindow, 0)]
        var visited = 0
        let maxVisited = 160
        var addressBarFallback: String? = nil

        while !queue.isEmpty && visited < maxVisited && !isPast(deadline) {
            let (node, depth) = queue.removeFirst()
            visited += 1
            let role = copyString(node, kAXRoleAttribute) ?? ""

            if role == "AXWebArea" {
                if let url = copyURLString(node, "AXURL" as CFString) {
                    return url
                }
            }

            if addressBarFallback == nil && (role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String)) {
                let id = (copyString(node, kAXIdentifierAttribute) ?? "").lowercased()
                let desc = (copyString(node, kAXDescriptionAttribute) ?? "").lowercased()
                let roleDesc = (copyString(node, kAXRoleDescriptionAttribute) ?? "").lowercased()
                let isAddressBar = id.contains("address") || id.contains("url") || id.contains("location")
                    || desc.contains("address") || desc.contains("url") || desc.contains("地址") || desc.contains("网址")
                    || roleDesc.contains("address")
                if isAddressBar, let rawVal = copyString(node, kAXValueAttribute),
                   let normalized = VoiceContextPolicy.normalizeURLCandidate(rawVal) {
                    addressBarFallback = normalized
                }
            }

            if depth < 9 {
                let children = copyElementArray(node, kAXChildrenAttribute)
                for child in children.prefix(32) {
                    queue.append((child, depth + 1))
                }
            }
        }

        return addressBarFallback
    }

    // MARK: - Cursor State (Standard AXRange + Web/Electron AXTextMarkerRange)

    private static func readCursorState(
        element: AXUIElement,
        options: VoiceContextCaptureOptions
    ) -> VoiceCapturedContext.TextInsertionPoint.CursorState {
        var selectedText = copyString(element, kAXSelectedTextAttribute) ?? ""
        if selectedText.count > options.maxSelectedChars {
            selectedText = String(selectedText.prefix(options.maxSelectedChars))
        }

        // Strategy A: Standard `kAXSelectedTextRangeAttribute` + `kAXStringForRangeParameterizedAttribute` / `kAXValueAttribute`.
        if let selRange = copyCFRange(element, kAXSelectedTextRangeAttribute), selRange.location >= 0 {
            let selLoc = selRange.location
            let selLen = max(0, selRange.length)
            let totalChars = copyInt(element, kAXNumberOfCharactersAttribute)

            // Prefer parameterized range queries so 100K-word documents don't copy the entire string.
            let beforeStart = max(0, selLoc - options.maxCursorBeforeChars)
            let beforeLen = selLoc - beforeStart
            let beforeParam = beforeLen > 0
                ? copyStringForRange(element, CFRange(location: beforeStart, length: beforeLen))
                : ""

            let afterStart = selLoc + selLen
            let afterLen: Int
            if let totalChars, totalChars >= afterStart {
                afterLen = min(options.maxCursorAfterChars, totalChars - afterStart)
            } else {
                afterLen = options.maxCursorAfterChars
            }
            let afterParam = afterLen > 0
                ? copyStringForRange(element, CFRange(location: afterStart, length: afterLen))
                : ""

            if selectedText.isEmpty && selLen > 0,
               let fetchedSel = copyStringForRange(element, CFRange(location: selLoc, length: min(selLen, options.maxSelectedChars))) {
                selectedText = String(fetchedSel.prefix(options.maxSelectedChars))
            }

            if beforeParam != nil || afterParam != nil {
                return .init(
                    cursorPosition: selLoc,
                    selectionLength: selLen,
                    hasTextSelected: selLen > 0 || !selectedText.isEmpty,
                    selectedText: selectedText,
                    textBeforeCursor: String((beforeParam ?? "").suffix(options.maxCursorBeforeChars)),
                    textAfterCursor: String((afterParam ?? "").prefix(options.maxCursorAfterChars))
                )
            }

            // Fallback: read `kAXValueAttribute` and slice safely around the range.
            if let fullText = copyString(element, kAXValueAttribute) {
                let sliced = VoiceContextPolicy.sliceCursorContext(
                    fullText: fullText,
                    selectionLocationUTF16: selLoc,
                    selectionLengthUTF16: selLen,
                    maxBeforeChars: options.maxCursorBeforeChars,
                    maxAfterChars: options.maxCursorAfterChars,
                    maxSelectedChars: options.maxSelectedChars
                )
                return .init(
                    cursorPosition: selLoc,
                    selectionLength: selLen,
                    hasTextSelected: selLen > 0 || !selectedText.isEmpty || !sliced.selected.isEmpty,
                    selectedText: selectedText.isEmpty ? sliced.selected : selectedText,
                    textBeforeCursor: sliced.before,
                    textAfterCursor: sliced.after
                )
            }
        }

        // Strategy B: Web / Chromium / Electron `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange`.
        if let markerState = readWebTextMarkerCursorState(element: element, existingSelected: selectedText, options: options) {
            return markerState
        }

        // Strategy C: Element has `AXValue` (or child `AXStaticText` nodes in contenteditable) without a range.
        if let fullText = copyString(element, kAXValueAttribute), !fullText.isEmpty {
            return .init(
                cursorPosition: nil,
                selectionLength: selectedText.utf16.count,
                hasTextSelected: !selectedText.isEmpty,
                selectedText: selectedText,
                textBeforeCursor: String(fullText.suffix(options.maxCursorBeforeChars)),
                textAfterCursor: ""
            )
        }

        // Contenteditable rich editors sometimes expose text only via direct child AXStaticText elements.
        let childTexts = collectInlineText(from: element, maxChars: options.maxCursorBeforeChars, maxNodes: 40)
        if !childTexts.isEmpty || !selectedText.isEmpty {
            return .init(
                cursorPosition: nil,
                selectionLength: selectedText.utf16.count,
                hasTextSelected: !selectedText.isEmpty,
                selectedText: selectedText,
                textBeforeCursor: String(childTexts.suffix(options.maxCursorBeforeChars)),
                textAfterCursor: ""
            )
        }

        return .init(
            cursorPosition: nil,
            selectionLength: selectedText.utf16.count,
            hasTextSelected: !selectedText.isEmpty,
            selectedText: selectedText,
            textBeforeCursor: "",
            textAfterCursor: ""
        )
    }

    private static func readWebTextMarkerCursorState(
        element: AXUIElement,
        existingSelected: String,
        options: VoiceContextCaptureOptions
    ) -> VoiceCapturedContext.TextInsertionPoint.CursorState? {
        var markerRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef) == .success,
              let markerRange = markerRangeRef else {
            return nil
        }

        var selectedText = existingSelected
        if selectedText.isEmpty,
           let fetched = copyStringForParameterized(element, "AXStringForTextMarkerRange" as CFString, param: markerRange) {
            selectedText = String(fetched.prefix(options.maxSelectedChars))
        }

        // Try extracting start/end markers via parameterized attributes exposed by WebKit & Chromium.
        var selStartMarker: CFTypeRef?
        var selEndMarker: CFTypeRef?
        _ = AXUIElementCopyParameterizedAttributeValue(element, "AXStartTextMarkerForTextMarkerRange" as CFString, markerRange, &selStartMarker)
        _ = AXUIElementCopyParameterizedAttributeValue(element, "AXEndTextMarkerForTextMarkerRange" as CFString, markerRange, &selEndMarker)

        var cursorPos: Int? = nil
        if let startM = selStartMarker {
            var idxRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, "AXIndexForTextMarker" as CFString, startM, &idxRef) == .success,
               let num = idxRef as? NSNumber {
                cursorPos = num.intValue
            }
        }

        var beforeText = ""
        var afterText = ""

        var docStartMarker: CFTypeRef?
        var docEndMarker: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, "AXStartTextMarker" as CFString, &docStartMarker)
        _ = AXUIElementCopyAttributeValue(element, "AXEndTextMarker" as CFString, &docEndMarker)

        if let docStart = docStartMarker, let selStart = selStartMarker {
            // If we have an index and the document is huge, create a bounded start marker first.
            var boundedStart: CFTypeRef = docStart
            if let pos = cursorPos, pos > options.maxCursorBeforeChars {
                var mRef: CFTypeRef?
                let targetIdx = NSNumber(value: pos - options.maxCursorBeforeChars)
                if AXUIElementCopyParameterizedAttributeValue(element, "AXTextMarkerForIndex" as CFString, targetIdx, &mRef) == .success,
                   let mRef {
                    boundedStart = mRef
                }
            }
            if let range = makeMarkerRange(element: element, markerA: boundedStart, markerB: selStart),
               let text = copyStringForParameterized(element, "AXStringForTextMarkerRange" as CFString, param: range) {
                beforeText = String(text.suffix(options.maxCursorBeforeChars))
            }
        }

        if let selEnd = selEndMarker, let docEnd = docEndMarker {
            var boundedEnd: CFTypeRef = docEnd
            if let pos = cursorPos {
                var mRef: CFTypeRef?
                let targetIdx = NSNumber(value: pos + selectedText.utf16.count + options.maxCursorAfterChars)
                if AXUIElementCopyParameterizedAttributeValue(element, "AXTextMarkerForIndex" as CFString, targetIdx, &mRef) == .success,
                   let mRef {
                    boundedEnd = mRef
                }
            }
            if let range = makeMarkerRange(element: element, markerA: selEnd, markerB: boundedEnd),
               let text = copyStringForParameterized(element, "AXStringForTextMarkerRange" as CFString, param: range) {
                afterText = String(text.prefix(options.maxCursorAfterChars))
            }
        }

        // If markers existed but WebKit/Chromium didn't support AXStartTextMarkerForTextMarkerRange,
        // try AXLineTextMarkerRangeForTextMarker / AXValue fallback.
        if beforeText.isEmpty && afterText.isEmpty {
            if let value = copyString(element, kAXValueAttribute), !value.isEmpty {
                if let pos = cursorPos {
                    let sliced = VoiceContextPolicy.sliceCursorContext(
                        fullText: value,
                        selectionLocationUTF16: pos,
                        selectionLengthUTF16: selectedText.utf16.count,
                        maxBeforeChars: options.maxCursorBeforeChars,
                        maxAfterChars: options.maxCursorAfterChars,
                        maxSelectedChars: options.maxSelectedChars
                    )
                    beforeText = sliced.before
                    afterText = sliced.after
                } else {
                    beforeText = String(value.suffix(options.maxCursorBeforeChars))
                }
            }
        }

        return .init(
            cursorPosition: cursorPos,
            selectionLength: selectedText.utf16.count,
            hasTextSelected: !selectedText.isEmpty,
            selectedText: selectedText,
            textBeforeCursor: beforeText,
            textAfterCursor: afterText
        )
    }

    private static func makeMarkerRange(element: AXUIElement, markerA: CFTypeRef, markerB: CFTypeRef) -> CFTypeRef? {
        let pair: CFArray = [markerA, markerB] as CFArray
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
            pair,
            &rangeRef
        ) == .success else {
            return nil
        }
        return rangeRef
    }

    // MARK: - Surrounding Context (`getFocusedElementRelatedContent`)

    private static func readSurroundingContext(
        focusedElement: AXUIElement,
        maxBeforeChars: Int,
        maxAfterChars: Int,
        deadline: UInt64
    ) -> (VoiceCapturedContext.TextInsertionPoint.SurroundingContext, Bool) {
        var beforePieces: [String] = []
        var afterPieces: [String] = []
        var beforeCount = 0
        var afterCount = 0
        var visited = 0
        let maxVisited = 140
        var timedOut = false

        // Walk up a few ancestors and inspect sibling subtrees immediately before and after the focused branch.
        var current = focusedElement
        for _ in 0..<6 {
            if isPast(deadline) {
                timedOut = true
                break
            }
            guard let parent = copyElement(current, kAXParentAttribute) else { break }
            let parentRole = copyString(parent, kAXRoleAttribute) ?? ""
            if parentRole == (kAXApplicationRole as String) { break }

            let siblings = copyElementArray(parent, kAXChildrenAttribute)
            if let idx = siblings.firstIndex(where: { CFEqual($0, current) }) {
                // Collect siblings before current (nearest first, then reverse for reading order).
                if beforeCount < maxBeforeChars && idx > 0 {
                    var localBefore: [String] = []
                    for sIdx in stride(from: idx - 1, through: max(0, idx - 6), by: -1) {
                        if isPast(deadline) { timedOut = true; break }
                        if visited >= maxVisited || beforeCount >= maxBeforeChars { break }
                        let snippet = collectSnippet(
                            from: siblings[sIdx],
                            budget: maxBeforeChars - beforeCount,
                            visited: &visited,
                            maxVisited: maxVisited,
                            deadline: deadline,
                            timedOut: &timedOut
                        )
                        if !snippet.isEmpty {
                            localBefore.append(snippet)
                            beforeCount += snippet.count + 1
                        }
                    }
                    if !localBefore.isEmpty {
                        beforePieces.insert(contentsOf: localBefore.reversed(), at: 0)
                    }
                }

                // Collect siblings after current.
                if afterCount < maxAfterChars && idx + 1 < siblings.count {
                    for sIdx in (idx + 1)..<min(siblings.count, idx + 7) {
                        if isPast(deadline) { timedOut = true; break }
                        if visited >= maxVisited || afterCount >= maxAfterChars { break }
                        let snippet = collectSnippet(
                            from: siblings[sIdx],
                            budget: maxAfterChars - afterCount,
                            visited: &visited,
                            maxVisited: maxVisited,
                            deadline: deadline,
                            timedOut: &timedOut
                        )
                        if !snippet.isEmpty {
                            afterPieces.append(snippet)
                            afterCount += snippet.count + 1
                        }
                    }
                }
            }

            if beforeCount >= maxBeforeChars && afterCount >= maxAfterChars { break }
            if parentRole == (kAXWindowRole as String) { break }
            current = parent
        }

        let beforeJoined = String(deduplicatedLines(beforePieces).joined(separator: "\n").suffix(maxBeforeChars))
        let afterJoined = String(deduplicatedLines(afterPieces).joined(separator: "\n").prefix(maxAfterChars))
        return (.init(textBeforeInputArea: beforeJoined, textAfterInputArea: afterJoined), timedOut)
    }

    // MARK: - Visible Screen Content (`getFocusedVisibleText`)

    private static let skippedSubtreeRoles: Set<String> = [
        kAXMenuBarRole as String,
        kAXMenuRole as String,
        kAXMenuItemRole as String,
        kAXScrollBarRole as String,
        "AXMenuBarItem",
        "AXBusyIndicator",
        "AXProgressIndicator",
        "AXImage",
    ]

    private static let textLeafRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
        "AXHeading",
        "AXLink",
        "AXSearchField",
    ]

    private static func readVisibleScreenText(
        window: AXUIElement,
        maxChars: Int,
        deadline: UInt64
    ) -> (String, Bool) {
        let windowFrame = copyFrame(window)
        var lines: [String] = []
        var totalChars = 0
        var visited = 0
        let maxVisited = 650
        var timedOut = false

        func walk(_ node: AXUIElement, depth: Int) {
            if totalChars >= maxChars || visited >= maxVisited { return }
            if isPast(deadline) {
                timedOut = true
                return
            }
            visited += 1

            let role = copyString(node, kAXRoleAttribute) ?? ""
            if skippedSubtreeRoles.contains(role) { return }
            if copyString(node, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return }

            // Prune off-screen subtrees when both window frame and node frame are available.
            if let winRect = windowFrame, depth > 1, let nodeRect = copyFrame(node) {
                if nodeRect.width <= 0 || nodeRect.height <= 0 { return }
                if !winRect.intersects(nodeRect) { return }
            }

            if textLeafRoles.contains(role) {
                if let text = readVisibleTextOfLeaf(node, role: role, remaining: maxChars - totalChars),
                   !text.isEmpty {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        lines.append(trimmed)
                        totalChars += trimmed.count + 1
                    }
                }
                // StaticText / TextField / TextArea leaves don't need child recursion unless empty WebArea containers.
                if role == (kAXStaticTextRole as String) || role == (kAXTextFieldRole as String) {
                    return
                }
            }

            guard depth < 24 else { return }
            let children = copyElementArray(node, kAXVisibleChildrenAttribute)
            let toVisit = children.isEmpty ? copyElementArray(node, kAXChildrenAttribute) : children
            for child in toVisit {
                if totalChars >= maxChars || visited >= maxVisited { break }
                if isPast(deadline) {
                    timedOut = true
                    break
                }
                walk(child, depth: depth + 1)
            }
        }

        walk(window, depth: 0)
        let joined = deduplicatedLines(lines).joined(separator: "\n")
        if joined.count > maxChars {
            return (String(joined.prefix(maxChars)), timedOut)
        }
        return (joined, timedOut)
    }

    private static func readVisibleTextOfLeaf(_ node: AXUIElement, role: String, remaining: Int) -> String? {
        guard remaining > 0 else { return nil }
        // For large text areas, prefer `kAXVisibleCharacterRangeAttribute` so we only capture visible lines.
        if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
            if let visRange = copyCFRange(node, kAXVisibleCharacterRangeAttribute), visRange.length > 0 {
                let capped = CFRange(location: visRange.location, length: min(visRange.length, remaining))
                if let slice = copyStringForRange(node, capped), !slice.isEmpty {
                    return String(slice.prefix(remaining))
                }
            }
        }
        if let val = copyString(node, kAXValueAttribute), !val.isEmpty {
            return String(val.prefix(remaining))
        }
        if role == "AXHeading" || role == "AXLink" {
            if let title = copyString(node, kAXTitleAttribute), !title.isEmpty {
                return String(title.prefix(remaining))
            }
            if let desc = copyString(node, kAXDescriptionAttribute), !desc.isEmpty {
                return String(desc.prefix(remaining))
            }
        }
        return nil
    }

    private static func collectSnippet(
        from root: AXUIElement,
        budget: Int,
        visited: inout Int,
        maxVisited: Int,
        deadline: UInt64,
        timedOut: inout Bool
    ) -> String {
        var pieces: [String] = []
        var count = 0

        func walk(_ node: AXUIElement, depth: Int) {
            if count >= budget || visited >= maxVisited { return }
            if isPast(deadline) { timedOut = true; return }
            visited += 1

            let role = copyString(node, kAXRoleAttribute) ?? ""
            if skippedSubtreeRoles.contains(role) { return }
            if copyString(node, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return }

            if textLeafRoles.contains(role) {
                if let text = readVisibleTextOfLeaf(node, role: role, remaining: budget - count)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    pieces.append(text)
                    count += text.count + 1
                }
                if role == (kAXStaticTextRole as String) || role == (kAXTextFieldRole as String) {
                    return
                }
            }

            guard depth < 8 else { return }
            let children = copyElementArray(node, kAXChildrenAttribute)
            for child in children.prefix(24) {
                if count >= budget || visited >= maxVisited { break }
                if isPast(deadline) { timedOut = true; break }
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)
        return deduplicatedLines(pieces).joined(separator: " ")
    }

    private static func collectInlineText(from root: AXUIElement, maxChars: Int, maxNodes: Int) -> String {
        var pieces: [String] = []
        var count = 0
        var visited = 0

        func walk(_ node: AXUIElement, depth: Int) {
            if count >= maxChars || visited >= maxNodes { return }
            visited += 1
            let role = copyString(node, kAXRoleAttribute) ?? ""
            if copyString(node, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return }
            if role == (kAXStaticTextRole as String),
               let val = copyString(node, kAXValueAttribute), !val.isEmpty {
                pieces.append(val)
                count += val.count
                return
            }
            guard depth < 6 else { return }
            for child in copyElementArray(node, kAXChildrenAttribute).prefix(24) {
                walk(child, depth: depth + 1)
                if count >= maxChars || visited >= maxNodes { break }
            }
        }

        walk(root, depth: 0)
        return pieces.joined()
    }

    private static func deduplicatedLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var prev: String? = nil
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed == prev { continue }
            result.append(trimmed)
            prev = trimmed
        }
        return result
    }

    // MARK: - Low-Level AX Attribute Helpers

    private final class UncheckedAXBox: @unchecked Sendable {
        let element: AXUIElement
        init(element: AXUIElement) { self.element = element }
    }

    private static func deadlineAfter(ms: Int) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ UInt64(max(1, ms)) &* 1_000_000
    }

    private static func isPast(_ deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    private static func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let arr = ref as? [AnyObject] else {
            return []
        }
        let targetID = AXUIElementGetTypeID()
        return arr.compactMap { item in
            CFGetTypeID(item) == targetID ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private static func copyURLString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success, let ref else {
            return nil
        }
        if let url = ref as? URL {
            return url.absoluteString
        }
        if let str = ref as? String, !str.isEmpty {
            return str
        }
        return nil
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success, let ref else {
            return nil
        }
        if CFGetTypeID(ref) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeDowncast(ref, to: CFBoolean.self))
        }
        if let num = ref as? NSNumber {
            return num.boolValue
        }
        return nil
    }

    private static func copyInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let num = ref as? NSNumber else {
            return nil
        }
        return num.intValue
    }

    private static func copyCFRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        let axVal = unsafeDowncast(ref, to: AXValue.self)
        guard AXValueGetType(axVal) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
        return range
    }

    private static func copyFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        let posVal = unsafeDowncast(posRef, to: AXValue.self)
        let sizeVal = unsafeDowncast(sizeRef, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &point),
              AXValueGetValue(sizeVal, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private static func copyStringForRange(_ element: AXUIElement, _ range: CFRange) -> String? {
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else { return nil }
        return copyStringForParameterized(element, kAXStringForRangeParameterizedAttribute as CFString, param: axRange)
    }

    private static func copyStringForParameterized(
        _ element: AXUIElement,
        _ attribute: CFString,
        param: CFTypeRef
    ) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, param, &ref) == .success else {
            return nil
        }
        return ref as? String
    }
}

// MARK: - Live Inspector Store (for Juxu Preferences Preview & Debugging)

@MainActor
public final class VoiceContextInspectorStore: ObservableObject {
    public static let shared = VoiceContextInspectorStore()

    @Published public private(set) var lastCaptured: VoiceCapturedContext?
    @Published public private(set) var lastJSON: String = ""
    @Published public private(set) var countdownSeconds: Int = 0
    @Published public private(set) var isCapturing: Bool = false
    @Published public var respectBlacklist: Bool = true

    private var scheduledTask: Task<Void, Never>?

    private init() {}

    public func record(_ captured: VoiceCapturedContext) {
        self.lastCaptured = captured
        self.lastJSON = captured.prettyJSON()
    }

    public func captureAfterDelay(seconds: Int = 3) {
        scheduledTask?.cancel()
        let respect = respectBlacklist
        scheduledTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCapturing = true
            defer {
                self.countdownSeconds = 0
                self.isCapturing = false
            }
            for remaining in stride(from: max(0, seconds), through: 1, by: -1) {
                self.countdownSeconds = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            self.countdownSeconds = 0
            let opts = VoiceContextCaptureOptions(respectBlacklist: respect)
            let captured = await VoiceContextCapture.captureAsync(options: opts)
            if Task.isCancelled { return }
            self.record(captured)
            NSSound.beep()
        }
    }

    public func cancelScheduledCapture() {
        scheduledTask?.cancel()
        scheduledTask = nil
        countdownSeconds = 0
        isCapturing = false
    }
}
