import AppKit

/// What each recogniser and the polish model receive from the captured context.
/// Uses `precondition` because the suite is built with `-O`, which removes `assert`.
enum VoiceContextPromptTests {
    @MainActor
    final class RecordingEngine: VoiceASREngine {
        var contexts: [VoiceContext] = []
        func beginSession() {}
        func endSession() {}
        func prepare() async throws {}
        func transcribe(wavData: Data, language: String, timeout: TimeInterval, isFinal: Bool) async throws -> String { "" }
        func updateContext(_ context: VoiceContext) { contexts.append(context) }
        func release() {}
    }

    static func captured(
        app: String = "Slack",
        bundle: String = "com.tinyspeck.slackmacgap",
        title: String = "#engineering — Slack",
        url: String? = nil,
        screen: String? = "Alice: VoiceContextCapture 的 PR #42 已经合进 juxu-qwen-asr 了",
        before: String = "我看了一下 WhisperKit 和 Qwen3-ASR 的对比，",
        after: String = "明天再说",
        selected: String = "",
        above: String = "Bob: 你试过 MLX 吗",
        below: String = "",
        secure: Bool = false,
        blacklisted: Bool = false
    ) -> VoiceCapturedContext {
        VoiceCapturedContext(
            activeApplication: .init(
                appName: app,
                appIdentifier: bundle,
                windowTitle: title,
                webURL: url,
                appType: "electron_app",
                isWebBrowser: url != nil,
                appMetadata: .init(processId: 4321, appPath: nil),
                visibleScreenContent: screen
            ),
            textInsertionPoint: .init(
                inputAreaType: "rich_text",
                accessibilityRole: "AXTextArea",
                accessibilitySubrole: nil,
                inputCapabilities: .init(isEditable: true, isSecure: secure),
                cursorState: .init(
                    cursorPosition: before.count,
                    selectionLength: selected.count,
                    hasTextSelected: !selected.isEmpty,
                    selectedText: selected,
                    textBeforeCursor: before,
                    textAfterCursor: after
                ),
                surroundingContext: .init(textBeforeInputArea: above, textAfterInputArea: below)
            ),
            contextMetadata: .init(
                isAccessibilityTrusted: true,
                isBlacklisted: blacklisted,
                blacklistReason: blacklisted ? "app_blacklist:\(bundle)" : nil,
                isSecureInput: secure
            )
        )
    }

    /// Runs main-actor async work from the synchronous test entry point.
    @MainActor
    static func runAsync(timeout: TimeInterval = 5, _ body: @escaping @MainActor () async -> Void) {
        final class Flag { var done = false }
        let flag = Flag()
        Task { @MainActor in
            await body()
            flag.done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        precondition(flag.done, "async test body did not finish within \(timeout) s")
    }

    @MainActor
    static func run() {
        textHelpers()
        keyTerms()
        recognitionContexts()
        privacy()
        polish()
        engines()
        session()
        preview()
        print("✓ Voice ASR & polish context tests passed")
    }

    static func textHelpers() {
        precondition(VoiceContextText.clean("a\u{FFFC}b  \t c\n\n\n\nd\u{200B}") == "ab c\n\nd")
        precondition(VoiceContextText.singleLine("  第一行\n第二行  ") == "第一行 第二行")
        precondition(VoiceContextText.tail("短文本", 10) == "短文本")
        let tail = VoiceContextText.tail("前面很长很长的一段话。后面才是重点内容", 12)
        precondition(tail == "后面才是重点内容", "tail starts after a sentence boundary: \(tail)")
        let head = VoiceContextText.head("hello wonderful world of speech", 18)
        precondition(head == "hello wonderful", "head ends at a word boundary: \(head)")
        precondition(VoiceContextText.sanitizedURL("https://github.com/nameoverflow/juxu/pull/16?token=abc#top") == "https://github.com/nameoverflow/juxu/pull/16")
        precondition(VoiceContextText.sanitizedURL("not a url") == nil)
        let titled = VoiceContext(appName: "Slack", windowTitle: "#engineering — Slack")
        precondition(VoiceContextText.windowTitle(titled, limit: 50) == "#engineering")
        precondition(VoiceContextText.windowTitle(VoiceContext(appName: "Notes", windowTitle: "Notes"), limit: 50).isEmpty)
    }

    static func keyTerms() {
        let terms = VoiceContextTerms.extract(
            from: [("Please ask Alice whether VoiceContextCapture in juxu-qwen-asr fixed PR42 for GitHub, then check the check list", 1)],
            limit: 10
        )
        precondition(terms.prefix(3).contains("VoiceContextCapture") && terms.contains("juxu-qwen-asr") && terms.contains("PR42"), "identifiers rank first: \(terms)")
        precondition(terms.contains("Alice") && terms.contains("GitHub"), "proper nouns are kept: \(terms)")
        precondition(!terms.contains("Please") && !terms.contains("then"), "stopwords are dropped: \(terms)")
        precondition(terms.contains("check") && !terms.contains("list"), "a plain lowercase word needs to repeat: \(terms)")
        let quoted = VoiceContextTerms.extract(from: [("我们在《句序输入法》里讨论「语音识别」", 1)], limit: 5)
        precondition(quoted.contains("句序输入法") && quoted.contains("语音识别"), "quoted CJK names are terms: \(quoted)")
        let excluded = VoiceContextTerms.extract(from: [("Juxu and MLX", 3)], excluding: ["juxu"], limit: 5)
        precondition(excluded == ["MLX"], "vocabulary entries are not repeated as terms: \(excluded)")
        let weighted = VoiceContextTerms.extract(from: [("Zeta", 1), ("Omega", 3)], limit: 2)
        precondition(weighted == ["Omega", "Zeta"], "cursor and window terms outrank screen terms: \(weighted)")
    }

    static func recognitionContexts() {
        let vocab = ["句序", "Typeless", "RWKV-7"]
        let ctx = VoiceContext(personalVocabulary: vocab).merged(with: captured())

        let qwen = VoiceASRContextBuilder.recognitionContext(ctx, target: .qwen, language: "zh") ?? ""
        precondition(qwen.count <= VoiceASRContextTarget.qwen.characterBudget)
        precondition(qwen.hasPrefix("#engineering\n"), "Qwen gets the window title: \(qwen)")
        precondition(qwen.contains("句序 Typeless RWKV-7"), "Qwen gets the vocabulary first: \(qwen)")
        precondition(qwen.contains("WhisperKit") && qwen.contains("MLX"), "Qwen gets cursor and surrounding terms: \(qwen)")
        precondition(!qwen.contains("VoiceContextCapture") && !qwen.contains("Alice"), "Qwen gets no terms from the whole screen: \(qwen)")
        precondition(qwen.hasSuffix("我看了一下 WhisperKit 和 Qwen3-ASR 的对比，"), "Qwen gets the text before the cursor: \(qwen)")

        let whisper = VoiceASRContextBuilder.recognitionContext(ctx, target: .whisper, language: "zh") ?? ""
        precondition(whisper.count <= 120, "Whisper prompt stays short: \(whisper.count)")
        precondition(whisper.hasPrefix("句序、Typeless、RWKV-7、"), "Whisper gets a glossary sentence: \(whisper)")
        precondition(whisper.contains("。") && whisper.hasSuffix("的对比，"), "Whisper prompt ends with the text before the cursor: \(whisper)")
        let english = VoiceASRContextBuilder.recognitionContext(
            VoiceContext(beforeContext: "Thanks for the review.", personalVocabulary: ["Juxu", "MLX"]),
            target: .whisper,
            language: "en"
        )
        precondition(english == "Juxu, MLX. Thanks for the review.", "English prompts use English punctuation: \(english ?? "nil")")
        precondition(VoiceASRContextBuilder.recognitionContext(VoiceContext(), target: .whisper, language: "zh") == nil)

        // A long screen and a long vocabulary still stay inside every budget.
        let longScreen = String(repeating: "ProjectAlpha 的 build-42 日志 ", count: 900)
        let longVocab = (0..<200).map { "词条\($0)" }
        let big = VoiceContext(personalVocabulary: longVocab).merged(
            with: captured(screen: longScreen, before: String(repeating: "很长的前文。", count: 400))
        )
        for target in [VoiceASRContextTarget.qwen, .whisper, .cloud(model: "whisper-large-v3-turbo"), .cloud(model: "gpt-4o-mini-transcribe")] {
            let text = VoiceASRContextBuilder.recognitionContext(big, target: target, language: "zh") ?? ""
            precondition(!text.isEmpty && text.count <= target.characterBudget, "\(target) stays within \(target.characterBudget): \(text.count)")
        }
        precondition(VoiceASRContextTarget.cloud(model: "gpt-4o-mini-transcribe").characterBudget == 400)
        precondition(VoiceASRContextTarget.cloud(model: "whisper-large-v3-turbo").characterBudget == 160)

        // Unrelated words on screen pulled Qwen3-ASR towards them in testing, so no recogniser prompt reads the screen.
        let noisy = VoiceContext(personalVocabulary: ["句序"]).merged(with: captured(screen: "Kubernetes Terraform Grafana Prometheus"))
        for target in [VoiceASRContextTarget.qwen, .whisper, .cloud(model: "gpt-4o-mini-transcribe")] {
            let text = VoiceASRContextBuilder.recognitionContext(noisy, target: target, language: "zh") ?? ""
            precondition(!text.contains("Kubernetes") && !text.contains("Grafana"), "\(target) ignores screen-only terms: \(text)")
        }
        precondition(VoiceASRContextBuilder.contextualStrings(noisy).contains("Kubernetes"), "Apple Speech phrases still read the screen")
        precondition(VoicePolishContextBuilder.referenceBlock(noisy, budget: .compact).contains("Kubernetes"), "compact polish still reads the screen")

        let phrases = VoiceASRContextBuilder.contextualStrings(ctx)
        precondition(Array(phrases.prefix(3)) == vocab, "Apple Speech gets the vocabulary first: \(phrases)")
        precondition(phrases.contains("VoiceContextCapture") && phrases.contains("MLX"), "then terms on screen: \(phrases)")
        let manyPhrases = VoiceASRContextBuilder.contextualStrings(big)
        precondition(manyPhrases.count <= 100 && manyPhrases.allSatisfy { $0.count <= 40 })

        precondition(VoiceASRContextBuilder.isPromptEcho("句序、Typeless、RWKV-7。", prompt: whisper))
        precondition(!VoiceASRContextBuilder.isPromptEcho("句序", prompt: whisper), "a single short term is real speech")
        precondition(!VoiceASRContextBuilder.isPromptEcho("我们明天下午开会讨论一下", prompt: whisper))
        precondition(!VoiceASRContextBuilder.isPromptEcho("anything at all", prompt: nil))
    }

    static func privacy() {
        let vocab = ["句序"]
        let targets = [VoiceASRContextTarget.qwen, .whisper, .cloud(model: "gpt-4o-mini-transcribe")]
        func allPolish(_ ctx: VoiceContext, _ budget: VoicePolishContextBudget) -> String {
            VoicePromptBuilder.polishMessages(rawTranscript: "测试", toneMode: .autoByApp, context: ctx, budget: budget)
                .compactMap { $0["content"] }.joined(separator: "\n")
        }

        // Secure fields and password managers: nothing but the vocabulary leaves the input method.
        let everything = ["WhisperKit", "VoiceContextCapture", "engineering", "明天再说", "MLX", "Alice"]
        func leaks(_ text: String?, _ words: [String]) -> [String] {
            guard let text else { return [] }
            return words.filter { text.contains($0) }
        }
        let hard: [(String, VoiceContext)] = [
            ("secure field", VoiceContext(personalVocabulary: vocab).merged(with: captured(secure: true))),
            ("password manager", VoiceContext(
                bundleIdentifier: "com.1password.1password",
                windowTitle: "engineering",
                beforeContext: "WhisperKit VoiceContextCapture",
                afterContext: "明天再说",
                personalVocabulary: vocab
            )),
        ]
        for (name, ctx) in hard {
            precondition(!ctx.allowsCursorContext && !ctx.allowsScreenContext, "\(name) is fully gated")
            for target in targets {
                let text = VoiceASRContextBuilder.recognitionContext(ctx, target: target, language: "zh")
                precondition(leaks(text, everything).isEmpty, "\(name) leaks \(leaks(text, everything)) to \(target)")
                precondition(text?.contains("句序") == true, "\(name) still sends the vocabulary to \(target)")
            }
            precondition(VoiceASRContextBuilder.contextualStrings(ctx) == vocab, "\(name): Apple Speech gets only the vocabulary")
            for budget in [VoicePolishContextBudget.full, .compact] {
                let all = allPolish(ctx, budget)
                precondition(leaks(all, everything).isEmpty, "\(name) leaks \(leaks(all, everything)) to polish (\(budget))")
                precondition(all.contains("句序"), "\(name) keeps the vocabulary in polish")
            }
        }

        // Blacklisted apps and pages: the cursor state is still read there, so window, cursor text and
        // selection stay; the URL, the surrounding text and the screen do not.
        let screenOnly = ["VoiceContextCapture", "Alice", "MLX", "Bob", "docs.google.com"]
        let soft: [(String, VoiceContext)] = [
            ("blacklisted capture", VoiceContext(personalVocabulary: vocab).merged(
                with: captured(url: "https://docs.google.com/document/d/abc", blacklisted: true)
            )),
            ("blacklisted before capture", VoiceContext(
                bundleIdentifier: "com.tencent.xinWeChat",
                windowTitle: "#engineering",
                webURL: "https://docs.google.com/document/d/abc",
                beforeContext: "我看了一下 WhisperKit 的对比，",
                afterContext: "明天再说",
                surroundingBefore: "Bob: MLX",
                visibleScreenText: "Alice: VoiceContextCapture",
                personalVocabulary: vocab
            ).restricted(true)),
        ]
        for (name, ctx) in soft {
            precondition(ctx.allowsCursorContext && !ctx.allowsScreenContext, "\(name) gates only the screen")
            for target in targets {
                let text = VoiceASRContextBuilder.recognitionContext(ctx, target: target, language: "zh") ?? ""
                precondition(leaks(text, screenOnly).isEmpty, "\(name) leaks \(leaks(text, screenOnly)) to \(target)")
                precondition(text.contains("句序") && text.contains("WhisperKit"), "\(name) keeps vocabulary and cursor text for \(target): \(text)")
            }
            let qwen = VoiceASRContextBuilder.recognitionContext(ctx, target: .qwen, language: "zh") ?? ""
            precondition(qwen.hasPrefix("#engineering"), "\(name) keeps the window title: \(qwen)")
            let phrases = VoiceASRContextBuilder.contextualStrings(ctx)
            precondition(leaks(phrases.joined(separator: " "), screenOnly).isEmpty && phrases.contains("WhisperKit"), "\(name): \(phrases)")
            for budget in [VoicePolishContextBudget.full, .compact] {
                let all = allPolish(ctx, budget)
                precondition(leaks(all, screenOnly).isEmpty, "\(name) leaks \(leaks(all, screenOnly)) to polish (\(budget))")
                precondition(all.contains("光标前文：") && all.contains("WhisperKit") && all.contains("光标后文：明天再说"), "\(name) keeps cursor text in polish (\(budget))")
                precondition(all.contains("#engineering") && !all.contains("网址"), "\(name) keeps the window, not the URL (\(budget))")
            }
        }

        // The selection is sent on purpose by speak-to-edit, so a blacklisted app keeps it; a secure field never does.
        let softSelected = VoiceContext(selectedText: "原文", personalVocabulary: vocab).merged(with: captured(blacklisted: true))
        precondition(softSelected.promptSafe().selectedText == "原文")
        let secureSelected = VoiceContext(selectedText: "密码", personalVocabulary: vocab).merged(with: captured(secure: true))
        precondition(secureSelected.promptSafe().selectedText == nil)
        let secureEdit = VoicePromptBuilder.polishMessages(rawTranscript: "改一下", toneMode: .casual, context: secureSelected)
        precondition(!(secureEdit.last?["content"]?.contains("密码") ?? true))

        precondition(VoiceContext().restricted(true).merged(with: captured()).policyRestricted, "merging keeps the blacklist mark")
        precondition(VoiceContext().merged(with: captured()).allowsScreenContext)
    }

    static func polish() {
        let ctx = VoiceContext(bundleIdentifier: "com.tinyspeck.slackmacgap", personalVocabulary: ["句序"]).merged(
            with: captured(
                url: "https://app.slack.com/client/T1/C2?token=secret#msg",
                screen: "Alice: VoiceContextCapture 的 PR #42 已经合进 juxu-qwen-asr 了\n明天再说\n"
                    + String(repeating: "重复的一行内容 MLX\n", count: 3)
                    + (0..<400).map { "第\($0)条历史消息" }.joined(separator: "\n"),
                above: "Bob: 你试过 MLX 吗"
            )
        )
        let full = VoicePromptBuilder.polishMessages(rawTranscript: "嗯那个我觉得可以", toneMode: .autoByApp, context: ctx, budget: .full)
        let fullSystem = full[0]["content"] ?? ""
        precondition(full[1]["content"] == "嗯那个我觉得可以", "the transcript stays the only user turn")
        precondition(fullSystem.contains("【参考上下文】") && fullSystem.contains("【参考上下文结束】"))
        precondition(fullSystem.contains("6. 【参考上下文】") && fullSystem.contains("不要复述"), "the model is told not to repeat the screen")
        precondition(fullSystem.contains("应用：Slack · #engineering"), fullSystem)
        precondition(fullSystem.contains("网址：https://app.slack.com/client/T1/C2") && !fullSystem.contains("secret"), "URL without query")
        precondition(fullSystem.contains("光标前文：我看了一下 WhisperKit") && fullSystem.contains("光标后文：明天再说"))
        precondition(fullSystem.contains("输入框上方：Bob: 你试过 MLX 吗"))
        precondition(fullSystem.contains("屏幕可见内容（节选）：\nAlice: VoiceContextCapture"))
        precondition(!fullSystem.contains("\n明天再说\n"), "screen lines the cursor text already shows are skipped")
        precondition(fullSystem.components(separatedBy: "重复的一行内容 MLX").count == 2, "repeated screen lines appear once")
        precondition(fullSystem.contains("第1条历史消息") && !fullSystem.contains("第399条历史消息"), "the screen excerpt is capped")
        precondition(fullSystem.contains("句序"))

        let compact = VoicePromptBuilder.polishMessages(rawTranscript: "嗯那个我觉得可以", toneMode: .autoByApp, context: ctx, budget: .compact)
        let compactSystem = compact[0]["content"] ?? ""
        precondition(!compactSystem.contains("网址") && !compactSystem.contains("屏幕可见内容"), "small models get no URL or raw screen")
        precondition(compactSystem.contains("屏幕关键词：") && compactSystem.contains("VoiceContextCapture"), compactSystem)
        precondition(compactSystem.contains("光标前文："))
        let compactBlock = VoicePolishContextBuilder.referenceBlock(ctx, budget: .compact)
        precondition(compactBlock.count <= 400, "compact context fits a 2K window next to the rules: \(compactBlock.count)")
        precondition(compactSystem.count < fullSystem.count / 2)

        // A long cursor text is cut for small models.
        let longBefore = VoiceContext().merged(with: captured(before: String(repeating: "前文内容很多。", count: 200)))
        let longBlock = VoicePolishContextBuilder.referenceBlock(longBefore, budget: .compact)
        let beforeLine = longBlock.split(separator: "\n").first { $0.hasPrefix("光标前文：") } ?? ""
        precondition(beforeLine.count <= "光标前文：".count + 80)

        // Speak-to-edit keeps its shape and only adds the app line.
        let edit = VoicePromptBuilder.polishMessages(
            rawTranscript: "翻成英文",
            toneMode: .professional,
            context: VoiceContext(selectedText: "你好世界").merged(with: captured())
        )
        precondition(edit[1]["content"]?.contains("你好世界") == true && edit[1]["content"]?.contains("翻成英文") == true)
        precondition(edit[0]["content"]?.contains("应用：Slack · #engineering") == true)
        precondition(edit[0]["content"]?.contains("WhisperKit") == false, "editing does not need the cursor text")

        // Without any context the prompt has no reference section.
        let bare = VoicePromptBuilder.polishMessages(rawTranscript: "测试", toneMode: .casual, context: VoiceContext())
        precondition(!(bare[0]["content"]?.contains("参考上下文") ?? true))
    }

    @MainActor
    static func engines() {
        let ctx = VoiceContext(personalVocabulary: ["句序"]).merged(with: captured())
        let header = VoiceQwenHelperManager.requestHeader(id: 7, isFinal: true, sampleCount: 16_000, language: "zh", context: "句序 MLX")
        precondition(header["context"] as? String == "句序 MLX" && header["kind"] as? String == "final" && header["language"] as? String == "Chinese")
        precondition(VoiceQwenHelperManager.requestHeader(id: 8, isFinal: false, sampleCount: 1, language: "auto", context: nil)["context"] == nil)

        let qwen = VoiceQwenHelperManager.shared
        qwen.configure(modelDirectory: "/nonexistent", context: nil)
        precondition(qwen.currentContext == nil)
        qwen.updateContext(ctx)
        precondition(qwen.currentContext == VoiceASRContextBuilder.recognitionContext(ctx, target: .qwen, language: ""))
        precondition(qwen.currentContext?.contains("#engineering") == true)
        qwen.updateContext(VoiceContext())
        precondition(qwen.currentContext == nil, "a new dictation does not inherit the last one's context")
        VoiceQwenHelperManager.unload()

        let whisper = VoiceWhisperServerManager.shared
        whisper.configure(binaryPath: "/nonexistent", modelPath: "/nonexistent", language: "zh")
        whisper.updateContext(ctx)
        let prompt = whisper.prompt ?? ""
        precondition(prompt.hasPrefix("句序、") && prompt.count <= 120, prompt)
        let body = VoiceMultipartBuilder.buildAudioTranscriptionBody(
            boundary: "B", wavData: Data(), model: "whisper", language: "zh", prompt: prompt
        )
        precondition(String(decoding: body, as: UTF8.self).contains("name=\"prompt\"\r\n\r\n\(prompt)\r\n"))
        VoiceWhisperServerManager.unload()
    }

    @MainActor
    static func session() {
        let session = VoiceSessionController.shared
        let engine = RecordingEngine()

        // The capture lands mid-recording: the engine listening already is re-biased with the merged context.
        session.activeContext = VoiceContext(bundleIdentifier: "com.tinyspeck.slackmacgap", personalVocabulary: ["句序"])
        session.activeEngine = engine
        session.applyCapturedContext(captured())
        precondition(engine.contexts.count == 1)
        let pushed = engine.contexts[0]
        precondition(pushed.windowTitle == "#engineering — Slack" && pushed.beforeContext?.contains("WhisperKit") == true)
        precondition(pushed.personalVocabulary == ["句序"], "the vocabulary survives the merge")
        precondition(VoiceASRContextBuilder.recognitionContext(pushed, target: .qwen, language: "zh")?.contains("#engineering") == true)

        // A secure field found by the capture reaches the engine without screen text.
        engine.contexts.removeAll()
        session.activeContext = VoiceContext(personalVocabulary: ["句序"])
        session.applyCapturedContext(captured(secure: true))
        let securePrompt = VoiceASRContextBuilder.recognitionContext(engine.contexts[0], target: .whisper, language: "zh") ?? ""
        precondition(securePrompt == "句序。", "secure fields bias with the vocabulary only: \(securePrompt)")

        // The final pass waits briefly for a capture that is still running, and never longer than the grace.
        session.activeEngine = nil
        session.activeContext = VoiceContext(personalVocabulary: ["句序"])
        session.beginPendingContextCaptureForTesting()
        runAsync {
            let start = Date()
            await session.awaitContextCapture(maxWait: 0.2)
            let waited = Date().timeIntervalSince(start)
            precondition(waited >= 0.15 && waited < 0.6, "a capture that never lands costs at most the grace: \(waited)")
        }
        session.beginPendingContextCaptureForTesting()
        runAsync {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { session.finishPendingContextCaptureForTesting(captured()) }
            }
            let start = Date()
            await session.awaitContextCapture(maxWait: 1.0)
            let waited = Date().timeIntervalSince(start)
            precondition(waited < 0.5, "the wait ends as soon as the capture lands: \(waited)")
            precondition(session.activeContext.windowTitle == "#engineering — Slack", "the final pass reads the merged context")
        }
        runAsync {
            let start = Date()
            await session.awaitContextCapture(maxWait: 1.0)
            precondition(Date().timeIntervalSince(start) < 0.05, "nothing pending, nothing to wait for")
        }
        precondition(VoiceSessionController.contextCaptureGrace <= 0.3, "release is never held up for long")
        VoiceSessionController.unload()
    }

    static func preview() {
        let ctx = VoiceContext(personalVocabulary: ["句序", "Typeless"]).merged(with: captured())
        var prefs = VoicePreferences()
        prefs.providerMode = .local
        prefs.localASRPreset = .qwen3ASR
        prefs.localLLMPreset = .none
        let qwen = VoiceContextPromptPreview.build(context: ctx, prefs: prefs)
        precondition(qwen.asrTargetLabel.contains("Qwen3-ASR") && qwen.asrContext.contains("#engineering") && qwen.asrContext.contains("Typeless"))
        precondition(qwen.polishBudgetLabel.contains("未开启") && qwen.polishContext.contains("【参考上下文】"))

        prefs.localASRPreset = .whisperTurbo
        let whisper = VoiceContextPromptPreview.build(context: ctx, prefs: prefs)
        precondition(whisper.asrTargetLabel.contains("Whisper") && whisper.asrContext.count <= 120)

        prefs.localASRPreset = .appleSpeech
        let apple = VoiceContextPromptPreview.build(context: ctx, prefs: prefs)
        precondition(apple.asrTargetLabel.contains("Apple Speech") && apple.asrContext.contains("VoiceContextCapture"))

        prefs.providerMode = .cloudBYOK
        prefs.cloudPreset = .openai
        prefs.cloudPolishEnabled = true
        let cloud = VoiceContextPromptPreview.build(context: ctx, prefs: prefs)
        precondition(cloud.asrTargetLabel.contains("400") && cloud.polishBudgetLabel.contains("full") && !cloud.polishBudgetLabel.contains("未开启"))
    }
}
