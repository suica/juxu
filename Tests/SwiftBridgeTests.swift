import AppKit
import SwiftUI

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

        let cadence = VoicePartialCadence.standard
        precondition(cadence.interval(lastPass: 0.1, thermal: .nominal, lowPower: false, memoryPressure: false) == cadence.minInterval, "fast passes run at the target cadence")
        precondition(abs(cadence.interval(lastPass: 0.7, thermal: .nominal, lowPower: false, memoryPressure: false) - 1.0) < 0.001, "slow passes back off so the model is not pinned")
        precondition(cadence.interval(lastPass: 0.1, thermal: .serious, lowPower: false, memoryPressure: false) >= 1.0, "a hot Mac slows captions")
        precondition(cadence.interval(lastPass: 0.1, thermal: .critical, lowPower: false, memoryPressure: false) >= 2.0)
        precondition(cadence.interval(lastPass: 0.1, thermal: .nominal, lowPower: true, memoryPressure: false) >= 0.7, "Low Power Mode slows captions")
        precondition(cadence.interval(lastPass: 0.1, thermal: .nominal, lowPower: false, memoryPressure: true) >= 1.0, "memory pressure slows captions")
        var timing = VoiceSessionTimeline()
        timing.begin(); timing.mark(.release, at: CFAbsoluteTimeGetCurrent() + 1); timing.mark(.release, at: CFAbsoluteTimeGetCurrent() + 9)
        precondition(timing.summary.contains("release=") && !timing.summary.contains("release=9"), "a timing mark keeps its first value")

        var stable = VoicePartialStabilizer()
        precondition(stable.update("今天下午", windowed: false) == VoicePartialDisplay(text: "今天下午", tentativeCount: 4), "the first pass is tentative")
        precondition(stable.update("今天下午三点", windowed: false) == VoicePartialDisplay(text: "今天下午三点", tentativeCount: 2), "text seen twice is locked")
        precondition(stable.update("今天下午三点开会。", windowed: false).text == "今天下午三点开会", "a trailing full stop is not shown while speaking")
        let oneBadPass = stable.update("完全不同的内容在这里", windowed: false)
        precondition(oneBadPass.text == "今天下午三点开会", "one pass that cannot be aligned does not move the caption")
        var sliding = VoicePartialStabilizer()
        _ = sliding.update("甲乙丙丁戊己庚辛壬癸", windowed: false)
        _ = sliding.update("甲乙丙丁戊己庚辛壬癸子丑", windowed: false)
        let slid = sliding.update("丁戊己庚辛壬癸子丑寅卯", windowed: true)
        precondition(slid.text == "甲乙丙丁戊己庚辛壬癸子丑寅卯", "a sliding window aligns on overlap, not position")
        var punctuation = VoicePartialStabilizer()
        _ = punctuation.update("我们开会。", windowed: false)
        precondition(punctuation.update("我们开会，讨论", windowed: false).text == "我们开会，讨论", "changed punctuation is not a disagreement")
        var latin = VoicePartialStabilizer()
        _ = latin.update("open the", windowed: false)
        precondition(latin.update("open therapy", windowed: false).tentativeCount == " therapy".count, "half a Latin word is not locked")

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

        // Global voice key: off by default, and existing settings files are unaffected.
        let legacyVoice = try! JSONEncoder().encode(VoicePreferences())
        precondition(!String(decoding: legacyVoice, as: UTF8.self).contains("globalVoiceHotkey"), "off leaves voice.json unchanged")
        precondition(try! JSONDecoder().decode(VoicePreferences.self, from: legacyVoice).isGlobalHotkeyEnabled == false)
        precondition(!VoiceGlobalHotkeyController.isLoaded && !VoiceGlobalHotkeyController.isListening, "nothing listens while off")
        var globalOn = VoicePreferences(); globalOn.globalVoiceHotkey = true
        precondition(try! JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(globalOn)).isGlobalHotkeyEnabled)

        let route = { (down: Bool, key: UInt16, flags: NSEvent.ModifierFlags, secure: Bool, recording: Bool) in
            VoiceGlobalKeyRouter.decide(isKeyDown: down, keyCode: key, flags: flags, trigger: .rightCommand, isSecureInput: secure, isRecording: recording)
        }
        precondition(route(false, 0x36, .command, false, false) == .forward, "the trigger reaches the hold logic")
        precondition(route(true, 8, .command, false, false) == .forward, "a chord reaches the pending hold and cancels it")
        precondition(route(true, 8, .command, false, true) == .cancelChord, "a shortcut during recording cancels dictation")
        precondition(route(true, 0x35, [], false, true) == .forward, "Esc cancels")
        precondition(route(false, 0x36, .command, true, false) == .ignore, "secure input never starts a recording")
        precondition(route(true, 8, [], true, false) == .ignore, "keys in secure input are not read")
        precondition(route(false, 0x36, [], true, true) == .forward, "a recording in progress can still end")
        precondition(VoiceGlobalKeyRouter.decide(isKeyDown: true, keyCode: 0x31, flags: .option, trigger: .optionSpace, isSecureInput: false, isRecording: false) == .ignore, "Option+Space is not global")

        let commitRoute = { (secure: Bool, same: Bool, imk: Bool, ax: Bool, field: Bool) in
            VoiceGlobalCommitPolicy.route(isSecure: secure, focusUnchanged: same, hasInputMethodClient: imk, hasAccessibility: ax, hasTextField: field)
        }
        precondition(commitRoute(false, true, true, false, false) == .inputMethod)
        precondition(commitRoute(false, true, false, true, true) == .accessibility)
        for blocked in [commitRoute(true, true, true, true, true), commitRoute(false, false, true, true, true), commitRoute(false, true, false, false, true), commitRoute(false, true, false, true, false)] {
            if case .clipboardOnly = blocked { continue }
            preconditionFailure("password fields, changed focus and missing targets must keep the text on the clipboard")
        }

        let testBoard = NSPasteboard(name: NSPasteboard.Name("juxu.tests.\(UUID().uuidString)"))
        testBoard.clearContents()
        let richItem = NSPasteboardItem()
        richItem.setString("原来的内容", forType: .string)
        richItem.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.juxu.test"))
        testBoard.writeObjects([richItem])
        let boardSnapshot = VoiceClipboardSnapshot(testBoard)
        testBoard.clearContents(); testBoard.setString("听写文字", forType: .string)
        boardSnapshot.restore(to: testBoard)
        precondition(testBoard.string(forType: .string) == "原来的内容", "the clipboard text is restored")
        precondition(testBoard.data(forType: NSPasteboard.PasteboardType("com.juxu.test")) == Data([1, 2, 3]), "every clipboard type is restored")
        testBoard.releaseGlobally()

        // The HUD meter separates loudness on a dB scale across both laptop and close-up mics.
        let rmsFromDB = { (db: Float) -> Float in pow(10, db / 20) }
        var laptopMeter = VoiceLevelMeter()
        for _ in 0..<10 { _ = laptopMeter.process(rms: rmsFromDB(-41.5), seconds: 0.1) }
        let laptopSteps: [Float] = ([-41.5, -36, -32, -29, -25] as [Float]).map { db in
            var out: Float = 0
            for _ in 0..<4 { out = laptopMeter.process(rms: rmsFromDB(db), seconds: 0.1) }
            return out
        }
        precondition(laptopSteps[0] == 0, "laptop room noise stays at rest")
        precondition(zip(laptopSteps, laptopSteps.dropFirst()).allSatisfy { $0 < $1 }, "louder speech always draws higher on laptop mic")
        precondition(laptopSteps[2] >= 0.35 && laptopSteps[4] >= 0.85, "laptop speech spans a clear visual range")

        var closeMicMeter = VoiceLevelMeter()
        for _ in 0..<10 { _ = closeMicMeter.process(rms: rmsFromDB(-56), seconds: 0.1) }
        precondition(closeMicMeter.process(rms: rmsFromDB(-56), seconds: 0.1) == 0, "quiet room stays at rest")
        for _ in 0..<6 { _ = closeMicMeter.process(rms: rmsFromDB(-12), seconds: 0.1) }
        let closeLoud = closeMicMeter.process(rms: rmsFromDB(-12), seconds: 0.1)
        let closeNormal = closeMicMeter.process(rms: rmsFromDB(-26), seconds: 0.1)
        let closeWhisper = closeMicMeter.process(rms: rmsFromDB(-42), seconds: 0.1)
        precondition(closeWhisper > 0.05 && closeWhisper < closeNormal && closeNormal < closeLoud, "adaptive ceiling separates whisper, normal and loud speech on hot mics")

        // The 11-band speech spectrum analyzer separates frequency bands independently across bars
        // while keeping steady room noise at zero.
        let sampleRate = 16_000.0
        let frameLen = 512
        let makeTone = { (hz: Double, amp: Float) -> [Float] in
            (0..<frameLen).map { i in amp * sin(Float(2 * Double.pi * hz * Double(i) / sampleRate)) }
        }
        let quietFloor = (0..<frameLen).map { i in
            Float(0.008) * sin(Float(Double(i) * 0.13)) // ~-45 dBFS steady rumble
        }
        let spectrum = VoiceSpectrumAnalyzer()
        for _ in 0..<12 { _ = spectrum.processFrame(quietFloor, sampleRate: sampleRate) }
        let quietBars = spectrum.processFrame(quietFloor, sampleRate: sampleRate)
        precondition(quietBars.allSatisfy { $0 < 0.05 }, "steady room noise stays at rest across all 11 bars, got \(quietBars)")

        let lowVowel = makeTone(520, 0.05) // Band 3 -> center bar 5
        let lowBars = spectrum.processFrame(lowVowel, sampleRate: sampleRate)
        precondition(lowBars[5] > 0.5 && lowBars[5] > lowBars[0] * 3 && lowBars[5] > lowBars[10] * 3,
                     "520 Hz vowel peaks on center bar 5, got \(lowBars)")

        let highSibilant = makeTone(3450, 0.04) // Band 9 -> outer bar 0
        let highBars = spectrum.processFrame(highSibilant, sampleRate: sampleRate)
        precondition(highBars[0] > 0.4 && highBars[0] > highBars[5] * 2,
                     "3450 Hz fricative peaks on high-frequency bar 0 rather than center bar 5, got \(highBars)")

        // Hold logic, fed the same synthetic events a listener would deliver. The microphone is never started.
        VoicePreferencesStore.shared.update({ $0.enabled = true; $0.triggerKey = .rightCommand }, persist: false)
        let holdSession = VoiceSessionController.shared
        var holdStarts = 0
        var holdFinishes = 0
        holdSession.startRecordingOverride = { holdStarts += 1 }
        holdSession.finishRecordingOverride = { holdFinishes += 1 }
        let command = { (down: Bool) -> NSEvent in
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x36, keyDown: down)!
            e.type = .flagsChanged
            e.flags = down ? .maskCommand : []
            return NSEvent(cgEvent: e)!
        }
        let keyC: NSEvent = {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
            e.flags = .maskCommand
            return NSEvent(cgEvent: e)!
        }()
        let feed = { (event: NSEvent) in
            _ = holdSession.handleEvent(event, caretRectProvider: { .zero }, windowLevel: nil, contextProvider: { VoiceContext() }, onCommit: { _, _ in })
        }
        // Capture starts on key-down with no delay.
        feed(command(true))
        precondition(holdStarts == 1 && holdSession.isCapturing, "pressing the voice key starts at once")
        feed(command(true))
        precondition(holdStarts == 1, "a repeated key-down does not start twice")
        feed(command(false))
        precondition(holdFinishes == 1 && !holdSession.isCapturing, "release finishes the dictation")
        // A shortcut is dropped immediately and still reaches the app.
        feed(command(true))
        let chordConsumed = holdSession.handleEvent(keyC, caretRectProvider: { .zero }, windowLevel: nil, contextProvider: { VoiceContext() }, onCommit: { _, _ in })
        precondition(!chordConsumed, "right-Command-C still reaches the app")
        precondition(!holdSession.isCapturing, "a shortcut cancels at once")
        feed(command(false))
        precondition(holdStarts == 2 && holdFinishes == 1, "a cancelled shortcut never finishes into a transcription")
        // Adding another modifier is a shortcut too.
        let leftShift: NSEvent = {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x38, keyDown: true)!
            e.type = .flagsChanged
            e.flags = [.maskCommand, .maskShift]
            return NSEvent(cgEvent: e)!
        }()
        feed(command(true)); feed(leftShift)
        precondition(!holdSession.isCapturing, "another modifier cancels at once")
        feed(command(false))
        precondition(holdStarts == 3 && holdFinishes == 1, "the release after a cancel does nothing")
        // Without the global key, leaving the app cancels; with it, the dictation continues.
        feed(command(true)); holdSession.handleDeactivate()
        precondition(!holdSession.isCapturing, "without the global key, deactivation cancels as before"); feed(command(false))
        VoiceGlobalHotkeyController.testingForceListening = true
        precondition(VoiceGlobalHotkeyController.isListening)
        feed(command(true)); holdSession.handleDeactivate()
        precondition(holdSession.isCapturing, "with the global key, switching app does not cancel"); feed(command(false))
        precondition(holdStarts == 5 && holdFinishes == 2, "one press is exactly one dictation")
        VoiceGlobalHotkeyController.testingForceListening = false
        holdSession.startRecordingOverride = nil
        holdSession.finishRecordingOverride = nil
        VoicePreferencesStore.shared.update({ $0.enabled = false }, persist: false)
        precondition(!VoiceSessionController.isLoaded && !VoiceGlobalHotkeyController.isLoaded, "turning voice off releases the listener")

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

        // 8. Verify SettingsWindow handles Cmd+W close shortcut without requiring a main menu
        func makeKeyEvent(
            type: NSEvent.EventType = .keyDown,
            chars: String,
            ignoringModifiers: String,
            modifiers: NSEvent.ModifierFlags,
            keyCode: UInt16 = 13
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: ignoringModifiers,
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        let cmdW = makeKeyEvent(chars: "w", ignoringModifiers: "w", modifiers: .command)
        let cmdCapsW = makeKeyEvent(chars: "W", ignoringModifiers: "W", modifiers: [.command, .capsLock])
        let cmdNonLatinW = makeKeyEvent(chars: "w", ignoringModifiers: "ц", modifiers: .command)
        let cmdShiftW = makeKeyEvent(chars: "W", ignoringModifiers: "w", modifiers: [.command, .shift])
        let cmdOptW = makeKeyEvent(chars: "∑", ignoringModifiers: "w", modifiers: [.command, .option])
        let cmdCtrlW = makeKeyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command, .control])
        let plainW = makeKeyEvent(chars: "w", ignoringModifiers: "w", modifiers: [])
        let cmdA = makeKeyEvent(chars: "a", ignoringModifiers: "a", modifiers: .command, keyCode: 0)
        let cmdWKeyUp = makeKeyEvent(type: .keyUp, chars: "w", ignoringModifiers: "w", modifiers: .command)

        assert(SettingsWindow.isCloseWindowShortcut(cmdW))
        assert(SettingsWindow.isCloseWindowShortcut(cmdCapsW))
        assert(SettingsWindow.isCloseWindowShortcut(cmdNonLatinW))
        assert(!SettingsWindow.isCloseWindowShortcut(cmdShiftW))
        assert(!SettingsWindow.isCloseWindowShortcut(cmdOptW))
        assert(!SettingsWindow.isCloseWindowShortcut(cmdCtrlW))
        assert(!SettingsWindow.isCloseWindowShortcut(plainW))
        assert(!SettingsWindow.isCloseWindowShortcut(cmdA))
        assert(!SettingsWindow.isCloseWindowShortcut(cmdWKeyUp))

        final class CloseSpy: NSObject, NSWindowDelegate {
            var closeCount = 0
            func windowWillClose(_ notification: Notification) {
                closeCount += 1
            }
        }
        _ = NSApplication.shared
        let spy = CloseSpy()
        let settingsWin = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        settingsWin.isReleasedWhenClosed = false
        settingsWin.contentView = NSHostingView(rootView: SettingsRootView(bridge: bridge))
        settingsWin.delegate = spy
        assert(!settingsWin.performKeyEquivalent(with: cmdShiftW))
        assert(!settingsWin.performKeyEquivalent(with: plainW))
        assert(!settingsWin.performKeyEquivalent(with: cmdA))
        assert(spy.closeCount == 0)
        assert(settingsWin.performKeyEquivalent(with: cmdW))
        assert(spy.closeCount == 1, "Expected Cmd+W to close SettingsWindow, got closeCount=\(spy.closeCount)")

        // 9. Verify Typeless-style VoiceContextCapture policy, JSON schema, blacklist, and UTF-16 cursor slicing
        let defaultOpts = VoiceContextCaptureOptions()
        assert(VoiceContextPolicy.isHardBlocked(bundleId: "com.1password.1password"))
        assert(VoiceContextPolicy.isHardBlocked(bundleId: "com.apple.Passwords"))
        assert(!VoiceContextPolicy.isHardBlocked(bundleId: "com.tinyspeck.slackmacgap"))

        assert(VoiceContextPolicy.blacklistReason(bundleId: "com.tencent.xinWeChat", webURL: nil, options: defaultOpts) == "app_blacklist:com.tencent.xinWeChat")
        assert(VoiceContextPolicy.blacklistReason(bundleId: "com.microsoft.Excel", webURL: nil, options: defaultOpts) == "app_blacklist:com.microsoft.Excel")
        assert(VoiceContextPolicy.blacklistReason(bundleId: "com.google.Chrome", webURL: "https://docs.google.com/document/d/abc123/edit", options: defaultOpts)?.hasPrefix("url_blacklist:") == true)
        assert(VoiceContextPolicy.blacklistReason(bundleId: "com.google.Chrome", webURL: "https://github.com/nameoverflow/juxu", options: defaultOpts) == nil)
        assert(VoiceContextPolicy.blacklistReason(bundleId: "com.tinyspeck.slackmacgap", webURL: nil, options: defaultOpts) == nil)

        var noBlacklistOpts = VoiceContextCaptureOptions()
        noBlacklistOpts.respectBlacklist = false
        assert(VoiceContextPolicy.blacklistReason(bundleId: "com.tencent.xinWeChat", webURL: nil, options: noBlacklistOpts) == nil)
        // Password managers remain hard-blocked even when content blacklist is disabled.
        assert(VoiceContextPolicy.blacklistReason(bundleId: "com.1password.1password", webURL: nil, options: noBlacklistOpts) == "password_manager:com.1password.1password")

        assert(VoiceContextPolicy.shouldClearNotionWebAreaCursor(isWebBrowser: true, webURL: "https://www.notion.so/page-1", role: "AXWebArea"))
        assert(!VoiceContextPolicy.shouldClearNotionWebAreaCursor(isWebBrowser: true, webURL: "https://www.notion.so/page-1", role: "AXTextArea"))
        assert(!VoiceContextPolicy.shouldClearNotionWebAreaCursor(isWebBrowser: true, webURL: "https://github.com", role: "AXWebArea"))

        // Safe UTF-16 cursor slicing with CJK + emoji surrogate pairs
        let mixedText = "你好😀世界abc"
        // "你好" = 2 UTF-16, "😀" = 2 UTF-16, "世界" = 2 UTF-16 -> caret at UTF-16 offset 4 is right after "你好😀"
        let sliced = VoiceContextPolicy.sliceCursorContext(
            fullText: mixedText,
            selectionLocationUTF16: 4,
            selectionLengthUTF16: 2,
            maxBeforeChars: 10,
            maxAfterChars: 10,
            maxSelectedChars: 10
        )
        assert(sliced.before == "你好😀", "Expected before='你好😀', got '\(sliced.before)'")
        assert(sliced.selected == "世界", "Expected selected='世界', got '\(sliced.selected)'")
        assert(sliced.after == "abc", "Expected after='abc', got '\(sliced.after)'")

        assert(VoiceContextPolicy.normalizeURLCandidate("github.com/nameoverflow/juxu") == "https://github.com/nameoverflow/juxu")
        assert(VoiceContextPolicy.normalizeURLCandidate("https://example.com/a?b=1") == "https://example.com/a?b=1")
        assert(VoiceContextPolicy.normalizeURLCandidate("just some text") == nil)

        let sampleCaptured = VoiceCapturedContext(
            activeApplication: .init(
                appName: "Slack",
                appIdentifier: "com.tinyspeck.slackmacgap",
                windowTitle: "#engineering",
                webURL: nil,
                appType: "electron_app",
                isWebBrowser: false,
                appMetadata: .init(processId: 1234, appPath: "/Applications/Slack.app"),
                visibleScreenContent: "Alice: check CI"
            ),
            textInsertionPoint: .init(
                inputAreaType: "rich_text",
                accessibilityRole: "AXTextArea",
                accessibilitySubrole: nil,
                inputCapabilities: .init(isEditable: true, isSecure: false),
                cursorState: .init(
                    cursorPosition: 10,
                    selectionLength: 0,
                    hasTextSelected: false,
                    selectedText: "",
                    textBeforeCursor: "Let me check ",
                    textAfterCursor: "now"
                ),
                surroundingContext: .init(
                    textBeforeInputArea: "Channel: #engineering",
                    textAfterInputArea: ""
                )
            ),
            contextMetadata: .init(
                isOwnApplication: false,
                isAccessibilityTrusted: true,
                enhancedUIEnabled: true,
                isBlacklisted: false,
                blacklistReason: nil,
                isSecureInput: false,
                timedOutVisible: false,
                timedOutSurrounding: false,
                elapsedMs: 12,
                captureTimestamp: "2026-11-23T09:50:00Z"
            )
        )
        let sampleJSON = sampleCaptured.prettyJSON()
        assert(sampleJSON.contains("\"active_application\""))
        assert(sampleJSON.contains("\"visible_screen_content\""))
        assert(sampleJSON.contains("\"text_before_cursor\""))
        assert(sampleJSON.contains("\"enhanced_ui_enabled\""))
        let decodedCaptured = try! JSONDecoder().decode(VoiceCapturedContext.self, from: Data(sampleJSON.utf8))
        assert(decodedCaptured == sampleCaptured)

        let mergedCtx = VoiceContext(personalVocabulary: ["Juxu"]).merged(with: sampleCaptured)
        assert(mergedCtx.bundleIdentifier == "com.tinyspeck.slackmacgap")
        assert(mergedCtx.appName == "Slack")
        assert(mergedCtx.beforeContext == "Let me check ")
        assert(mergedCtx.afterContext == "now")
        assert(mergedCtx.visibleScreenText == "Alice: check CI")

        print("✓ All Swift <-> Rust C ABI bridge, pure-AppKit non-wrapping candidate bar, Cangjie, Bayesian typo, SettingsWindow Cmd+W, VoiceContextCapture & macOS Voice MVP tests passed!")
    }
}
