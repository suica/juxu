import AppKit

@main
struct SwiftBridgeTests {
    @MainActor
    static func main() {
        let dictsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Dicts", isDirectory: true)
        let bridge = JuxuBridge(customDictsDir: dictsURL, inMemoryOnly: true)

        // 1. Verify 86 / 98 / 06 schema switching & dynamic phrase re-encoding
        assert(bridge.state.schemaId == 86)
        let code86 = bridge.addUserPhrase("棱五笔", persist: false)
        assert(!code86.isEmpty, "Expected 86 phrase code for 棱五笔")

        bridge.switchSchema(98, persist: false)
        assert(bridge.state.schemaId == 98)
        assert(bridge.userPhrases.contains(where: { $0.text == "棱五笔" && !$0.code.isEmpty }))

        bridge.switchSchema(6, persist: false)
        assert(bridge.state.schemaId == 6)

        // Switch back to 86 for typing & touch tests
        bridge.switchSchema(86, persist: false)

        // 2. Verify 4-code unique auto-commit ("我们" = trwu)
        for ch in "trw".unicodeScalars {
            let s = bridge.handleKey(keyCode: 0, scalar: ch.value, hasCmdOrCtrl: false, timestampMs: 100)
            assert(s.commitText.isEmpty)
        }
        let s4 = bridge.handleKey(keyCode: 0, scalar: UnicodeScalar("u").value, hasCmdOrCtrl: false, timestampMs: 120)
        assert(s4.commitText == "我们", "Expected auto-commit 我们, got \(s4.commitText)")

        // 3. Verify continuous touch boundary Bayesian typo rescue (`yrwu` near T/Y border -> "我们")
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "y"), x: 4.54, y: 0.03, isNormalized: true, timestampMs: 200)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "r"), x: 3.00, y: 0.00, isNormalized: true, timestampMs: 260)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "w"), x: 1.00, y: 0.00, isNormalized: true, timestampMs: 320)
        let touchOut = bridge.pushTouch(reportedAscii: UInt8(ascii: "u"), x: 6.00, y: 0.00, isNormalized: true, timestampMs: 380)
        assert(
            touchOut.candidates.first?.text == "我们",
            "Expected Bayesian touch rescue #1 == 我们, got \(String(describing: touchOut.candidates.first?.text))"
        )
        let confirm = bridge.handleKey(keyCode: 0x31, scalar: 32, hasCmdOrCtrl: false, timestampMs: 420)
        assert(confirm.commitText == "我们")
        assert(confirm.calibratedKeyCount >= 1, "Expected online touch adaptation to record calibrated keys")

        // 4. Verify TOML round-trip
        var prefs = bridge.prefs
        assert(prefs.autoSpaceZhEn == true)
        assert(prefs.autoSpaceDigits == true)
        assert(prefs.spaceless == false)
        prefs.strictShortcode = true
        prefs.spaceless = true
        prefs.promoteThreshold = 0.86
        prefs.autoSpaceDigits = false
        let decoded = JuxuPreferences.fromTOML(prefs.toTOML())
        assert(decoded.strictShortcode == true)
        assert(decoded.spaceless == true)
        assert(abs(decoded.promoteThreshold - 0.86) < 0.005)
        assert(decoded.autoSpaceZhEn == true)
        assert(decoded.autoSpaceDigits == false)

        // No-space 98 input through both ABI entry points. Backspace must edit a stroke
        // in the marked tail even after the engine has committed part of the sentence.
        var streamingPrefs = decoded
        streamingPrefs.schemaId = 98
        bridge.applyAndSavePreferences(streamingPrefs, persist: false)
        bridge.setContext("")
        let codes = "wygdgdrtfhvbtrwuggfhfcuktqnkc"
        var committed = ""
        for key in codes.utf8.dropLast() {
            let state = bridge.pushTouch(
                reportedAscii: key, x: 0, y: 0, isNormalized: false, timestampMs: 500
            )
            assert(state.consumed && !state.bell)
            committed += state.commitText
        }
        let beforeLast = bridge.state.preedit
        let last = UInt32(codes.utf8.last!)
        let afterLast = bridge.handleKey(keyCode: 0, scalar: last, hasCmdOrCtrl: false, timestampMs: 501)
        committed += afterLast.commitText
        assert(committed == "今天天气真好我们一起")
        assert(afterLast.preedit == "去吃饭吧")
        assert(afterLast.macOSPreedit == "fcu·ktqn·kc")
        assert(afterLast.segmentedCode.hasSuffix("│ fcu·ktqn·kc"))
        assert(afterLast.segmentedCode.filter(\.isLetter) == codes)
        assert(afterLast.candidates.contains { $0.text == "吧" })
        assert(bridge.handleKey(keyCode: 0x33, scalar: 0, hasCmdOrCtrl: false, timestampMs: 502).preedit == beforeLast)
        _ = bridge.handleKey(keyCode: 0, scalar: last, hasCmdOrCtrl: false, timestampMs: 503)
        let punct = bridge.handleKey(keyCode: 0, scalar: 46, hasCmdOrCtrl: false, timestampMs: 504)
        assert(punct.commitText == "去吃饭吧。" && punct.preedit.isEmpty)
        assert(punct.segmentedCode.isEmpty)
        for enterKey: UInt16 in [0x24, 0x4c] {
            for key in "hello".unicodeScalars {
                let state = bridge.handleKey(keyCode: 0, scalar: key.value, hasCmdOrCtrl: false, timestampMs: 505)
                assert(state.commitText.isEmpty)
            }
            let enter = bridge.handleKey(keyCode: enterKey, scalar: 13, hasCmdOrCtrl: false, timestampMs: 506)
            assert(enter.commitText == "hello" && enter.preedit.isEmpty && enter.segmentedCode.isEmpty)
        }
        for key in "qbh".unicodeScalars {
            _ = bridge.handleKey(keyCode: 0, scalar: key.value, hasCmdOrCtrl: false, timestampMs: 507)
        }
        let singleIndex = bridge.allCandidates(maxCount: 30).firstIndex { $0.text == "邜" }!
        assert(bridge.selectAbsCandidate(absIndex: singleIndex, timestampMs: 508).commitText == "邜")
        bridge.setContext("")
        for key in codes.unicodeScalars {
            _ = bridge.handleKey(keyCode: 0, scalar: key.value, hasCmdOrCtrl: false, timestampMs: 509)
        }
        let tailIndex = bridge.state.candidates.firstIndex { $0.text == "吧" }!
        assert(bridge.selectCandidate(pageRelIndex: tailIndex, timestampMs: 510).commitText == "去吃饭吧")

        // 4b. Verify Chinese/English auto-spacing formatter & edge cases
        let allOn = AutoSpaceOptions(enabled: true, spaceDigits: true)
        let noDigits = AutoSpaceOptions(enabled: true, spaceDigits: false)
        let allOff = AutoSpaceOptions(enabled: false, spaceDigits: true)

        // Basic CJK <-> EN & Digits
        assert(AutoSpaceFormatter.format(before: "你好", inserting: "hello", splitInternal: false, options: allOn).text == " hello")
        assert(AutoSpaceFormatter.format(before: "hello", inserting: "世界", splitInternal: false, options: allOn).text == " 世界")
        assert(AutoSpaceFormatter.format(before: "第", inserting: "1", splitInternal: false, options: allOn).text == " 1")
        assert(AutoSpaceFormatter.format(before: "2026", inserting: "年", splitInternal: false, options: allOn).text == " 年")

        // Digits toggle (`spaceDigits: false` keeps `2026年` / `第1`, yet still spaces `iPhone17 手机` / `5G 网络`)
        assert(AutoSpaceFormatter.format(before: "第", inserting: "1", splitInternal: false, options: noDigits).text == "1")
        assert(AutoSpaceFormatter.format(before: "2026", inserting: "年", splitInternal: false, options: noDigits).text == "年")
        assert(AutoSpaceFormatter.format(before: "3.14", inserting: "倍", splitInternal: false, options: noDigits).text == "倍")
        assert(AutoSpaceFormatter.format(before: "iPhone17", inserting: "手机", splitInternal: false, options: noDigits).text == " 手机")
        assert(AutoSpaceFormatter.format(before: "看", inserting: "3D", splitInternal: false, options: noDigits).text == " 3D")

        // Disabled mode
        assert(AutoSpaceFormatter.format(before: "你好", inserting: "hello", splitInternal: false, options: allOff).text == "hello")

        // Existing whitespace / newline / fullwidth space -> never double-space
        assert(AutoSpaceFormatter.format(before: "", inserting: "hello", splitInternal: false, options: allOn).text == "hello")
        assert(AutoSpaceFormatter.format(before: "你好 ", inserting: "hello", splitInternal: false, options: allOn).text == "hello")
        assert(AutoSpaceFormatter.format(before: "你好\n", inserting: "hello", splitInternal: false, options: allOn).text == "hello")
        assert(AutoSpaceFormatter.format(before: "你好\t", inserting: "hello", splitInternal: false, options: allOn).text == "hello")
        assert(AutoSpaceFormatter.format(before: "你好\u{3000}", inserting: "hello", splitInternal: false, options: allOn).text == "hello")
        assert(AutoSpaceFormatter.format(before: "你好", inserting: " hello", splitInternal: false, options: allOn).text == " hello")

        // Fullwidth Chinese punctuation & halfwidth code/markdown punctuation -> never insert space
        assert(AutoSpaceFormatter.format(before: "你好，", inserting: "world", splitInternal: false, options: allOn).text == "world")
        assert(AutoSpaceFormatter.format(before: "hello", inserting: "，", splitInternal: false, options: allOn).text == "，")
        assert(AutoSpaceFormatter.format(before: "（", inserting: "test", splitInternal: false, options: allOn).text == "test")
        assert(AutoSpaceFormatter.format(before: "（test）", inserting: "的", splitInternal: false, options: allOn).text == "的")
        assert(AutoSpaceFormatter.format(before: "函数", inserting: "(", splitInternal: false, options: allOn).text == "(")
        assert(AutoSpaceFormatter.format(before: "[", inserting: "链接", splitInternal: false, options: allOn).text == "链接")
        assert(AutoSpaceFormatter.format(before: "中/", inserting: "English", splitInternal: false, options: allOn).text == "English")
        assert(AutoSpaceFormatter.format(before: "中文", inserting: "/", splitInternal: false, options: allOn).text == "/")
        assert(AutoSpaceFormatter.format(before: "#", inserting: "话题", splitInternal: false, options: allOn).text == "话题")
        assert(AutoSpaceFormatter.format(before: "`", inserting: "代码", splitInternal: false, options: allOn).text == "代码")
        assert(AutoSpaceFormatter.format(before: "你好", inserting: "😀", splitInternal: false, options: allOn).text == "😀")

        // URLs with CJK paths stay intact, while prose after ASCII URL gets space
        assert(AutoSpaceFormatter.format(before: "https://zh.wikipedia.org/wiki/五笔", inserting: "86", splitInternal: false, options: allOn).text == "86")
        assert(AutoSpaceFormatter.format(before: "https://example.com?q=五笔", inserting: "v2", splitInternal: false, options: allOn).text == "v2")
        assert(AutoSpaceFormatter.format(before: "看 https://github.com/nameoverflow/formordo", inserting: "仓库", splitInternal: false, options: allOn).text == " 仓库")
        assert(AutoSpaceFormatter.format(before: "https://example.com/docs/", inserting: "文档", splitInternal: false, options: allOn).text == "文档")

        // Special language tokens & percent
        assert(AutoSpaceFormatter.format(before: "用 C++", inserting: "写", splitInternal: false, options: allOn).text == " 写")
        assert(AutoSpaceFormatter.format(before: "用 g++", inserting: "编译", splitInternal: false, options: allOn).text == " 编译")
        assert(AutoSpaceFormatter.format(before: "用 C#", inserting: "开发", splitInternal: false, options: allOn).text == " 开发")
        assert(AutoSpaceFormatter.format(before: "增长 50%", inserting: "左右", splitInternal: false, options: allOn).text == " 左右")
        assert(AutoSpaceFormatter.format(before: "增长 50%", inserting: "左右", splitInternal: false, options: noDigits).text == "左右")
        assert(AutoSpaceFormatter.format(before: "%50%", inserting: "测试", splitInternal: false, options: allOn).text == "测试")

        // Internal mixed boundary (`我们A`) vs clipboard (`splitInternal: false`)
        assert(AutoSpaceFormatter.format(before: "hello", inserting: "我们A", splitInternal: true, options: allOn).text == " 我们 A")
        assert(AutoSpaceFormatter.format(before: "你好", inserting: "我们A", splitInternal: true, options: allOn).text == "我们 A")
        assert(AutoSpaceFormatter.format(before: "使用", inserting: "iOS开发", splitInternal: false, options: allOn).text == " iOS开发")

        // CJK Extension B surrogate pair + Latin extended
        assert(AutoSpaceFormatter.format(before: "𠮷", inserting: "a", splitInternal: false, options: allOn).text == " a")
        assert(AutoSpaceFormatter.format(before: "café", inserting: "店", splitInternal: false, options: allOn).text == " 店")

        // Backspace-deleted auto-space suppression & tracker state tests (authoritative macOS & optimistic iOS)
        var macTracker = AutoSpaceContextTracker()
        assert(macTracker.prepareCommit("T", hostBefore: "", hostBeforeIsAuthoritative: true, splitInternal: true, options: allOn) == "T")
        assert(macTracker.prepareCommit("恤", hostBefore: "T", hostBeforeIsAuthoritative: true, splitInternal: true, options: allOn) == " 恤")
        // User deletes '恤', then deletes ' ' -> suppresses auto-space at "T"
        macTracker.willDeleteBackward(hostBefore: "T 恤", hostBeforeIsAuthoritative: true)
        macTracker.willDeleteBackward(hostBefore: "T ", hostBeforeIsAuthoritative: true)
        assert(macTracker.prepareCommit("恤", hostBefore: "T", hostBeforeIsAuthoritative: true, splitInternal: true, options: allOn) == "恤")

        // Deleting a single wrong letter keeps the space when typing replacement letter
        var macTracker2 = AutoSpaceContextTracker()
        assert(macTracker2.prepareCommit("a", hostBefore: "你好", hostBeforeIsAuthoritative: true, splitInternal: false, options: allOn) == " a")
        macTracker2.willDeleteBackward(hostBefore: "你好 a", hostBeforeIsAuthoritative: true)
        assert(macTracker2.prepareCommit("b", hostBefore: "你好 ", hostBeforeIsAuthoritative: true, splitInternal: false, options: allOn) == "b")

        // Deleting a whole multi-key word (>2 commits) does NOT suppress space for a fresh word
        var macTracker3 = AutoSpaceContextTracker()
        assert(macTracker3.prepareCommit("a", hostBefore: "你好", hostBeforeIsAuthoritative: true, splitInternal: false, options: allOn) == " a")
        macTracker3.recordPassthrough("b", hostBefore: "你好 a", hostBeforeIsAuthoritative: true)
        macTracker3.recordPassthrough("c", hostBefore: "你好 ab", hostBeforeIsAuthoritative: true)
        macTracker3.willDeleteBackward(hostBefore: "你好 abc", hostBeforeIsAuthoritative: true)
        macTracker3.willDeleteBackward(hostBefore: "你好 ab", hostBeforeIsAuthoritative: true)
        macTracker3.willDeleteBackward(hostBefore: "你好 a", hostBeforeIsAuthoritative: true)
        macTracker3.willDeleteBackward(hostBefore: "你好 ", hostBeforeIsAuthoritative: true)
        assert(macTracker3.prepareCommit("x", hostBefore: "你好", hostBeforeIsAuthoritative: true, splitInternal: false, options: allOn) == " x")

        // iOS stale-XPC optimistic tracking: host stays stale across rapid commit + EN key + Backspace x2 + retype
        var iosTracker = AutoSpaceContextTracker()
        assert(iosTracker.prepareCommit("我们", hostBefore: "hello", hostBeforeIsAuthoritative: false, splitInternal: true, options: allOn) == " 我们")
        // Host still reports "hello" (XPC lag!) when user immediately types 'a'
        assert(iosTracker.prepareCommit("a", hostBefore: "hello", hostBeforeIsAuthoritative: false, splitInternal: false, options: allOn) == " a")
        // Rapid Backspace x2 while host STILL reports "hello"
        iosTracker.willDeleteBackward(hostBefore: "hello", hostBeforeIsAuthoritative: false)
        iosTracker.willDeleteBackward(hostBefore: "hello", hostBeforeIsAuthoritative: false)
        // Re-type 'a' while host catches up to "hello 我们"
        iosTracker.reconcileExternalContext(hostBefore: "hello 我们")
        assert(iosTracker.prepareCommit("a", hostBefore: "hello 我们", hostBeforeIsAuthoritative: false, splitInternal: false, options: allOn) == "a")

        // 5. Verify pure AppKit NativeCandidateContentView NEVER wraps lines even across narrow->wide transitions
        let candidateView = NativeCandidateContentView(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
        candidateView.maxAllowedWidth = 800
        let narrowState = JuxuActionState(
            consumed: true, bell: false, asciiMode: false, schemaId: 86, page: 0, totalPages: 1, vertical: false,
            schemaName: "86版五笔", commitText: "", preedit: "g", notice: "", userPhraseCount: 0, calibratedKeyCount: 0,
            candidates: [JuxuCandidateItem(index: 1, text: "一", comment: "", badge: 0, confidence: 1, isExact: true)]
        )
        candidateView.state = narrowState
        let sz1 = candidateView.computeFittingSize()
        assert(sz1.height == 30.0, "Expected exact 30pt single-line bar height, got \(sz1.height)")

        let wideMultiPhraseState = JuxuActionState(
            consumed: true, bell: false, asciiMode: false, schemaId: 86, page: 0, totalPages: 3, vertical: false,
            schemaName: "86版五笔", commitText: "", preedit: "khk", notice: "", userPhraseCount: 0, calibratedKeyCount: 0,
            candidates: [
                JuxuCandidateItem(index: 1, text: "中华人民共和国", comment: "⚡k", badge: 1, confidence: 1, isExact: true),
                JuxuCandidateItem(index: 2, text: "一心一意", comment: "", badge: 0, confidence: 1, isExact: true),
                JuxuCandidateItem(index: 3, text: "实事求是", comment: "", badge: 0, confidence: 1, isExact: true),
                JuxuCandidateItem(index: 4, text: "千方百计", comment: "", badge: 0, confidence: 1, isExact: true),
                JuxuCandidateItem(index: 5, text: "自力更生", comment: "", badge: 0, confidence: 1, isExact: true),
            ]
        )
        candidateView.state = wideMultiPhraseState
        let sz2 = candidateView.computeFittingSize()
        assert(sz2.height == 30.0, "Expected strictly single-line 30pt height without wrapping, got \(sz2.height)")
        assert(sz2.width > sz1.width + 200.0, "Expected horizontal candidate bar to expand cleanly on single line")

        bridge.setContext("")
        for key in "qdgip".unicodeScalars {
            _ = bridge.handleKey(keyCode: 0, scalar: key.value, hasCmdOrCtrl: false, timestampMs: 600)
        }
        candidateView.state = bridge.state
        candidateView.frame.size = candidateView.computeFittingSize()
        candidateView.layout()
        assert(bridge.state.preedit == "我感觉" && bridge.state.macOSPreedit == "q·dgip")
        assert(candidateView.frame.height == 30 && candidateView.subviews.isEmpty)
        candidateView.state = narrowState
        assert(narrowState.macOSPreedit == "g")

        // 6. Verify macOS Voice MVP: strict lazy-loading, preset resolution, preferences persistence, WAV/multipart, prompts & local polisher
        assert(VoicePreferences().enabled == false, "Voice entry must be disabled by default")
        assert(!VoiceSessionController.isLoaded, "VoiceSessionController must NOT be loaded before voice is enabled")
        assert(!VoiceHUDPanelController.isLoaded, "VoiceHUDPanelController must NOT be loaded before voice is enabled")
        assert(!VoiceLocalInstaller.isLoaded, "VoiceLocalInstaller must NOT be loaded before voice is enabled")
        precondition(!VoiceWhisperServerManager.isLoaded, "whisper-server manager must NOT be loaded before voice is enabled")
        precondition(VoiceWhisperStreamPolicy.normalizedTranscript("今天开会\n 明天发布\n") == "今天开会明天发布")
        precondition(VoiceWhisperStreamPolicy.normalizedTranscript("hello\nworld") == "hello world")
        precondition(VoiceSpeechGate.finalAudio([Int16](repeating: 0, count: 48_000)) == nil, "digital silence is not speech")
        precondition(VoiceSpeechGate.finalAudio([Int16](repeating: 1_000, count: 48_000)) == nil, "a steady level is not speech")
        var clicks = [Int16](repeating: 5, count: 48_000)
        for c in 0..<9 { for j in 0..<160 { clicks[3_000 + c * 5_000 + j] = 9_000 } }
        precondition(VoiceSpeechGate.finalAudio(clicks) == nil, "isolated key clicks are not speech")
        // A periodic 150 Hz signal with a syllable envelope is the shape the gate looks for.
        var voiced = [Int16](repeating: 0, count: 48_000)
        for i in 16_000..<32_000 {
            let envelope = 0.6 + 0.4 * sin(2 * Double.pi * 4 * Double(i) / 16_000)
            voiced[i] = Int16(3_000 * envelope * sin(2 * Double.pi * 150 * Double(i) / 16_000))
        }
        precondition(VoiceSpeechGate.finalAudio(voiced) != nil, "periodic speech-like audio is kept")
        precondition(VoiceLocalASRModelPreset(rawValue: "whisper_turbo") == .whisperTurbo, "existing presets still decode")
        precondition(VoiceLocalASRModelPreset(rawValue: "qwen3_asr") == .qwen3ASR)
        precondition(VoiceQwenHelperManager.modelLanguage("zh") == "Chinese")
        precondition(VoiceQwenHelperManager.modelLanguage("auto") == nil)
        precondition(!VoiceQwenHelperManager.isLoaded, "Qwen helper must NOT be loaded before voice is enabled")
        precondition(VoiceLocalASRModelPreset.qwen3ASR.descriptor.pinned?.isInstalled(at: FileManager.default.temporaryDirectory) == false, "no marker means not installed")
        for preset in VoiceLocalASRModelPreset.allCases {
            precondition(!preset.displayName.isEmpty, "every preset has a descriptor")
            precondition((preset.descriptor.executor != nil) == (preset.backend == .engine))
        }
        precondition(VoiceLocalASRModelPreset.whisperTurbo.modelFilename == "ggml-large-v3-turbo-q5_0.bin", "existing model files keep their names")
        precondition(VoiceLocalASRModelPreset.whisperBase.modelFilename == "ggml-base.bin")
        precondition(VoiceHallucinationFilter.shouldDrop("请不吝点赞 订阅 转发 打赏支持明镜与点点栏目", voicedSeconds: 0.3))
        precondition(VoiceHallucinationFilter.shouldDrop("字幕志愿者 杨栋梁", voicedSeconds: 0))
        precondition(!VoiceHallucinationFilter.shouldDrop("请大家点赞订阅转发", voicedSeconds: 1.6), "a person really saying it keeps it")
        precondition(!VoiceHallucinationFilter.shouldDrop("这个视频的点赞和转发数据不错", voicedSeconds: 0), "ordinary sentences are never credits")
        precondition(VoiceHallucinationFilter.filtered("今天下午三点我们开会讨论一下新版本的发布计划\n请不吝点赞 订阅 转发 打赏支持明镜与点点栏目", voicedSeconds: 4.2) == "今天下午三点我们开会讨论一下新版本的发布计划", "a credit line cannot borrow real speech as evidence")
        precondition(VoiceHallucinationFilter.filtered("请大家点赞订阅转发", voicedSeconds: 1.6) == "请大家点赞订阅转发")
        precondition(VoiceWhisperStreamPolicy.simplified("今天下午三點我們開", language: "zh") == "今天下午三点我们开")
        precondition(VoiceWhisperStreamPolicy.simplified("之後對於這個問題是什麼", language: "zh") == "之后对于这个问题是什么")
        let latinAndPunctuation = "Hello World 123, GPT-4 v2.1 (test) 100%! ,.?;:，。！？、《》"
        precondition(VoiceWhisperStreamPolicy.simplified(latinAndPunctuation, language: "zh") == latinAndPunctuation)
        let validSimplified = "俱乐部 摔跤 狼藉 姊妹 乾隆 乾坤 著名 瞭望 大阪 苎麻 叱吒 钳子 酒麴 折叠 于是 头发 里面 皇后 云彩 一只 几个 准备"
        precondition(VoiceWhisperStreamPolicy.simplified(validSimplified, language: "zh") == validSimplified)
        precondition(VoiceWhisperStreamPolicy.simplified("三點", language: "en") == "三點", "only zh is converted")
        precondition(VoiceHallucinationFilter.shouldDrop(VoiceWhisperStreamPolicy.simplified("請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目", language: "zh"), voicedSeconds: 0.3))

        let defaultVoice = VoicePreferences()
        assert(defaultVoice.cloudPreset == .groq)
        assert(defaultVoice.effectiveCloudASRBaseURL == "https://api.groq.com/openai/v1")
        assert(defaultVoice.effectiveCloudASRModel == "whisper-large-v3-turbo")
        assert(defaultVoice.effectiveCloudLLMModel == "llama-3.3-70b-versatile")
        assert(defaultVoice.effectiveCloudASRKeyAccount == defaultVoice.effectiveCloudLLMKeyAccount)

        let tempVoiceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("juxu-voice-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempVoiceURL) }
        let voiceStore = VoicePreferencesStore(fileURL: tempVoiceURL, inMemoryOnly: false)
        assert(!voiceStore.prefs.enabled)
        voiceStore.update {
            $0.enabled = true
            $0.providerMode = .local
            $0.localASRPreset = .whisperTurbo
            $0.localLLMPreset = .qwen15B
            $0.customVocabulary = "句序, Juxu，RWKV-7\nTypeless"
        }
        let reloadedStore = VoicePreferencesStore(fileURL: tempVoiceURL, inMemoryOnly: false)
        assert(reloadedStore.prefs.enabled == true)
        assert(reloadedStore.prefs.providerMode == .local)
        assert(reloadedStore.prefs.localASRPreset == .whisperTurbo)
        assert(reloadedStore.prefs.localLLMPreset == .qwen15B)
        assert(reloadedStore.prefs.parsedCustomVocabulary == ["句序", "Juxu", "RWKV-7", "Typeless"])

        // Trigger lazy load and verify disabling voice unloads session, HUD, and local installer
        _ = VoiceSessionController.shared
        _ = VoiceLocalInstaller.shared
        _ = VoiceWhisperServerManager.shared
        _ = VoiceQwenHelperManager.shared
        assert(VoiceSessionController.isLoaded)
        assert(VoiceLocalInstaller.isLoaded)
        reloadedStore.update { $0.enabled = false }
        assert(!VoiceSessionController.isLoaded, "Disabling voice must unload VoiceSessionController")
        assert(!VoiceHUDPanelController.isLoaded, "Disabling voice must unload VoiceHUDPanelController")
        assert(!VoiceLocalInstaller.isLoaded, "Disabling voice must unload VoiceLocalInstaller")
        precondition(!VoiceWhisperServerManager.isLoaded, "Disabling voice must unload the whisper-server manager")
        precondition(!VoiceQwenHelperManager.isLoaded, "Disabling voice must unload the Qwen helper manager")

        // Verify legacy "rule_based" config migrates cleanly to local LLM (.qwen15B)
        let defaultVoiceLLM = VoicePreferences()
        assert(defaultVoiceLLM.localLLMPreset == .qwen15B)
        let migrated = try! JSONDecoder().decode(VoiceLocalLLMPreset.self, from: Data("\"rule_based\"".utf8))
        assert(migrated == .qwen15B, "Legacy rule_based must migrate to .qwen15B")

        // Verify app-aware tone & Speak-to-Edit prompt builder
        assert(VoiceAppStyleClassifier.styleInstruction(toneMode: .autoByApp, bundleIdentifier: "com.tencent.xinWeChat").contains("即时聊天"))
        assert(VoiceAppStyleClassifier.styleInstruction(toneMode: .autoByApp, bundleIdentifier: "com.apple.dt.Xcode").contains("技术术语"))
        let normalMsgs = VoicePromptBuilder.polishMessages(
            rawTranscript: "测试一下",
            toneMode: .autoByApp,
            context: VoiceContext(bundleIdentifier: "com.apple.mail", personalVocabulary: ["句序", "句序", "Juxu"])
        )
        assert(normalMsgs.count == 2)
        assert(normalMsgs[0]["content"]?.contains("句序、Juxu") == true)
        let editMsgs = VoicePromptBuilder.polishMessages(
            rawTranscript: "翻成英文",
            toneMode: .professional,
            context: VoiceContext(selectedText: "你好世界")
        )
        assert(editMsgs[1]["content"]?.contains("你好世界") == true && editMsgs[1]["content"]?.contains("翻成英文") == true)

        // Verify WAV header & multipart form builder
        let wav = VoiceWAVEncoder.encodePCM16Mono(samples: [0, 1000, -1000, 32767], sampleRate: 16_000)
        assert(wav.count == 44 + 8)
        assert(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        assert(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let multipart = VoiceMultipartBuilder.buildAudioTranscriptionBody(
            boundary: "TESTBOUNDARY",
            wavData: wav,
            model: "whisper-large-v3-turbo",
            language: "zh",
            prompt: "句序"
        )
        let multipartPrefix = String(decoding: multipart.prefix(320), as: UTF8.self)
        assert(multipartPrefix.contains("--TESTBOUNDARY"))
        assert(multipartPrefix.contains("whisper-large-v3-turbo"))
        assert(multipartPrefix.contains("speech.wav"))

        // 7. Verify Cangjie 3 / 5 / 6 schema switching, categories, TOML round-trip, and 5-code input
        for (sid, expectedName, expectedTag) in [(UInt32(33), "仓颉三代", "cangjie3"), (UInt32(35), "仓颉五代", "cangjie5"), (UInt32(36), "仓颉六代", "cangjie6")] {
            bridge.switchSchema(sid, persist: false)
            assert(bridge.state.schemaId == sid)
            assert(bridge.state.schemaName == expectedName, "Expected \(expectedName), got \(bridge.state.schemaName)")
            assert(bridge.prefs.schemaCategory == .cangjie)
            assert(bridge.prefs.isCangjieFamily)
            let toml = bridge.prefs.toTOML()
            assert(toml.contains("schema = \"\(expectedTag)\""))
            assert(JuxuPreferences.fromTOML(toml).schemaId == sid)
        }
        bridge.switchSchema(35, persist: false)
        var cjPrefs = bridge.prefs
        cjPrefs.spaceless = false
        bridge.applyAndSavePreferences(cjPrefs, persist: false)
        for ch in "grmb".unicodeScalars {
            let s = bridge.handleKey(keyCode: 0, scalar: ch.value, hasCmdOrCtrl: false, timestampMs: 700)
            assert(s.commitText.isEmpty)
        }
        assert(bridge.state.preedit == "土口一月", "Expected Cangjie radicals 土口一月, got \(bridge.state.preedit)")
        let cj5Out = bridge.handleKey(keyCode: 0, scalar: UnicodeScalar("c").value, hasCmdOrCtrl: false, timestampMs: 720)
        assert(cj5Out.commitText == "頡", "Expected Cangjie 5-code auto-commit 頡, got \(cj5Out.commitText)")

        print("✓ All Swift <-> Rust C ABI bridge, pure-AppKit non-wrapping candidate bar, Cangjie, Bayesian typo & macOS Voice MVP tests passed!")
    }
}
