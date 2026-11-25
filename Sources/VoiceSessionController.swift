import AppKit
import AVFoundation
import Foundation
import InputMethodKit
import Speech

/// Strictly lazy macOS voice dictation & AI polish coordinator.
/// When `VoicePreferencesStore.shared.prefs.enabled == false`, `_shared` remains `nil`
/// and zero audio, speech, networking, or HUD resources are allocated.
@MainActor
public final class VoiceSessionController {
    private static var _shared: VoiceSessionController?

    public static var isLoaded: Bool { _shared != nil }

    public static var sharedIfLoaded: VoiceSessionController? { _shared }

    public static var shared: VoiceSessionController {
        if let existing = _shared {
            return existing
        }
        let created = VoiceSessionController()
        _shared = created
        return created
    }

    public static func unload() {
        _shared?.teardown()
        _shared = nil
        VoiceHUDPanelController.unload()
        VoiceASRRegistry.unloadAll()
        VoiceGlobalHotkeyController.unload()
    }

    private enum Phase {
        case idle
        case recording
        case processing
    }

    private var phase: Phase = .idle
    /// The model is only woken once the key has clearly been held, so taps and shortcuts stay free.
    private static let engineWarmDelay: TimeInterval = 0.3
    /// A press shorter than this with no speech in it is a tap: it ends silently.
    private static let tapWindow: TimeInterval = 0.6
    /// Keep capturing briefly after key-up so CoreAudio's ~100 ms tap buffer and trailing syllables arrive.
    private static let releaseTailDelay: TimeInterval = 0.18
    /// After the release tail, how much longer the final pass waits for a context capture still running.
    static let contextCaptureGrace: TimeInterval = 0.25
    private var engineWarmItem: DispatchWorkItem?
    private var engineWarmed = false
    private var warmHold: (any VoiceASREngine)?
    private var pressTime: Date?
    /// A quick tap waits this long for a second press before it counts as a plain tap.
    var doubleTapWindow: TimeInterval = 0.3
    private static let secondPressHoldLimit: TimeInterval = 0.3
    private static let holdCueDelay: TimeInterval = 0.3
    /// Below this display level nobody is talking yet, so a cue cannot land on speech.
    private static let cueQuietLevel: Float = 0.08
    private var tapTimeoutItem: DispatchWorkItem?
    private var secondPressTime: Date?
    private var handsFree = false
    private var holdCueItem: DispatchWorkItem?
    private var startCueDue = false
    private var cueSounded = false
    /// Test seam: replaces playing a cue.
    var cueOverride: ((VoiceCueKind) -> Void)?
    /// The key went down again while a cancelled microphone start was still unwinding.
    private var pendingRestart: (() -> Void)?
    private var levelTimer: Timer?
    private var recordingStartTime: Date?
    private var latestLevel: Float = 0
    private var peakLevelSinceDraw: Float?
    private var latestPartial: String = ""
    private var latestTentativeCount = 0
    private var timeline = VoiceSessionTimeline()
    /// The microphone is starting off the main thread; a release or Esc can arrive meanwhile.
    private var isStarting = false
    private var startAborted = false
    private var activeRecorder: VoiceAudioRecorder?
    private var activeStream: VoiceWhisperStreamSession?
    private var sessionGeneration: UInt64 = 0
    private var pipelineClient: VoicePipelineClient?
    private var activeTask: Task<Void, Never>?
    private var activeContextCaptureTask: Task<Void, Never>?
    private var contextCaptureDone = true
    /// The local engine of this dictation, told when the AX capture lands. Internal for tests.
    var activeEngine: (any VoiceASREngine)?
    private var activeCaretRect: NSRect = .zero
    private var activeWindowLevel: CGWindowLevel?
    private var activeCommitHandler: ((String, Bool) -> Void)?
    /// Internal for tests.
    var activeContext: VoiceContext = VoiceContext()

    private init() {}

    public var isActive: Bool {
        phase != .idle
    }

    public var isRecording: Bool { phase == .recording }

    /// The voice key is down and audio is being captured, or the microphone is coming up for it.
    public var isCapturing: Bool { phase == .recording || (isStarting && !startAborted) }

    /// Test seam: replaces starting the microphone.
    var startRecordingOverride: (() -> Void)?
    /// Test seam: called instead of transcribing when the key is released.
    var finishRecordingOverride: (() -> Void)?

    /// Another key joined the voice key, so this was a shortcut: drop everything without a notice.
    public func cancelForChord() {
        // Typing during a hands-free dictation is not a shortcut on the voice key.
        if handsFree { return }
        pendingRestart = nil
        if isCapturing { cancelCurrentSession(showNotice: false) }
    }

    /// The global listener stopped, so the key that would end a hands-free dictation is gone.
    public func cancelForLostListener() {
        handsFree = false
        cancelForChord()
    }

    /// Test seam: the double-tap window has passed.
    func fireTapTimeoutForTesting() {
        tapTimeoutItem?.perform()
    }

    public var isHandsFree: Bool { handsFree }

    public func showExternalNotice(_ message: String) {
        showNotice(message, isError: false, duration: 3.2)
    }

    /// Handles modifier/key events from `JuxuInputController` ONLY when voice is enabled.
    /// Returns `true` if the event was consumed by voice dictation.
    public func handleEvent(
        _ event: NSEvent,
        caretRectProvider: @escaping () -> NSRect,
        windowLevel: CGWindowLevel?,
        contextProvider: @escaping () -> VoiceContext,
        onCommit: @escaping (_ text: String, _ replaceSelection: Bool) -> Void
    ) -> Bool {
        let prefs = VoicePreferencesStore.shared.prefs
        guard prefs.enabled else {
            Self.unload()
            return false
        }

        if event.type == .keyDown && event.keyCode == 0x35 && (phase != .idle || isCapturing) {
            cancelCurrentSession(showNotice: true)
            return true
        }

        if prefs.triggerKey == .optionSpace {
            if event.type == .keyDown {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 0x31 && mods == .option {
                    if phase == .idle {
                        startRecording(
                            caretRect: caretRectProvider(),
                            windowLevel: windowLevel,
                            context: contextProvider(),
                            warmDelay: 0,
                            onCommit: onCommit
                        )
                    } else if phase == .recording {
                        finishRecordingAndProcess()
                    }
                    return true
                }
                if phase == .recording && (event.keyCode == 0x24 || event.keyCode == 0x4C) {
                    finishRecordingAndProcess()
                    return true
                }
            }
            return false
        }

        guard let targetKeyCode = prefs.triggerKey.modifierKeyCode else { return false }

        if event.type == .keyDown {
            // Never consumed: the shortcut still has to reach the app.
            cancelForChord()
            return false
        }

        guard event.type == .flagsChanged else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let targetFlag: NSEvent.ModifierFlags
        switch prefs.triggerKey {
        case .rightOption: targetFlag = .option
        case .rightCommand: targetFlag = .command
        case .fnKey: targetFlag = .function
        case .optionSpace: return false
        }

        if event.keyCode == targetKeyCode {
            let isDown = flags.contains(targetFlag) && flags.subtracting([targetFlag, .capsLock]).isEmpty
            if isDown {
                if handsFree {
                    if isStarting {
                        cancelCurrentSession(showNotice: false)
                    } else {
                        finishRecordingAndProcess()
                    }
                    return true
                }
                if tapTimeoutItem != nil {
                    tapTimeoutItem?.cancel()
                    tapTimeoutItem = nil
                    secondPressTime = Date()
                    scheduleHoldCue()
                    return false
                }
                if phase == .idle {
                    let begin = { [weak self] in
                        guard let self else { return }
                        self.timeline.begin()
                        self.pressTime = Date()
                        self.scheduleHoldCue()
                        self.startRecording(
                            caretRect: caretRectProvider(),
                            windowLevel: windowLevel,
                            context: contextProvider(),
                            warmDelay: Self.engineWarmDelay,
                            onCommit: onCommit
                        )
                    }
                    if !isStarting {
                        begin()
                    } else if startAborted {
                        pendingRestart = begin
                    }
                }
                return false
            } else {
                pendingRestart = nil
                if handsFree { return false }
                if let second = secondPressTime {
                    secondPressTime = nil
                    if isCapturing, Date().timeIntervalSince(second) < Self.secondPressHoldLimit {
                        handsFree = true
                        pressTime = nil
                        holdCueItem?.cancel()
                        holdCueItem = nil
                        playStartCue()
                        return true
                    }
                    // The second press was held, so it is an ordinary dictation.
                    pressTime = nil
                } else if doubleTapWindow > 0, isCapturing, let pressed = pressTime,
                          Date().timeIntervalSince(pressed) < doubleTapWindow {
                    holdCueItem?.cancel()
                    holdCueItem = nil
                    let item = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.tapTimeoutItem = nil
                        if self.isStarting {
                            if !self.startAborted { self.cancelCurrentSession(showNotice: false) }
                        } else {
                            self.finishRecordingAndProcess()
                        }
                    }
                    tapTimeoutItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: item)
                    return true
                }
                if isStarting {
                    // Released before the microphone came up, so no audio exists to transcribe.
                    if !startAborted { cancelCurrentSession(showNotice: false) }
                    return true
                }
                if phase == .recording {
                    finishRecordingAndProcess()
                    return true
                }
                return false
            }
        } else if !flags.subtracting([targetFlag, .capsLock]).isEmpty {
            cancelForChord()
        }

        return false
    }

    public func handleDeactivate() {
        // With the global key, switching app or input method does not end a dictation.
        if VoiceGlobalHotkeyController.isListening { return }
        pendingRestart = nil
        if phase == .recording || isStarting {
            cancelCurrentSession(showNotice: false)
        }
    }

    /// Runs a quick non-recording connectivity / readiness check for Settings UI.
    public func testCurrentConfiguration() async -> (ok: Bool, message: String) {
        let prefs = VoicePreferencesStore.shared.prefs
        guard prefs.enabled else {
            return (false, "请先开启语音输入总开关")
        }
        switch prefs.providerMode {
        case .cloudBYOK:
            let asrKey = VoiceKeychainStore.read(prefs.effectiveCloudASRKeyAccount)
            if asrKey.isEmpty {
                return (false, "请先填写 \(prefs.cloudPreset.displayName) 的 API Key")
            }
            if prefs.outputMode == .smartPolish && prefs.cloudPolishEnabled {
                let llmKey = VoiceKeychainStore.read(prefs.effectiveCloudLLMKeyAccount)
                if llmKey.isEmpty {
                    return (false, "未配置整理模型 API Key")
                }
                do {
                    let client = ensurePipelineClient()
                    let polished = try await client.polishOpenAICompatible(
                        baseURL: prefs.effectiveCloudLLMBaseURL,
                        apiKey: llmKey,
                        model: prefs.effectiveCloudLLMModel,
                        rawTranscript: "嗯，那个，测试一下语音整理功能，明天，不对，后天下午三点开会。",
                        toneMode: prefs.toneMode,
                        context: VoiceContext(personalVocabulary: prefs.parsedCustomVocabulary)
                    )
                    return (true, "连通正常（\(prefs.cloudPreset.displayName)）：\(polished)")
                } catch {
                    return (false, error.localizedDescription)
                }
            }
            return (true, "云端识别配置就绪（\(prefs.effectiveCloudASRModel)）")

        case .local:
            switch prefs.localASRPreset.backend {
            case .engine:
                let status = VoiceLocalInstaller.asrStatus(for: prefs.localASRPreset)
                if !status.isReady {
                    return (false, "尚未安装 \(prefs.localASRPreset.displayName)，请点击上方「一键下载并安装」")
                }
            case .appleSpeech:
                let locale = Locale(identifier: prefs.localAppleLocale.isEmpty ? "zh-CN" : prefs.localAppleLocale)
                guard let rec = SFSpeechRecognizer(locale: locale) else {
                    return (false, "系统不支持语言 \(locale.identifier)")
                }
                if prefs.localAppleRequireOnDevice && !rec.supportsOnDeviceRecognition {
                    return (false, "未检测到 \(locale.identifier) 离线语音模型，请在系统设置 → 键盘 → 听写中下载，或取消勾选「纯离线」")
                }
            case .customHTTP:
                if URL(string: prefs.localHTTPASRBaseURL) == nil {
                    return (false, "本地 HTTP ASR 地址无效")
                }
            }

            if prefs.outputMode == .smartPolish {
                switch prefs.localLLMPreset {
                case .qwen15B:
                    let llmStatus = VoiceLocalInstaller.llmStatus(for: .qwen15B)
                    if !llmStatus.isReady {
                        return (false, "识别引擎已就绪，但本地整理模型尚未下载（请点击上方「一键下载并安装」）")
                    }
                    return (true, "本地识别与 Qwen2.5-1.5B AI 整理均已就绪")
                case .ollamaHTTP:
                    do {
                        let client = ensurePipelineClient()
                        let polished = try await client.polishOpenAICompatible(
                            baseURL: prefs.localHTTPLLMBaseURL,
                            apiKey: nil,
                            model: prefs.localHTTPLLMModel,
                            rawTranscript: "嗯，那个，测试一下本地整理功能。",
                            toneMode: prefs.toneMode,
                            context: VoiceContext()
                        )
                        return (true, "本地模型就绪，LLM 整理正常：\(polished)")
                    } catch {
                        return (false, "本地 LLM 服务不可达：\(error.localizedDescription)")
                    }
                case .none:
                    return (true, "本地语音识别（\(prefs.localASRPreset.displayName)）已就绪")
                }
            }
            return (true, "本地语音识别（\(prefs.localASRPreset.displayName)）已就绪")
        }
    }

    // MARK: - Private Lifecycle

    private func resetPressState() {
        tapTimeoutItem?.cancel()
        tapTimeoutItem = nil
        holdCueItem?.cancel()
        holdCueItem = nil
        secondPressTime = nil
        handsFree = false
        startCueDue = false
    }

    /// The cue waits until the key is clearly held, so shortcuts on the voice key stay silent.
    private func scheduleHoldCue() {
        holdCueItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holdCueItem = nil
            if self.isCapturing { self.playStartCue() }
        }
        holdCueItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdCueDelay, execute: item)
    }

    private func playStartCue() {
        guard VoicePreferencesStore.shared.prefs.areVoiceCuesEnabled, !cueSounded else { return }
        guard phase == .recording else {
            startCueDue = true
            return
        }
        cueSounded = true
        // Already talking: stay silent rather than put a sound on top of the first words.
        guard max(latestLevel, peakLevelSinceDraw ?? 0) < Self.cueQuietLevel else { return }
        activeRecorder?.muteInput(forSeconds: VoiceCuePlayer.audibleSeconds)
        playCue(.start)
    }

    private func playCue(_ kind: VoiceCueKind) {
        if let cueOverride {
            cueOverride(kind)
        } else {
            VoiceCuePlayer.shared.play(kind)
        }
    }

    private func cancelEngineWarm() {
        engineWarmItem?.cancel()
        engineWarmItem = nil
        engineWarmed = false
        releaseWarmHold()
    }

    private func releaseWarmHold() {
        warmHold?.endSession()
        warmHold = nil
    }

    private func warmEngine(prefs: VoicePreferences) {
        engineWarmItem = nil
        guard isCapturing, prefs.providerMode == .local else { return }
        timeline.mark(.holdFired)
        engineWarmed = true
        guard let engine = VoiceASRRegistry.engine(for: prefs, context: activeContext) else { return }
        activeEngine = engine
        if phase == .recording, let recorder = activeRecorder {
            startEngineStreamIfAvailable(prefs: prefs, recorder: recorder)
        } else {
            engine.beginSession()
            warmHold = engine
        }
        Task { @MainActor [weak self] in
            try? await engine.prepare()
            self?.timeline.mark(.engineReady)
        }
    }

    /// A cancelled start has finished unwinding; honour a press that arrived meanwhile.
    private func runPendingRestart() {
        let restart = pendingRestart
        pendingRestart = nil
        restart?()
    }

    /// Folds a finished AX capture into the dictation and re-biases the engine that is already listening.
    func applyCapturedContext(_ captured: VoiceCapturedContext) {
        activeContext = activeContext.merged(with: captured)
        activeEngine?.updateContext(activeContext)
        let preview = VoiceContextPromptPreview.build(
            context: activeContext,
            prefs: VoicePreferencesStore.shared.prefs
        )
        VoiceContextInspectorStore.shared.recordModelContext(
            asrTargetLabel: preview.asrTargetLabel,
            asrContext: preview.asrContext,
            polishBudgetLabel: preview.polishBudgetLabel,
            polishContext: preview.polishContext
        )
    }

    /// Lets a capture that is about to land reach the final pass, never holding the release up by more than `maxWait`.
    func awaitContextCapture(maxWait: TimeInterval) async {
        guard activeContextCaptureTask != nil, !contextCaptureDone else { return }
        let deadline = Date().addingTimeInterval(maxWait)
        while !contextCaptureDone, activeContextCaptureTask != nil, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Test seam: stands in for a capture task that has not finished yet.
    func beginPendingContextCaptureForTesting() {
        contextCaptureDone = false
        activeContextCaptureTask = Task {}
    }

    /// Test seam: the pending capture lands.
    func finishPendingContextCaptureForTesting(_ captured: VoiceCapturedContext) {
        applyCapturedContext(captured)
        contextCaptureDone = true
    }

    private func ensurePipelineClient() -> VoicePipelineClient {
        if let existing = pipelineClient {
            return existing
        }
        let created = VoicePipelineClient()
        pipelineClient = created
        return created
    }

    private func startRecording(
        caretRect: NSRect,
        windowLevel: CGWindowLevel?,
        context: VoiceContext,
        warmDelay: TimeInterval,
        onCommit: @escaping (_ text: String, _ replaceSelection: Bool) -> Void
    ) {
        if let startRecordingOverride {
            phase = .recording
            startRecordingOverride()
            return
        }
        let prefs = VoicePreferencesStore.shared.prefs
        let useAppleSpeech = (prefs.providerMode == .local && prefs.localASRPreset == .appleSpeech)

        // A blacklisted app is known from its bundle ID at once; the capture adds URL and secure-field checks later.
        let respectBlacklist = VoiceContextInspectorStore.shared.respectBlacklist
        let blacklisted = context.bundleIdentifier.map {
            VoiceContextPolicy.blacklistReason(
                bundleId: $0,
                webURL: nil,
                options: VoiceContextCaptureOptions(respectBlacklist: respectBlacklist)
            ) != nil
        } ?? false

        activeCaretRect = caretRect
        activeWindowLevel = windowLevel
        activeContext = context.restricted(blacklisted)
        activeEngine = nil
        activeCommitHandler = onCommit
        latestLevel = 0
        peakLevelSinceDraw = nil
        latestPartial = ""
        latestTentativeCount = 0
        cueSounded = false

        // Capture full AXUIElement context asynchronously so key-down / HUD display stays instant (0 ms added).
        activeContextCaptureTask?.cancel()
        contextCaptureDone = false
        let captureGeneration = sessionGeneration &+ 1
        activeContextCaptureTask = Task { @MainActor [weak self] in
            let captured = await VoiceContextCapture.captureAsync(
                options: VoiceContextCaptureOptions(respectBlacklist: respectBlacklist)
            )
            guard !Task.isCancelled, let self else { return }
            VoiceContextInspectorStore.shared.record(captured)
            if self.phase == .recording || self.isStarting || self.sessionGeneration == captureGeneration {
                self.applyCapturedContext(captured)
            }
            self.contextCaptureDone = true
        }

        isStarting = true
        startAborted = false
        // The pill and the microphone start at key-down; the model waits until the key is really held.
        VoiceHUDPanelController.shared.show(
            state: .recording(level: 0, elapsed: 0, partial: "", modeLabel: ""),
            caretRect: caretRect,
            clientWindowLevel: windowLevel
        )
        timeline.mark(.hudShown)
        cancelEngineWarm()
        if warmDelay <= 0 {
            warmEngine(prefs: prefs)
        } else if prefs.providerMode == .local {
            let item = DispatchWorkItem { [weak self] in
                self?.warmEngine(prefs: prefs)
            }
            engineWarmItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + warmDelay, execute: item)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let failStart = { (message: String) in
                self.isStarting = false
                self.resetPressState()
                self.cancelEngineWarm()
                if self.startAborted {
                    self.runPendingRestart()
                } else {
                    self.showNotice(message, isError: true)
                }
            }
            let micGranted = await Self.requestMicrophoneAccess()
            guard micGranted else {
                failStart(VoiceEngineError.microphonePermissionDenied.localizedDescription)
                return
            }
            if useAppleSpeech {
                let speechGranted = await Self.requestSpeechRecognitionAccess()
                guard speechGranted else {
                    failStart(VoiceEngineError.speechPermissionDenied.localizedDescription)
                    return
                }
            }

            let recorder = VoiceAudioRecorder()
            recorder.onAudioLevel = { [weak self] level in
                let time = CFAbsoluteTimeGetCurrent()
                Task { @MainActor [weak self] in
                    // Several buffers can arrive per HUD frame; keep the loudest so peaks are not dropped.
                    self?.peakLevelSinceDraw = max(self?.peakLevelSinceDraw ?? 0, level)
                    self?.timeline.mark(.firstBuffer, at: time)
                }
            }
            recorder.onAudioSpectrum = { [weak self] frames in
                let time = CFAbsoluteTimeGetCurrent()
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .recording || self.isStarting else { return }
                    VoiceHUDPanelController.shared.enqueueSpectrumFrames(frames)
                    self.timeline.mark(.firstBuffer, at: time)
                }
            }
            recorder.onPartialTranscript = { [weak self] partial in
                Task { @MainActor [weak self] in
                    self?.latestPartial = partial
                }
            }

            do {
                // Starting the audio engine can take a while, so it must not block the main thread.
                let locale = prefs.localAppleLocale
                let onDevice = prefs.localAppleRequireOnDevice
                // Apple Speech fixes its phrases when the request starts, so it gets what is known by now.
                let phrases = useAppleSpeech ? VoiceASRContextBuilder.contextualStrings(self.activeContext) : []
                try await Task.detached(priority: .userInitiated) {
                    try recorder.start(
                        useAppleSpeech: useAppleSpeech,
                        appleLocale: locale,
                        requireOnDevice: onDevice,
                        contextualStrings: phrases
                    )
                }.value
                self.timeline.mark(.micRunning)
                self.isStarting = false
                if self.startAborted {
                    recorder.cancel()
                    self.runPendingRestart()
                    return
                }
                self.activeRecorder = recorder
                self.phase = .recording
                self.recordingStartTime = Date()
                self.sessionGeneration &+= 1
                if self.engineWarmed {
                    self.startEngineStreamIfAvailable(prefs: prefs, recorder: recorder)
                    self.releaseWarmHold()
                }
                self.startHUDTimer()
                self.refreshRecordingHUD()
                if self.startCueDue {
                    self.startCueDue = false
                    self.playStartCue()
                }
            } catch {
                recorder.cancel()
                failStart(error.localizedDescription)
            }
        }
    }

    /// Starts live partials from the selected engine. If it is unavailable, dictation still works on release.
    private func startEngineStreamIfAvailable(prefs: VoicePreferences, recorder: VoiceAudioRecorder) {
        guard prefs.providerMode == .local,
              let manager = VoiceASRRegistry.engine(for: prefs, context: activeContext) else { return }
        activeEngine = manager
        let generation = sessionGeneration
        let stream = VoiceWhisperStreamSession(
            transcriber: manager,
            language: prefs.language,
            sampleProvider: { [weak recorder] maxCount in
                recorder?.snapshotRecentSamples(maxCount: maxCount) ?? ([], 0)
            },
            onPartial: { [weak self] partial in
                guard let self, self.phase == .recording, self.sessionGeneration == generation else { return }
                self.latestPartial = partial.text
                self.latestTentativeCount = partial.tentativeCount
                self.timeline.mark(.firstResult)
            }
        )
        stream.onPassStarted = { [weak self] in
            self?.timeline.mark(.firstRequest)
            self?.timeline.countPass()
        }
        activeStream = stream
        stream.start()
    }

    private func finishRecordingAndProcess() {
        guard phase == .recording else { return }
        let isShortPress = pressTime.map { Date().timeIntervalSince($0) < Self.tapWindow } ?? false
        pressTime = nil
        let endCue = cueSounded && VoicePreferencesStore.shared.prefs.areVoiceCuesEnabled
        cueSounded = false
        resetPressState()
        if let finishRecordingOverride {
            phase = .idle
            if endCue { playCue(.end) }
            finishRecordingOverride()
            return
        }
        guard let recorder = activeRecorder else { return }
        cancelEngineWarm()
        stopHUDTimer()
        timeline.mark(.release)
        let stream = activeStream
        activeStream = nil
        stream?.stopPartials()
        let generation = sessionGeneration
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())
        let partialText = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLivePartial = !partialText.isEmpty
        phase = .processing

        let prefs = VoicePreferencesStore.shared.prefs
        let modeLabel = prefs.providerMode == .cloudBYOK
            ? prefs.cloudPreset.displayName
            : "本地"
        let useAppleSpeech = (prefs.providerMode == .local && prefs.localASRPreset == .appleSpeech)
        let commitHandler = activeCommitHandler

        let showTranscribing = { [weak self] in
            guard let self else { return }
            VoiceHUDPanelController.shared.show(
                state: .transcribing(modeLabel: modeLabel),
                caretRect: self.activeCaretRect,
                clientWindowLevel: self.activeWindowLevel
            )
        }
        // A tap must not flash the spinner, so it is only shown once speech is confirmed.
        if !isShortPress { showTranscribing() }

        let client = ensurePipelineClient()
        let asrKey = VoiceKeychainStore.read(prefs.effectiveCloudASRKeyAccount)
        let llmKey = VoiceKeychainStore.read(prefs.effectiveCloudLLMKeyAccount)

        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                stream?.cancel()
                // A cancelled task may finish after a newer session started; leave that session alone.
                if self.sessionGeneration == generation {
                    self.activeRecorder = nil
                    self.activeTask = nil
                    self.activeEngine = nil
                    self.phase = .idle
                }
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(Self.releaseTailDelay * 1_000_000_000))
                try Task.checkCancellation()
                // A short press can release before the AX capture lands; give it a moment so the final pass sees it.
                await self.awaitContextCapture(maxWait: Self.contextCaptureGrace)
                try Task.checkCancellation()
                let context = self.activeContext
                let replaceSelection = prefs.speakToEditSelection
                    && !(context.promptSafe().selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let samples = recorder.stopAndCollectSamples()
                // Played only after the microphone has stopped, so it cannot be captured.
                if endCue { self.playCue(.end) }
                self.timeline.levelSummary = recorder.levelSummary()

                if !isShortPress && elapsed < 0.25 && samples.count < 3200 && !hasLivePartial {
                    recorder.cancel()
                    self.showNotice(VoiceEngineError.recordingTooShort.localizedDescription, isError: false, duration: 1.1)
                    return
                }

                if isShortPress {
                    let speech = await Task.detached(priority: .userInitiated) {
                        VoiceSpeechGate.finalAudio(samples)
                    }.value
                    try Task.checkCancellation()
                    guard speech != nil || hasLivePartial else {
                        recorder.cancel()
                        VoiceHUDPanelController.shared.hide()
                        return
                    }
                    showTranscribing()
                }

                let rawTranscript: String
                if useAppleSpeech {
                    rawTranscript = try await recorder.finishAppleSpeech()
                } else {
                    // Local models invent text for silence, so they only ever receive detected speech.
                    let usesLocalEngine = prefs.providerMode == .local && prefs.localASRPreset.backend == .engine
                    var audio = samples
                    var voicedSeconds = 0.0
                    if usesLocalEngine {
                        let gated = await Task.detached(priority: .userInitiated) {
                            VoiceSpeechGate.finalAudio(samples)
                        }.value
                        try Task.checkCancellation()
                        if let speech = gated {
                            audio = speech.audio
                            voicedSeconds = speech.voicedSeconds
                        } else if hasLivePartial {
                            // Live partials already recognised speech; never reject at release.
                            audio = samples
                            voicedSeconds = max(0.5, Double(partialText.count) * VoiceHallucinationFilter.secondsPerOrdinaryChar)
                        } else {
                            throw VoiceEngineError.noSpeechDetected
                        }
                    }
                    let conditioned = VoiceAudioNormalizer.conditionForASR(audio)
                    let wavData = VoiceWAVEncoder.encodePCM16Mono(samples: conditioned, sampleRate: 16_000)
                    var residentText: String?
                    if let stream {
                        do {
                            residentText = try await stream.finish(wavData: wavData, sampleCount: audio.count)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try Task.checkCancellation()
                            VoiceASRRegistry.stopAll()
                        }
                    }
                    if let residentText {
                        rawTranscript = residentText
                    } else {
                        let cliText = try await self.runNonAppleASR(
                            prefs: prefs,
                            client: client,
                            asrKey: asrKey,
                            wavData: wavData,
                            context: context
                        )
                        rawTranscript = usesLocalEngine
                            ? VoiceHallucinationFilter.filtered(
                                VoiceWhisperStreamPolicy.simplified(cliText, language: prefs.language),
                                voicedSeconds: voicedSeconds
                            )
                            : cliText
                    }
                    if usesLocalEngine,
                       rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw VoiceEngineError.noSpeechDetected
                    }
                }

                try Task.checkCancellation()
                let cleanedRaw = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedRaw.isEmpty else {
                    throw VoiceEngineError.emptyTranscript
                }

                let finalText: String
                if prefs.outputMode == .rawDictation {
                    finalText = cleanedRaw
                } else {
                    VoiceHUDPanelController.shared.show(
                        state: .polishing(preview: String(cleanedRaw.prefix(24))),
                        caretRect: self.activeCaretRect,
                        clientWindowLevel: self.activeWindowLevel
                    )
                    finalText = try await self.runPolish(
                        prefs: prefs,
                        client: client,
                        llmKey: llmKey,
                        rawTranscript: cleanedRaw,
                        context: context
                    )
                }

                try Task.checkCancellation()
                self.timeline.mark(.finalDone)
                VoiceHUDPanelController.shared.hide()
                commitHandler?(finalText, replaceSelection)
                self.timeline.mark(.inserted)
                self.timeline.log()
            } catch is CancellationError {
                VoiceHUDPanelController.shared.hide()
            } catch VoiceEngineError.cancelled {
                VoiceHUDPanelController.shared.hide()
            } catch VoiceEngineError.noSpeechDetected where isShortPress {
                VoiceHUDPanelController.shared.hide()
            } catch VoiceEngineError.noSpeechDetected {
                self.showNotice(VoiceEngineError.noSpeechDetected.localizedDescription, isError: false, duration: 1.4)
            } catch {
                self.showNotice(error.localizedDescription, isError: true, duration: 3.2)
            }
        }
    }

    private func runNonAppleASR(
        prefs: VoicePreferences,
        client: VoicePipelineClient,
        asrKey: String,
        wavData: Data,
        context: VoiceContext
    ) async throws -> String {
        /// Sends the prompt, and once more without it if the service only read the prompt back.
        func transcribeHTTP(baseURL: String, apiKey: String?, model: String) async throws -> String {
            let prompt = VoiceASRContextBuilder.recognitionContext(
                context,
                target: .cloud(model: model),
                language: prefs.language
            )
            let text = try await client.transcribeOpenAICompatible(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                language: prefs.language,
                prompt: prompt,
                wavData: wavData
            )
            guard VoiceASRContextBuilder.isPromptEcho(text, prompt: prompt) else { return text }
            return try await client.transcribeOpenAICompatible(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                language: prefs.language,
                prompt: nil,
                wavData: wavData
            )
        }
        switch prefs.providerMode {
        case .cloudBYOK:
            guard !asrKey.isEmpty else {
                throw VoiceEngineError.missingAPIKey(prefs.cloudPreset.displayName)
            }
            return try await transcribeHTTP(
                baseURL: prefs.effectiveCloudASRBaseURL,
                apiKey: asrKey,
                model: prefs.effectiveCloudASRModel
            )
        case .local:
            switch prefs.localASRPreset.backend {
            case .appleSpeech:
                return ""
            case .engine:
                return try await VoiceASRRegistry.transcribeWithFallback(
                    prefs: prefs,
                    client: client,
                    wavData: wavData,
                    context: context
                )
            case .customHTTP:
                return try await transcribeHTTP(
                    baseURL: prefs.localHTTPASRBaseURL,
                    apiKey: nil,
                    model: prefs.localHTTPASRModel
                )
            }
        }
    }

    private func runPolish(
        prefs: VoicePreferences,
        client: VoicePipelineClient,
        llmKey: String,
        rawTranscript: String,
        context: VoiceContext
    ) async throws -> String {
        switch prefs.providerMode {
        case .cloudBYOK:
            guard prefs.cloudPolishEnabled else {
                return rawTranscript
            }
            guard !llmKey.isEmpty else {
                throw VoiceEngineError.missingAPIKey("云端整理 LLM")
            }
            return try await client.polishOpenAICompatible(
                baseURL: prefs.effectiveCloudLLMBaseURL,
                apiKey: llmKey,
                model: prefs.effectiveCloudLLMModel,
                rawTranscript: rawTranscript,
                toneMode: prefs.toneMode,
                context: context
            )
        case .local:
            switch prefs.localLLMPreset {
            case .none:
                return rawTranscript
            case .qwen15B:
                let status = VoiceLocalInstaller.llmStatus(for: .qwen15B)
                guard let bin = status.dependencyPath, let modelPath = status.modelPath, status.isReady else {
                    throw VoiceEngineError.cliFailed("尚未安装本地整理模型，请在「句序偏好设置 → 语音输入」中点击一键下载并安装")
                }
                return try await client.polishLocalLlamaCLI(
                    binaryPath: bin,
                    modelPath: modelPath,
                    rawTranscript: rawTranscript,
                    toneMode: prefs.toneMode,
                    context: context
                )
            case .ollamaHTTP:
                // A local service usually runs a small model, so it gets the compact context.
                return try await client.polishOpenAICompatible(
                    baseURL: prefs.localHTTPLLMBaseURL,
                    apiKey: nil,
                    model: prefs.localHTTPLLMModel,
                    rawTranscript: rawTranscript,
                    toneMode: prefs.toneMode,
                    context: context,
                    budget: .compact
                )
            }
        }
    }

    private func cancelCurrentSession(showNotice: Bool) {
        resetPressState()
        cueSounded = false
        cancelEngineWarm()
        pressTime = nil
        stopHUDTimer()
        if isStarting { startAborted = true }
        sessionGeneration &+= 1
        activeStream?.cancel()
        activeStream = nil
        activeTask?.cancel()
        activeTask = nil
        activeContextCaptureTask?.cancel()
        activeContextCaptureTask = nil
        contextCaptureDone = true
        activeEngine = nil
        activeRecorder?.cancel()
        activeRecorder = nil
        phase = .idle
        if showNotice {
            self.showNotice("已取消语音输入", isError: false, duration: 1.0)
        } else {
            VoiceHUDPanelController.shared.hide()
        }
    }

    private func teardown() {
        resetPressState()
        cueSounded = false
        cancelEngineWarm()
        pendingRestart = nil
        pressTime = nil
        stopHUDTimer()
        if isStarting { startAborted = true }
        sessionGeneration &+= 1
        activeStream?.cancel()
        activeStream = nil
        activeTask?.cancel()
        activeTask = nil
        activeContextCaptureTask?.cancel()
        activeContextCaptureTask = nil
        contextCaptureDone = true
        activeEngine = nil
        activeRecorder?.cancel()
        activeRecorder = nil
        pipelineClient?.invalidate()
        pipelineClient = nil
        phase = .idle
    }

    private func startHUDTimer() {
        stopHUDTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRecordingHUD()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopHUDTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func refreshRecordingHUD() {
        guard phase == .recording else { return }
        if !latestPartial.isEmpty { timeline.mark(.firstDraw) }
        if let peak = peakLevelSinceDraw {
            latestLevel = peak
            peakLevelSinceDraw = nil
        }
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())
        let modeLabel = VoicePreferencesStore.shared.prefs.providerMode == .cloudBYOK
            ? VoicePreferencesStore.shared.prefs.cloudPreset.displayName
            : "本地"
        VoiceHUDPanelController.shared.show(
            state: .recording(
                level: latestLevel,
                elapsed: elapsed,
                partial: latestPartial,
                modeLabel: modeLabel,
                tentativeCount: latestTentativeCount
            ),
            caretRect: activeCaretRect,
            clientWindowLevel: activeWindowLevel
        )
    }

    private func showNotice(_ message: String, isError: Bool, duration: TimeInterval = 2.4) {
        VoiceHUDPanelController.shared.show(
            state: .notice(text: message, isError: isError),
            caretRect: activeCaretRect,
            clientWindowLevel: activeWindowLevel,
            autoHideAfter: duration
        )
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func requestSpeechRecognitionAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

enum VoiceCueKind {
    case start
    case end
}

/// Two short, quiet tones generated in memory: rising to start, falling to end.
@MainActor
final class VoiceCuePlayer {
    static let shared = VoiceCuePlayer()
    /// Tone length plus output latency; the microphone is blanked for this long.
    static let audibleSeconds: TimeInterval = 0.14
    private static let toneSeconds = 0.07
    private static let volume: Float = 0.14

    private lazy var startSound = Self.makeSound(fromHz: 660, toHz: 880)
    private lazy var endSound = Self.makeSound(fromHz: 880, toHz: 620)

    func play(_ kind: VoiceCueKind) {
        guard let sound = kind == .start ? startSound : endSound else { return }
        sound.stop()
        sound.volume = Self.volume
        sound.play()
    }

    static func toneSamples(fromHz: Double, toHz: Double, sampleRate: Double = 44_100) -> [Int16] {
        let count = Int(sampleRate * toneSeconds)
        var phase = 0.0
        return (0..<count).map { i in
            let t = Double(i) / Double(count)
            phase += 2 * .pi * (fromHz + (toHz - fromHz) * t) / sampleRate
            let envelope = min(1, t / 0.08) * pow(1 - t, 2)
            return Int16(sin(phase) * envelope * 0.8 * Double(Int16.max))
        }
    }

    private static func makeSound(fromHz: Double, toHz: Double) -> NSSound? {
        let samples = toneSamples(fromHz: fromHz, toHz: toHz)
        let rate: UInt32 = 44_100
        var wav = Data()
        let u32 = { (v: UInt32) in withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        let u16 = { (v: UInt16) in withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(byteCount)
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return NSSound(data: wav)
    }
}
