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
    private var engineWarmItem: DispatchWorkItem?
    private var engineWarmed = false
    private var warmHold: (any VoiceASREngine)?
    private var pressTime: Date?
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
    private var activeCaretRect: NSRect = .zero
    private var activeWindowLevel: CGWindowLevel?
    private var activeCommitHandler: ((String, Bool) -> Void)?
    private var activeContext: VoiceContext = VoiceContext()

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
        pendingRestart = nil
        if isCapturing { cancelCurrentSession(showNotice: false) }
    }

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
                if phase == .idle {
                    let begin = { [weak self] in
                        guard let self else { return }
                        self.timeline.begin()
                        self.pressTime = Date()
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

    private func warmEngine(prefs: VoicePreferences, vocabulary: [String]) {
        engineWarmItem = nil
        guard isCapturing, prefs.providerMode == .local else { return }
        timeline.mark(.holdFired)
        engineWarmed = true
        guard let engine = VoiceASRRegistry.engine(for: prefs, vocabulary: vocabulary) else { return }
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

        activeCaretRect = caretRect
        activeWindowLevel = windowLevel
        activeContext = context
        activeCommitHandler = onCommit
        latestLevel = 0
        peakLevelSinceDraw = nil
        latestPartial = ""
        latestTentativeCount = 0

        // Capture full AXUIElement context asynchronously so key-down / HUD display stays instant (0 ms added).
        activeContextCaptureTask?.cancel()
        let captureGeneration = sessionGeneration &+ 1
        let respectBlacklist = VoiceContextInspectorStore.shared.respectBlacklist
        activeContextCaptureTask = Task { @MainActor [weak self] in
            let captured = await VoiceContextCapture.captureAsync(
                options: VoiceContextCaptureOptions(respectBlacklist: respectBlacklist)
            )
            guard !Task.isCancelled, let self else { return }
            VoiceContextInspectorStore.shared.record(captured)
            if self.phase == .recording || self.isStarting || self.sessionGeneration == captureGeneration {
                self.activeContext = self.activeContext.merged(with: captured)
            }
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
        let vocabulary = context.personalVocabulary
        if warmDelay <= 0 {
            warmEngine(prefs: prefs, vocabulary: vocabulary)
        } else if prefs.providerMode == .local {
            let item = DispatchWorkItem { [weak self] in
                self?.warmEngine(prefs: prefs, vocabulary: vocabulary)
            }
            engineWarmItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + warmDelay, execute: item)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let failStart = { (message: String) in
                self.isStarting = false
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
                try await Task.detached(priority: .userInitiated) {
                    try recorder.start(useAppleSpeech: useAppleSpeech, appleLocale: locale, requireOnDevice: onDevice)
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
            } catch {
                recorder.cancel()
                failStart(error.localizedDescription)
            }
        }
    }

    /// Starts live partials from the selected engine. If it is unavailable, dictation still works on release.
    private func startEngineStreamIfAvailable(prefs: VoicePreferences, recorder: VoiceAudioRecorder) {
        guard prefs.providerMode == .local,
              let manager = VoiceASRRegistry.engine(for: prefs, vocabulary: activeContext.personalVocabulary) else { return }
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
        if let finishRecordingOverride {
            phase = .idle
            finishRecordingOverride()
            return
        }
        guard let recorder = activeRecorder else { return }
        cancelEngineWarm()
        stopHUDTimer()
        timeline.mark(.release)
        let stream = activeStream
        activeStream = nil
        let generation = sessionGeneration
        let samples = recorder.stopAndCollectSamples()
        timeline.levelSummary = recorder.levelSummary()
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())
        phase = .processing

        let prefs = VoicePreferencesStore.shared.prefs
        let modeLabel = prefs.providerMode == .cloudBYOK
            ? prefs.cloudPreset.displayName
            : "本地"
        let useAppleSpeech = (prefs.providerMode == .local && prefs.localASRPreset == .appleSpeech)
        let context = activeContext
        let commitHandler = activeCommitHandler
        let replaceSelection = prefs.speakToEditSelection
            && !(context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if !isShortPress && elapsed < 0.25 && samples.count < 3200 && latestPartial.isEmpty {
            stream?.cancel()
            recorder.cancel()
            activeRecorder = nil
            phase = .idle
            showNotice(VoiceEngineError.recordingTooShort.localizedDescription, isError: false, duration: 1.1)
            return
        }

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
                    self.phase = .idle
                }
            }

            if isShortPress {
                let speech = await Task.detached(priority: .userInitiated) {
                    VoiceSpeechGate.finalAudio(samples)
                }.value
                guard !Task.isCancelled, speech != nil else {
                    recorder.cancel()
                    VoiceHUDPanelController.shared.hide()
                    return
                }
                showTranscribing()
            }

            do {
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
                        guard let speech = gated else {
                            throw VoiceEngineError.noSpeechDetected
                        }
                        audio = speech.audio
                        voicedSeconds = speech.voicedSeconds
                    }
                    let wavData = VoiceWAVEncoder.encodePCM16Mono(samples: audio, sampleRate: 16_000)
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
                            vocabulary: context.personalVocabulary
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
        vocabulary: [String]
    ) async throws -> String {
        let prompt = VoicePromptBuilder.asrPrompt(vocabulary: vocabulary)
        switch prefs.providerMode {
        case .cloudBYOK:
            guard !asrKey.isEmpty else {
                throw VoiceEngineError.missingAPIKey(prefs.cloudPreset.displayName)
            }
            return try await client.transcribeOpenAICompatible(
                baseURL: prefs.effectiveCloudASRBaseURL,
                apiKey: asrKey,
                model: prefs.effectiveCloudASRModel,
                language: prefs.language,
                prompt: prompt,
                wavData: wavData
            )
        case .local:
            switch prefs.localASRPreset.backend {
            case .appleSpeech:
                return ""
            case .engine:
                return try await VoiceASRRegistry.transcribeWithFallback(prefs: prefs, client: client, wavData: wavData)
            case .customHTTP:
                return try await client.transcribeOpenAICompatible(
                    baseURL: prefs.localHTTPASRBaseURL,
                    apiKey: nil,
                    model: prefs.localHTTPASRModel,
                    language: prefs.language,
                    prompt: prompt,
                    wavData: wavData
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
                return try await client.polishOpenAICompatible(
                    baseURL: prefs.localHTTPLLMBaseURL,
                    apiKey: nil,
                    model: prefs.localHTTPLLMModel,
                    rawTranscript: rawTranscript,
                    toneMode: prefs.toneMode,
                    context: context
                )
            }
        }
    }

    private func cancelCurrentSession(showNotice: Bool) {
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
