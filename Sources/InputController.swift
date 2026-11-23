import AppKit
import Carbon
import InputMethodKit

@objc(JuxuInputController)
@MainActor
public final class JuxuInputController: IMKInputController {
    private weak var activeClient: (any IMKTextInput & NSObjectProtocol)?
    private var shiftTapDetector = ShiftTapDetector()
    private var autoSpaceTracker = AutoSpaceContextTracker()
    private var lastExpectedAnchor: Int? = nil
    private var sawClientSupportForRanges: Bool = false
    private var saveUserDataTimer: Timer?
    private var autoPairClosers: [String] = []
    private var autoPairTail: String = ""

    public override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        self.activeClient = inputClient as? (any IMKTextInput & NSObjectProtocol)
        configurePanelCallbacks()
    }

    private func configurePanelCallbacks() {
        CandidatePanelController.shared.onSelect = { [weak self] relIdx in
            guard let self else { return }
            let out = JuxuBridge.shared.selectCandidate(
                pageRelIndex: relIdx,
                timestampMs: Self.nowMs()
            )
            self.applyEngineOutput(out, client: self.activeClient)
        }
        CandidatePanelController.shared.onPage = { [weak self] delta in
            guard let self else { return }
            let out = JuxuBridge.shared.turnPage(delta: delta)
            self.applyEngineOutput(out, client: self.activeClient)
        }
    }

    public override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(mask.rawValue)
    }

    public override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        self.activeClient = sender as? (any IMKTextInput & NSObjectProtocol)
        shiftTapDetector.reset()
        autoSpaceTracker.invalidate()
        lastExpectedAnchor = nil
        sawClientSupportForRanges = false
        autoPairClosers.removeAll()
        configurePanelCallbacks()
        VoiceGlobalCommitter.setInputMethodSink(owner: self) { [weak self] text in
            guard let self, self.activeClient != nil else { return false }
            self.commitVoiceText(text, replaceSelection: false, client: self.activeClient)
            return true
        }
    }

    public override func deactivateServer(_ sender: Any!) {
        VoiceGlobalCommitter.clearInputMethodSink(owner: self)
        VoiceSessionController.sharedIfLoaded?.handleDeactivate()
        saveUserDataTimer?.invalidate()
        saveUserDataTimer = nil
        commitPendingAndHide(sender)
        JuxuBridge.shared.flushUserDataAsync()
        JuxuBridge.shared.flushPendingPersistence()
        shiftTapDetector.reset()
        autoSpaceTracker.invalidate()
        lastExpectedAnchor = nil
        sawClientSupportForRanges = false
        autoPairClosers.removeAll()
        super.deactivateServer(sender)
    }

    public override func commitComposition(_ sender: Any!) {
        saveUserDataTimer?.invalidate()
        saveUserDataTimer = nil
        commitPendingAndHide(sender)
        JuxuBridge.shared.flushUserDataAsync()
    }

    private func commitPendingAndHide(_ sender: Any!) {
        let clientObj = (sender as? (any IMKTextInput & NSObjectProtocol)) ?? activeClient
        let pre = JuxuBridge.shared.state.preedit
        if !pre.isEmpty {
            let rawText = JuxuBridge.shared.state.candidates.first?.text ?? pre
            let formatted = formatTextForCommit(rawText, splitInternal: true, client: clientObj)
            clientObj?.insertText(formatted, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            advanceExpectedAnchor(by: formatted.utf16.count)
            JuxuBridge.shared.clearComposition()
        }
        CandidatePanelController.shared.hide()
        ModeIndicatorPanelController.shared.hide()
    }

    public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let clientObj = (sender as? (any IMKTextInput & NSObjectProtocol)) ?? activeClient
        self.activeClient = clientObj
        JuxuBridge.shared.suppressEvalLogging = IsSecureEventInputEnabled()

        // Strictly on-demand voice entry: when disabled, zero voice controllers or panels are loaded.
        if VoiceGlobalHotkeyController.isListening {
            // The global listener already saw this key; only keep typing out of a recording.
            if event.type == .keyDown, VoiceSessionController.sharedIfLoaded?.isRecording == true {
                return true
            }
        } else if VoicePreferencesStore.shared.prefs.enabled {
            let consumedByVoice = VoiceSessionController.shared.handleEvent(
                event,
                caretRectProvider: { [weak self, weak clientObj] in
                    guard let self else {
                        let mouse = NSEvent.mouseLocation
                        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 20)
                    }
                    return self.queryCaretRect(client: clientObj)
                },
                windowLevel: clientObj?.windowLevel(),
                contextProvider: { [weak self, weak clientObj] in
                    self?.buildVoiceContext(client: clientObj) ?? VoiceContext()
                },
                onCommit: { [weak self, weak clientObj] text, replaceSelection in
                    self?.commitVoiceText(text, replaceSelection: replaceSelection, client: clientObj)
                }
            )
            if consumedByVoice {
                shiftTapDetector.cancelPendingTap()
                return true
            }
        }

        // Bare Shift tap detection for seamless Chinese / English toggle
        if event.type == .flagsChanged {
            let now = ProcessInfo.processInfo.systemUptime
            let eventTs = (event.timestamp > 0 && abs(now - event.timestamp) < 5.0) ? event.timestamp : now
            let triggered = shiftTapDetector.handleFlagsChanged(
                keyCode: event.keyCode,
                modifiers: Self.shiftTapModifiers(from: event.modifierFlags),
                timestamp: eventTs,
                hadInterveningHIDEvent: Self.hasInterveningHIDInput(since:)
            )
            if triggered {
                let out = JuxuBridge.shared.toggleAsciiMode()
                applyEngineOutput(out, client: clientObj)
                if out.preedit.isEmpty {
                    let caret = queryCaretRect(client: clientObj)
                    ModeIndicatorPanelController.shared.show(
                        asciiMode: out.asciiMode,
                        caretRect: caret,
                        clientWindowLevel: clientObj?.windowLevel()
                    )
                }
                return true
            }
            return false
        }

        guard event.type == .keyDown else { return false }
        shiftTapDetector.handleKeyDown()

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmdOrOption = mods.contains(.command) || mods.contains(.option)
        if hasCmdOrOption {
            autoSpaceTracker.invalidate()
            lastExpectedAnchor = nil
            autoPairClosers.removeAll()
            return false
        }
        let hasCtrl = mods.contains(.control)
        let scalar: UInt32 = event.characters?.unicodeScalars.first?.value ?? 0

        let out = JuxuBridge.shared.handleKey(
            keyCode: event.keyCode,
            scalar: scalar,
            hasCmdOrCtrl: hasCtrl,
            timestampMs: Self.nowMs()
        )

        if !out.consumed {
            return handlePassthroughAutoSpace(event: event, hasCtrl: hasCtrl, client: clientObj)
        }

        applyEngineOutput(out, client: clientObj)
        return true
    }

    private func applyEngineOutput(
        _ out: JuxuActionState,
        client: (any IMKTextInput & NSObjectProtocol)?
    ) {
        if out.bell {
            NSSound.beep()
        }

        if !out.commitText.isEmpty {
            if !commitWithOptionalPairing(out, client: client) {
                let formatted = formatTextForCommit(out.commitText, splitInternal: true, client: client)
                client?.insertText(
                    formatted,
                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
                )
                advanceExpectedAnchor(by: formatted.utf16.count)
            }
            scheduleUserDataFlush()
        }

        let markedText = out.macOSPreedit
        if markedText.isEmpty {
            if out.commitText.isEmpty {
                client?.setMarkedText(
                    "",
                    selectionRange: NSRange(location: 0, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
                )
            }
            CandidatePanelController.shared.hide()
        } else {
            let attr = NSAttributedString(
                string: markedText,
                attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
            client?.setMarkedText(
                attr,
                selectionRange: NSRange(location: markedText.utf16.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
            )
            let caret = queryCaretRect(client: client)
            ModeIndicatorPanelController.shared.hide()
            CandidatePanelController.shared.update(
                state: out,
                caretRect: caret,
                clientWindowLevel: client?.windowLevel()
            )
        }
    }

    private func queryCaretRect(client: (any IMKTextInput & NSObjectProtocol)?) -> NSRect {
        var lineRect = NSRect.zero
        if let client {
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
            if lineRect.origin == .zero {
                let marked = client.markedRange()
                if marked.location != NSNotFound {
                    let rect = client.firstRect(forCharacterRange: marked, actualRange: nil)
                    if rect.origin != .zero {
                        lineRect = rect
                    }
                }
            }
            if lineRect.origin == .zero {
                let sel = client.selectedRange()
                if sel.location != NSNotFound {
                    let rect = client.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: nil)
                    if rect.origin != .zero {
                        lineRect = rect
                    }
                }
            }
        }
        if lineRect.origin == .zero {
            let mouse = NSEvent.mouseLocation
            lineRect = NSRect(x: mouse.x, y: mouse.y, width: 1, height: 20)
        }
        return lineRect
    }

    // MARK: - Native macOS Input Method Menu

    public override func menu() -> NSMenu! {
        let m = NSMenu(title: "句序")
        let curSchema = JuxuBridge.shared.prefs.schemaId
        let curCategory = InputSchemaCategory.category(for: curSchema)

        for category in InputSchemaCategory.allCases {
            let catItem = NSMenuItem(title: category.rawValue, action: nil, keyEquivalent: "")
            catItem.state = (curCategory == category) ? .on : .off
            let sub = NSMenu(title: category.rawValue)
            for opt in InputSchemaOption.options(for: category) {
                let item = NSMenuItem(title: opt.title, action: #selector(selectSchemaFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(opt.id)
                item.state = (curSchema == opt.id) ? .on : .off
                sub.addItem(item)
            }
            catItem.submenu = sub
            m.addItem(catItem)
        }

        m.addItem(.separator())

        let typoItem = NSMenuItem(
            title: "误触与热区置信度纠正",
            action: #selector(toggleTypoCorrection(_:)),
            keyEquivalent: ""
        )
        typoItem.target = self
        typoItem.state = JuxuBridge.shared.prefs.typoEnabled ? .on : .off
        m.addItem(typoItem)

        let orientItem = NSMenuItem(
            title: JuxuBridge.shared.prefs.vertical ? "切换为横排候选栏" : "切换为竖排候选栏",
            action: #selector(toggleOrientation(_:)),
            keyEquivalent: ""
        )
        orientItem.target = self
        m.addItem(orientItem)

        let autoSpaceItem = NSMenuItem(
            title: "中英文之间自动加空格",
            action: #selector(toggleAutoSpace(_:)),
            keyEquivalent: ""
        )
        autoSpaceItem.target = self
        autoSpaceItem.state = JuxuBridge.shared.prefs.autoSpaceZhEn ? .on : .off
        m.addItem(autoSpaceItem)

        // Only expose voice quick controls in menu after voice entry is enabled
        if VoicePreferencesStore.shared.prefs.enabled {
            m.addItem(.separator())
            let voicePrefs = VoicePreferencesStore.shared.prefs
            let providerTitle = "语音方案：\(voicePrefs.providerMode.displayName)（点击切换）"
            let providerItem = NSMenuItem(
                title: providerTitle,
                action: #selector(toggleVoiceProviderMode(_:)),
                keyEquivalent: ""
            )
            providerItem.target = self
            m.addItem(providerItem)

            let polishItem = NSMenuItem(
                title: "语音智能整理",
                action: #selector(toggleVoiceSmartPolish(_:)),
                keyEquivalent: ""
            )
            polishItem.target = self
            polishItem.state = (voicePrefs.outputMode == .smartPolish) ? .on : .off
            m.addItem(polishItem)
        }

        m.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "句序偏好设置…",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ""
        )
        m.addItem(prefsItem)

        return m
    }

    @objc private func selectSchemaFromMenu(_ sender: NSMenuItem) {
        JuxuBridge.shared.switchSchema(UInt32(sender.tag))
    }

    @objc private func toggleTypoCorrection(_ sender: Any?) {
        var p = JuxuBridge.shared.prefs
        p.typoEnabled.toggle()
        JuxuBridge.shared.applyAndSavePreferences(p)
    }

    @objc private func toggleOrientation(_ sender: Any?) {
        var p = JuxuBridge.shared.prefs
        p.vertical.toggle()
        JuxuBridge.shared.applyAndSavePreferences(p)
    }

    @objc private func toggleAutoSpace(_ sender: Any?) {
        var p = JuxuBridge.shared.prefs
        p.autoSpaceZhEn.toggle()
        JuxuBridge.shared.applyAndSavePreferences(p)
    }

    @objc private func toggleVoiceProviderMode(_ sender: Any?) {
        VoicePreferencesStore.shared.update { prefs in
            prefs.providerMode = (prefs.providerMode == .cloudBYOK) ? .local : .cloudBYOK
        }
    }

    @objc private func toggleVoiceSmartPolish(_ sender: Any?) {
        VoicePreferencesStore.shared.update { prefs in
            prefs.outputMode = (prefs.outputMode == .smartPolish) ? .rawDictation : .smartPolish
        }
    }

    private func buildVoiceContext(client: (any IMKTextInput & NSObjectProtocol)?) -> VoiceContext {
        let voicePrefs = VoicePreferencesStore.shared.prefs
        var selectedText: String? = nil
        if voicePrefs.speakToEditSelection, let client {
            let sel = client.selectedRange()
            if sel.location != NSNotFound && sel.length > 0 && sel.length <= 4000 {
                selectedText = client.attributedSubstring(from: sel)?.string
            }
        }
        let beforeContext = readHostContextBefore(client: client)
        var vocab = voicePrefs.parsedCustomVocabulary
        if voicePrefs.syncJuxuLexicon {
            vocab.append(contentsOf: JuxuBridge.shared.userPhrases.prefix(40).map(\.text))
        }
        return VoiceContext(
            bundleIdentifier: client?.bundleIdentifier(),
            selectedText: selectedText,
            beforeContext: beforeContext,
            personalVocabulary: vocab
        )
    }

    private func commitVoiceText(
        _ text: String,
        replaceSelection: Bool,
        client: (any IMKTextInput & NSObjectProtocol)?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let targetClient = client ?? activeClient
        if replaceSelection, let targetClient {
            let sel = targetClient.selectedRange()
            if sel.location != NSNotFound && sel.length > 0 {
                targetClient.insertText(trimmed, replacementRange: sel)
                autoSpaceTracker.invalidate()
                lastExpectedAnchor = nil
                return
            }
        }
        let formatted = formatTextForCommit(trimmed, splitInternal: false, client: targetClient)
        targetClient?.insertText(
            formatted,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        advanceExpectedAnchor(by: formatted.utf16.count)
    }

    public override func showPreferences(_ sender: Any!) {
        SettingsWindowController.shared.show()
    }

    private func handlePassthroughAutoSpace(
        event: NSEvent,
        hasCtrl: Bool,
        client: (any IMKTextInput & NSObjectProtocol)?
    ) -> Bool {
        if hasCtrl {
            autoSpaceTracker.invalidate()
            lastExpectedAnchor = nil
            autoPairClosers.removeAll()
            return false
        }

        switch event.keyCode {
        case 0x33: // Backspace
            let hostBefore = readHostContextBefore(client: client)
            if JuxuBridge.shared.prefs.smartPunctuation,
               !JuxuBridge.shared.state.asciiMode,
               !autoPairClosers.isEmpty,
               CGPreflightPostEventAccess()
            {
                let hostAfter = readHostContextAfter(client: client)
                refreshAutoPairs(after: hostAfter)
                if PunctuationPairing.shouldDeletePair(before: hostBefore, after: hostAfter, openClosers: autoPairClosers) {
                    Self.postVirtualKey(0x75) // ForwardDelete removes closer on the right
                    autoPairClosers.removeLast()
                    autoSpaceTracker.invalidate()
                }
            }
            let eff = autoSpaceTracker.effectiveBefore(hostBefore: hostBefore, hostBeforeIsAuthoritative: true)
            let delUtf16 = eff.last?.utf16.count ?? 1
            autoSpaceTracker.willDeleteBackward(hostBefore: hostBefore, hostBeforeIsAuthoritative: true)
            if let anchor = lastExpectedAnchor {
                lastExpectedAnchor = max(0, anchor - delUtf16)
            }
            return false

        case 0x24, 0x4C: // Return / KP Enter
            let hostBefore = readHostContextBefore(client: client)
            autoSpaceTracker.recordPassthrough("\n", hostBefore: hostBefore, hostBeforeIsAuthoritative: true)
            advanceExpectedAnchor(by: 1)
            return false

        case 0x30: // Tab
            let hostBefore = readHostContextBefore(client: client)
            autoSpaceTracker.recordPassthrough("\t", hostBefore: hostBefore, hostBeforeIsAuthoritative: true)
            advanceExpectedAnchor(by: 1)
            return false

        case 0x31: // Space
            let hostBefore = readHostContextBefore(client: client)
            autoSpaceTracker.recordPassthrough(" ", hostBefore: hostBefore, hostBeforeIsAuthoritative: true)
            advanceExpectedAnchor(by: 1)
            return false

        case 0x35, 0x73, 0x74, 0x75, 0x77, 0x79, 0x7B, 0x7C, 0x7D, 0x7E:
            // Esc, Home, PgUp, ForwardDel, End, PgDn, Left, Right, Down, Up
            autoSpaceTracker.invalidate()
            lastExpectedAnchor = nil
            autoPairClosers.removeAll()
            return false

        default:
            break
        }

        guard let chars = event.characters, !chars.isEmpty,
              let firstScalar = chars.unicodeScalars.first else {
            return false
        }
        if firstScalar.value < 0x20
            || (firstScalar.value >= 0xF700 && firstScalar.value <= 0xF8FF)
            || firstScalar.value == 0x7F
        {
            autoSpaceTracker.invalidate()
            lastExpectedAnchor = nil
            return false
        }

        let hostBefore = readHostContextBefore(client: client)
        let options = AutoSpaceOptions(prefs: JuxuBridge.shared.prefs)
        if !IsSecureEventInputEnabled(),
           AutoSpaceFormatter.isAutoSpaceRightTrigger(chars, options: options)
        {
            let formatted = autoSpaceTracker.prepareCommit(
                chars,
                hostBefore: hostBefore,
                hostBeforeIsAuthoritative: true,
                splitInternal: false,
                options: options
            )
            if formatted != chars {
                client?.insertText(
                    formatted,
                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
                )
                advanceExpectedAnchor(by: formatted.utf16.count)
                return true
            }
            advanceExpectedAnchor(by: chars.utf16.count)
            return false
        }

        autoSpaceTracker.recordPassthrough(chars, hostBefore: hostBefore, hostBeforeIsAuthoritative: true)
        advanceExpectedAnchor(by: chars.utf16.count)
        return false
    }

    private func formatTextForCommit(
        _ text: String,
        splitInternal: Bool,
        client: (any IMKTextInput & NSObjectProtocol)?
    ) -> String {
        guard !IsSecureEventInputEnabled() else { return text }
        let hostBefore = readHostContextBefore(client: client)
        let options = AutoSpaceOptions(prefs: JuxuBridge.shared.prefs)
        return autoSpaceTracker.prepareCommit(
            text,
            hostBefore: hostBefore,
            hostBeforeIsAuthoritative: true,
            splitInternal: splitInternal,
            options: options
        )
    }

    private func readHostContextBefore(client: (any IMKTextInput & NSObjectProtocol)?) -> String? {
        guard let client else { return nil }
        let marked = client.markedRange()
        let sel = client.selectedRange()
        let anchor = (marked.location != NSNotFound) ? marked.location : sel.location
        guard anchor != NSNotFound else {
            lastExpectedAnchor = nil
            return nil
        }

        let docLen = client.length()
        let safeAnchor = (docLen != NSNotFound && docLen >= 0) ? min(anchor, docLen) : anchor

        // Guard against clients that stub `selectedRange()` and `length()` to always return 0.
        if safeAnchor == 0 && (docLen == NSNotFound || docLen == 0) && !sawClientSupportForRanges {
            if let expected = lastExpectedAnchor, expected > 0 {
                lastExpectedAnchor = nil
                return nil
            }
            lastExpectedAnchor = 0
            return nil
        }

        if let expected = lastExpectedAnchor, safeAnchor != expected {
            autoSpaceTracker.invalidate()
        }
        lastExpectedAnchor = safeAnchor

        if safeAnchor == 0 {
            if docLen != NSNotFound && docLen > 0 {
                sawClientSupportForRanges = true
            }
            return ""
        }
        let len = min(safeAnchor, 48)
        let start = safeAnchor - len
        guard let sub = client.attributedSubstring(from: NSRange(location: start, length: len))?.string,
              !sub.isEmpty else {
            return nil
        }
        sawClientSupportForRanges = true
        return sub
    }

    private func readHostContextAfter(client: (any IMKTextInput & NSObjectProtocol)?) -> String? {
        guard let client else { return nil }
        let marked = client.markedRange()
        let sel = client.selectedRange()
        let anchor = (marked.location != NSNotFound)
            ? (marked.location + marked.length)
            : ((sel.location != NSNotFound) ? (sel.location + sel.length) : NSNotFound)
        guard anchor != NSNotFound else { return nil }
        let docLen = client.length()
        guard docLen != NSNotFound, docLen >= anchor else { return nil }
        let remaining = docLen - anchor
        if remaining == 0 { return "" }
        let len = min(remaining, 16)
        return client.attributedSubstring(from: NSRange(location: anchor, length: len))?.string
    }

    private func refreshAutoPairs(after: String?) {
        autoPairClosers = PunctuationPairing.pruned(autoPairClosers, after: after)
        if !PunctuationPairing.cursorStaysInPairs(autoPairClosers, tail: autoPairTail, after: after) {
            autoPairClosers.removeAll()
        }
    }

    private func commitWithOptionalPairing(
        _ out: JuxuActionState,
        client: (any IMKTextInput & NSObjectProtocol)?
    ) -> Bool {
        guard JuxuBridge.shared.prefs.smartPunctuation,
              !out.asciiMode,
              out.macOSPreedit.isEmpty,
              CGPreflightPostEventAccess(),
              let lastScalar = out.commitText.last
        else {
            return false
        }
        let sym = String(lastScalar)
        let hasPrefix = out.commitText.count > 1
        let hostAfter = readHostContextAfter(client: client)
        refreshAutoPairs(after: hostAfter)

        switch PunctuationPairing.action(for: sym, after: hostAfter, openClosers: autoPairClosers) {
        case .skipClose where !hasPrefix:
            Self.postVirtualKey(0x7C) // Right Arrow skips over auto-inserted closer
            autoPairClosers.removeLast()
            autoSpaceTracker.invalidate()
            advanceExpectedAnchor(by: sym.utf16.count)
            return true
        case .insertPair(let close):
            if autoPairClosers.isEmpty {
                autoPairTail = hostAfter ?? ""
            }
            let formatted = formatTextForCommit(out.commitText, splitInternal: true, client: client)
            client?.insertText(
                formatted + close,
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
            )
            Self.postVirtualKey(0x7B) // Left Arrow places caret inside the pair
            autoPairClosers.append(close)
            advanceExpectedAnchor(by: formatted.utf16.count)
            autoSpaceTracker.invalidate()
            return true
        default:
            return false
        }
    }

    private static func postVirtualKey(_ keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func advanceExpectedAnchor(by utf16Count: Int) {
        if let anchor = lastExpectedAnchor {
            lastExpectedAnchor = anchor + utf16Count
        }
    }

    private func scheduleUserDataFlush() {
        saveUserDataTimer?.invalidate()
        saveUserDataTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                JuxuBridge.shared.flushUserDataAsync()
            }
        }
    }

    private static func shiftTapModifiers(from flags: NSEvent.ModifierFlags) -> ShiftTapModifiers {
        var result: ShiftTapModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.function) { result.insert(.function) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }

    private static func hasInterveningHIDInput(since downTimestamp: TimeInterval) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsedSinceDown = now - downTimestamp
        guard elapsedSinceDown > 0 else { return false }
        let monitoredTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        for evType in monitoredTypes {
            let sinceLast = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: evType)
            if sinceLast <= elapsedSinceDown {
                return true
            }
        }
        return false
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000.0)
    }
}
