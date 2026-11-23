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
        VoiceWhisperServerManager.unload()
    }

    private enum Phase {
        case idle
        case recording
        case processing
    }

    private var phase: Phase = .idle
    private var holdTimer: DispatchWorkItem?
    private var pendingHoldKeyCode: UInt16?
    private var levelTimer: Timer?
    private var recordingStartTime: Date?
    private var latestLevel: Float = 0
    private var latestPartial: String = ""
    private var activeRecorder: VoiceAudioRecorder?
    private var activeStream: VoiceWhisperStreamSession?
    private var sessionGeneration: UInt64 = 0
    private var pipelineClient: VoicePipelineClient?
    private var activeTask: Task<Void, Never>?
    private var activeCaretRect: NSRect = .zero
    private var activeWindowLevel: CGWindowLevel?
    private var activeCommitHandler: ((String, Bool) -> Void)?
    private var activeContext: VoiceContext = VoiceContext()

    private init() {}

    public var isActive: Bool {
        phase != .idle
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

        if event.type == .keyDown && event.keyCode == 0x35 && phase != .idle {
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
            if pendingHoldKeyCode != nil {
                cancelPendingHold()
            }
            return phase == .recording
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
                if phase == .idle && pendingHoldKeyCode == nil {
                    pendingHoldKeyCode = targetKeyCode
                    let item = DispatchWorkItem { [weak self] in
                        guard let self, self.pendingHoldKeyCode == targetKeyCode, self.phase == .idle else { return }
                        self.pendingHoldKeyCode = nil
                        self.startRecording(
                            caretRect: caretRectProvider(),
                            windowLevel: windowLevel,
                            context: contextProvider(),
                            onCommit: onCommit
                        )
                    }
                    holdTimer = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: item)
                }
                return false
            } else {
                cancelPendingHold()
                if phase == .recording {
                    finishRecordingAndProcess()
                    return true
                }
                return false
            }
        } else if pendingHoldKeyCode != nil {
            cancelPendingHold()
        }

        return false
    }

    public func handleDeactivate() {
        cancelPendingHold()
        if phase == .recording {
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
            switch prefs.localASRPreset {
            case .whisperTurbo, .whisperBase:
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

    private func cancelPendingHold() {
        holdTimer?.cancel()
        holdTimer = nil
        pendingHoldKeyCode = nil
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
        onCommit: @escaping (_ text: String, _ replaceSelection: Bool) -> Void
    ) {
        let prefs = VoicePreferencesStore.shared.prefs
        let useAppleSpeech = (prefs.providerMode == .local && prefs.localASRPreset == .appleSpeech)

        activeCaretRect = caretRect
        activeWindowLevel = windowLevel
        activeContext = context
        activeCommitHandler = onCommit
        latestLevel = 0
        latestPartial = ""

        Task { @MainActor [weak self] in
            guard let self else { return }
            let micGranted = await Self.requestMicrophoneAccess()
            guard micGranted else {
                self.showNotice(VoiceEngineError.microphonePermissionDenied.localizedDescription, isError: true)
                return
            }
            if useAppleSpeech {
                let speechGranted = await Self.requestSpeechRecognitionAccess()
                guard speechGranted else {
                    self.showNotice(VoiceEngineError.speechPermissionDenied.localizedDescription, isError: true)
                    return
                }
            }

            let recorder = VoiceAudioRecorder()
            recorder.onAudioLevel = { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.latestLevel = level
                }
            }
            recorder.onPartialTranscript = { [weak self] partial in
                Task { @MainActor [weak self] in
                    self?.latestPartial = partial
                }
            }

            do {
                try recorder.start(
                    useAppleSpeech: useAppleSpeech,
                    appleLocale: prefs.localAppleLocale,
                    requireOnDevice: prefs.localAppleRequireOnDevice
                )
                self.activeRecorder = recorder
                self.phase = .recording
                self.recordingStartTime = Date()
                self.sessionGeneration &+= 1
                self.startWhisperStreamIfAvailable(prefs: prefs, recorder: recorder)
                self.startHUDTimer()
                self.refreshRecordingHUD()
            } catch {
                recorder.cancel()
                self.showNotice(error.localizedDescription, isError: true)
            }
        }
    }

    /// Starts resident-model partials for local Whisper. If unavailable, dictation simply uses the CLI on release.
    private func startWhisperStreamIfAvailable(prefs: VoicePreferences, recorder: VoiceAudioRecorder) {
        guard prefs.providerMode == .local,
              prefs.localASRPreset == .whisperTurbo || prefs.localASRPreset == .whisperBase,
              let serverBinary = VoiceWhisperServerManager.detectServerBinary() else { return }
        let status = VoiceLocalInstaller.asrStatus(for: prefs.localASRPreset)
        guard status.isReady, let modelPath = status.modelPath else { return }

        let manager = VoiceWhisperServerManager.shared
        manager.configure(binaryPath: serverBinary, modelPath: modelPath, language: prefs.language)
        let generation = sessionGeneration
        let stream = VoiceWhisperStreamSession(
            transcriber: manager,
            language: prefs.language,
            sampleProvider: { [weak recorder] maxCount in
                recorder?.snapshotRecentSamples(maxCount: maxCount) ?? ([], 0)
            },
            onPartial: { [weak self] partial in
                guard let self, self.phase == .recording, self.sessionGeneration == generation else { return }
                self.latestPartial = partial
            }
        )
        activeStream = stream
        stream.start()
    }

    private func finishRecordingAndProcess() {
        guard phase == .recording, let recorder = activeRecorder else { return }
        stopHUDTimer()
        let stream = activeStream
        activeStream = nil
        let generation = sessionGeneration
        let samples = recorder.stopAndCollectSamples()
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

        if elapsed < 0.25 && samples.count < 3200 && latestPartial.isEmpty {
            stream?.cancel()
            recorder.cancel()
            activeRecorder = nil
            phase = .idle
            showNotice(VoiceEngineError.recordingTooShort.localizedDescription, isError: false, duration: 1.1)
            return
        }

        VoiceHUDPanelController.shared.show(
            state: .transcribing(modeLabel: modeLabel),
            caretRect: activeCaretRect,
            clientWindowLevel: activeWindowLevel
        )

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

            do {
                let rawTranscript: String
                if useAppleSpeech {
                    rawTranscript = try await recorder.finishAppleSpeech()
                } else {
                    // Local Whisper invents text for silence, so it only ever receives detected speech.
                    let isLocalWhisper = prefs.providerMode == .local
                        && (prefs.localASRPreset == .whisperTurbo || prefs.localASRPreset == .whisperBase)
                    var audio = samples
                    var voicedSeconds = 0.0
                    if isLocalWhisper {
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
                            VoiceWhisperServerManager.sharedIfLoaded?.stop()
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
                        rawTranscript = isLocalWhisper
                            ? VoiceHallucinationFilter.filtered(
                                VoiceWhisperStreamPolicy.simplified(cliText, language: prefs.language),
                                voicedSeconds: voicedSeconds
                            )
                            : cliText
                    }
                    if isLocalWhisper,
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
                VoiceHUDPanelController.shared.hide()
                commitHandler?(finalText, replaceSelection)
            } catch is CancellationError {
                VoiceHUDPanelController.shared.hide()
            } catch VoiceEngineError.cancelled {
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
            switch prefs.localASRPreset {
            case .appleSpeech:
                return ""
            case .whisperTurbo, .whisperBase:
                let status = VoiceLocalInstaller.asrStatus(for: prefs.localASRPreset)
                guard let bin = status.dependencyPath, let modelPath = status.modelPath, status.isReady else {
                    throw VoiceEngineError.cliFailed("尚未安装本地语音模型，请在「句序偏好设置 → 语音输入」中点击一键下载并安装")
                }
                return try await client.transcribeLocalCLI(
                    binaryPath: bin,
                    modelPath: modelPath,
                    language: prefs.language,
                    wavData: wavData
                )
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
        cancelPendingHold()
        stopHUDTimer()
        sessionGeneration &+= 1
        activeStream?.cancel()
        activeStream = nil
        activeTask?.cancel()
        activeTask = nil
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
        cancelPendingHold()
        stopHUDTimer()
        sessionGeneration &+= 1
        activeStream?.cancel()
        activeStream = nil
        activeTask?.cancel()
        activeTask = nil
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
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())
        let modeLabel = VoicePreferencesStore.shared.prefs.providerMode == .cloudBYOK
            ? VoicePreferencesStore.shared.prefs.cloudPreset.displayName
            : "本地"
        VoiceHUDPanelController.shared.show(
            state: .recording(
                level: latestLevel,
                elapsed: elapsed,
                partial: latestPartial,
                modeLabel: modeLabel
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
