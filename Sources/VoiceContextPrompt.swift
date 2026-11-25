import Foundation

// Turns the captured `VoiceContext` into what each recogniser and the polish model may see.
// Every builder starts from `promptSafe()`: a secure field or a password manager sends nothing but the
// personal vocabulary, and a blacklisted app or page sends no screen or surrounding text.

// MARK: - Privacy gate

extension VoiceContext {
    /// A secure text field or a password manager: not even the selection may leave the input method.
    public var isSecureOrHardBlocked: Bool {
        if captured?.contextMetadata.isSecureInput == true { return true }
        for bid in [bundleIdentifier, captured?.activeApplication.appIdentifier] {
            if let bid, !bid.isEmpty, VoiceContextPolicy.isHardBlocked(bundleId: bid) { return true }
        }
        return false
    }

    /// Whether the window title, the selection and the text around the cursor may leave the input method.
    public var allowsCursorContext: Bool { !isSecureOrHardBlocked }

    /// Whether the URL, the text around the input area and the visible screen may leave the input method.
    /// The blacklist exists to keep those large reads away from some apps and pages; the cursor state is still read there.
    public var allowsScreenContext: Bool {
        allowsCursorContext && !policyRestricted && captured?.contextMetadata.isBlacklisted != true
    }

    /// The context with everything the privacy gate forbids removed.
    public func promptSafe() -> VoiceContext {
        if allowsScreenContext { return self }
        let cursor = allowsCursorContext
        return VoiceContext(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: cursor ? windowTitle : nil,
            selectedText: cursor ? selectedText : nil,
            beforeContext: cursor ? beforeContext : nil,
            afterContext: cursor ? afterContext : nil,
            personalVocabulary: personalVocabulary,
            captured: nil,
            policyRestricted: true
        )
    }

    /// The same context, marked as blacklisted when `restricted` is true.
    public func restricted(_ restricted: Bool) -> VoiceContext {
        guard restricted, !policyRestricted else { return self }
        return VoiceContext(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            webURL: webURL,
            selectedText: selectedText,
            beforeContext: beforeContext,
            afterContext: afterContext,
            surroundingBefore: surroundingBefore,
            surroundingAfter: surroundingAfter,
            visibleScreenText: visibleScreenText,
            personalVocabulary: personalVocabulary,
            captured: captured,
            policyRestricted: true
        )
    }
}

// MARK: - Text helpers

public enum VoiceContextText {
    private static let boundaries: Set<Character> = [
        "\n", " ", "\t", "。", "！", "？", "；", "，", "、", "：", ".", "!", "?", ";", ",", ":",
    ]

    /// Drops AX placeholder and control characters and collapses runs of blank space.
    public static func clean(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(raw.count)
        var pendingSpace = false
        var newlines = 0
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0xFFFC, 0xFFFD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
                continue
            case 0x0A, 0x0D, 0x2028, 0x2029:
                newlines += 1
                pendingSpace = false
                continue
            case 0x09, 0x20, 0xA0, 0x3000:
                pendingSpace = true
                continue
            default:
                if CharacterSet.controlCharacters.contains(scalar) { continue }
            }
            if !out.isEmpty {
                if newlines > 0 {
                    out.append(newlines > 1 ? "\n\n" : "\n")
                } else if pendingSpace {
                    out.append(" ")
                }
            }
            newlines = 0
            pendingSpace = false
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    public static func singleLine(_ raw: String?) -> String {
        clean(raw).replacingOccurrences(of: "\n\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// The last `limit` characters, starting after a nearby word or sentence boundary when there is one.
    public static func tail(_ text: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let cut = Array(text.suffix(limit))
        let window = min(cut.count - 1, max(4, limit / 4))
        if window > 0, let i = cut[0..<window].firstIndex(where: { boundaries.contains($0) }) {
            return String(cut[(i + 1)...]).trimmingCharacters(in: .whitespaces)
        }
        return String(cut)
    }

    /// The first `limit` characters, ending at a nearby word or sentence boundary when there is one.
    public static func head(_ text: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let cut = Array(text.prefix(limit))
        let window = min(cut.count - 1, max(4, limit / 4))
        if window > 0, let i = cut[(cut.count - window)...].lastIndex(where: { boundaries.contains($0) }) {
            return String(cut[...i]).trimmingCharacters(in: .whitespaces)
        }
        return String(cut)
    }

    /// Scheme, host and path only: query strings and fragments often carry tokens and personal data.
    public static func sanitizedURL(_ raw: String?, limit: Int = 120) -> String? {
        let trimmed = singleLine(raw)
        guard !trimmed.isEmpty, var parts = URLComponents(string: trimmed), let host = parts.host, !host.isEmpty else {
            return nil
        }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let clean = parts.string else { return nil }
        return clean.count > limit ? String(clean.prefix(limit)) : clean
    }

    /// The window title without the app's own name, which says nothing the app line does not.
    public static func windowTitle(_ context: VoiceContext, limit: Int) -> String {
        var title = singleLine(context.windowTitle)
        if let app = context.appName?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            if title == app { return "" }
            for separator in [" — ", " – ", " - ", " | "] where title.hasSuffix(separator + app) {
                title = String(title.dropLast(separator.count + app.count))
            }
        }
        return head(title, limit)
    }
}

// MARK: - Key terms

/// Proper nouns and identifiers worth biasing a recogniser towards, without segmenting Chinese.
public enum VoiceContextTerms {
    /// Only so much of the screen is scanned, keeping this cheap on the main thread.
    static let maxScannedCharacters = 6_000

    private static let latinToken = try! NSRegularExpression(
        pattern: "[A-Za-z][A-Za-z0-9]*(?:[._+#-][A-Za-z0-9]+)*",
        options: []
    )
    private static let quotedCJK = try! NSRegularExpression(
        pattern: "[《「『“]([^》」』”\\n]{2,16})[》」』”]",
        options: []
    )

    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "could", "did", "do", "does",
        "for", "from", "had", "has", "have", "he", "her", "here", "his", "how", "i", "if", "in", "into", "is",
        "it", "its", "just", "let", "me", "my", "no", "not", "now", "of", "on", "or", "our", "she", "so",
        "that", "the", "their", "them", "then", "there", "these", "they", "this", "to", "too", "up", "us",
        "was", "we", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you",
        "your", "yes", "ok", "okay", "hi", "hello", "thanks", "please", "all", "any", "one", "new", "more",
        "also", "about", "after", "before", "out", "over", "some", "than", "very", "only", "other", "such",
        "should", "may", "might", "must", "shall", "each", "both", "few", "most", "own", "same", "via",
        "http", "https", "www", "com", "org", "net", "html", "png", "jpg",
    ]

    /// Ranks candidate terms by how identifier-like they are, how important their source is and how often they appear.
    /// `sources` pairs a text with its weight (3 for the cursor and window, 1 for the screen).
    public static func extract(
        from sources: [(text: String, weight: Int)],
        excluding: [String] = [],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        struct Candidate {
            var term: String
            var score: Int
            var count: Int
            var order: Int
            var lowercasePlain: Bool
        }
        let excluded = Set(excluding.map { $0.lowercased() })
        var candidates: [String: Candidate] = [:]
        var order = 0

        func add(_ term: String, base: Int, weight: Int, lowercasePlain: Bool) {
            let key = term.lowercased()
            guard !excluded.contains(key) else { return }
            if var existing = candidates[key] {
                existing.count += 1
                existing.score = max(existing.score, base * weight)
                existing.lowercasePlain = existing.lowercasePlain && lowercasePlain
                candidates[key] = existing
            } else {
                candidates[key] = Candidate(term: term, score: base * weight, count: 1, order: order, lowercasePlain: lowercasePlain)
                order += 1
            }
        }

        for (raw, weight) in sources where !raw.isEmpty {
            let text = raw.count > maxScannedCharacters ? String(raw.prefix(maxScannedCharacters)) : raw
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in latinToken.matches(in: text, range: range) {
                let token = ns.substring(with: match.range)
                guard token.count >= 2, token.count <= 32 else { continue }
                let lower = token.lowercased()
                if stopwords.contains(lower) { continue }
                let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                let uppercase = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
                let hasDigitOrSeparator = token.unicodeScalars.contains {
                    CharacterSet.decimalDigits.contains($0) || "._+#-".unicodeScalars.contains($0)
                }
                let isAllCaps = uppercase == letters.count && uppercase >= 2
                let isMixedCase = uppercase >= 2 && !isAllCaps
                let isCapitalized = uppercase == 1 && token.first?.isUppercase == true
                if isMixedCase || isAllCaps || hasDigitOrSeparator {
                    add(token, base: 3, weight: weight, lowercasePlain: false)
                } else if isCapitalized {
                    add(token, base: 2, weight: weight, lowercasePlain: false)
                } else if token.count >= 4 {
                    add(token, base: 1, weight: weight, lowercasePlain: true)
                }
            }
            for match in quotedCJK.matches(in: text, range: range) where match.numberOfRanges > 1 {
                let inner = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                guard !inner.isEmpty, inner.unicodeScalars.contains(where: { $0.value >= 0x3400 && $0.value <= 0x9FFF }) else { continue }
                add(inner, base: 3, weight: weight, lowercasePlain: false)
            }
        }

        // A plain lowercase word is only a term when it keeps coming back.
        let kept = candidates.values.filter { !$0.lowercasePlain || $0.count >= 2 }
        let ranked = kept.sorted {
            let a = $0.score + min($0.count, 5) - 1
            let b = $1.score + min($1.count, 5) - 1
            if a != b { return a > b }
            return $0.order < $1.order
        }
        return Array(ranked.prefix(limit).map(\.term))
    }

    /// Terms from the context fields the privacy gate allows, cursor and window first.
    /// `includeScreen` adds the whole visible screen, which is too noisy for the recognisers' own context:
    /// unrelated words on screen pulled Qwen3-ASR towards them in testing.
    public static func fromContext(_ context: VoiceContext, limit: Int, includeScreen: Bool) -> [String] {
        let ctx = context.promptSafe()
        var sources: [(text: String, weight: Int)] = [
            (VoiceContextText.singleLine(ctx.windowTitle), 3),
            (VoiceContextText.tail(VoiceContextText.clean(ctx.beforeContext), 600), 3),
            (VoiceContextText.head(VoiceContextText.clean(ctx.afterContext), 300), 3),
            (VoiceContextText.clean(ctx.selectedText), 3),
            (VoiceContextText.tail(VoiceContextText.clean(ctx.surroundingBefore), 800), 2),
            (VoiceContextText.head(VoiceContextText.clean(ctx.surroundingAfter), 600), 2),
        ]
        if includeScreen {
            sources.append((VoiceContextText.clean(ctx.visibleScreenText), 1))
        }
        var excluded = ctx.personalVocabulary
        if let app = ctx.appName { excluded.append(app) }
        return extract(from: sources, excluding: excluded, limit: limit)
    }
}

// MARK: - Recogniser context

/// Which recogniser a context is shaped for. Each has its own budget, because a long or noisy prompt
/// slows the first token and makes small models repeat it.
public enum VoiceASRContextTarget: Sendable, Equatable {
    /// Qwen3-ASR: free text in the system turn.
    case qwen
    /// whisper.cpp (`prompt` field / `--prompt`) and the local OpenAI-compatible HTTP service: an initial prompt.
    case whisper
    /// OpenAI-compatible `/audio/transcriptions` in the cloud.
    case cloud(model: String)

    /// In characters. Whisper keeps only ~224 prompt tokens and a CJK character can cost two or three.
    public var characterBudget: Int {
        switch self {
        case .qwen: return 240
        case .whisper: return 120
        case .cloud(let model): return model.lowercased().contains("gpt-4o") ? 400 : 160
        }
    }
}

public enum VoiceASRContextBuilder {
    /// Joins items in order, dropping whole items once `limit` characters are used.
    static func joined(_ items: [String], separator: String, limit: Int) -> String {
        var out = ""
        for item in items where !item.isEmpty {
            let next = out.isEmpty ? item : out + separator + item
            if next.count > limit { break }
            out = next
        }
        return out
    }

    /// The context string for one recogniser, or nil when there is nothing worth sending.
    public static func recognitionContext(
        _ context: VoiceContext,
        target: VoiceASRContextTarget,
        language: String
    ) -> String? {
        let ctx = context.promptSafe()
        let budget = target.characterBudget
        let vocabulary = VoicePromptBuilder.deduplicatedVocabulary(ctx.personalVocabulary, limit: 40)
            .filter { $0.count <= 40 }
        let terms = VoiceContextTerms.fromContext(ctx, limit: 16, includeScreen: false)
        let before = VoiceContextText.singleLine(ctx.beforeContext)

        switch target {
        case .qwen:
            // Qwen reads the system turn as reference text, so title, terms and the text before the cursor each get a line.
            let title = VoiceContextText.windowTitle(ctx, limit: 50)
            let termLine = joined(vocabulary + terms, separator: " ", limit: min(160, budget - title.count - 1))
            let used = title.count + termLine.count + 2
            let beforeLine = VoiceContextText.tail(before, min(60, max(0, budget - used)))
            let lines = [title, termLine, beforeLine].filter { !$0.isEmpty }
            let text = lines.joined(separator: "\n")
            return text.isEmpty ? nil : String(text.prefix(budget))

        case .whisper, .cloud:
            // Whisper treats the prompt as the text spoken just before, so it reads as a glossary sentence
            // followed by how the current text ends.
            let english = language.lowercased().hasPrefix("en")
            let separator = english ? ", " : "、"
            let stop = english ? ". " : "。"
            let maxBefore = target == .whisper ? 40 : 80
            let glossary = joined(vocabulary + terms, separator: separator, limit: budget * 3 / 5)
            let remaining = budget - glossary.count - stop.count
            let tail = VoiceContextText.tail(before, min(maxBefore, max(0, remaining)))
            var text = glossary.isEmpty ? "" : glossary + stop.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty {
                text += (text.isEmpty || !english ? "" : " ") + tail
            }
            return text.isEmpty ? nil : String(text.prefix(budget))
        }
    }

    /// Phrases for `SFSpeechRecognitionRequest.contextualStrings`: the vocabulary, then terms on screen.
    public static func contextualStrings(_ context: VoiceContext, limit: Int = 100) -> [String] {
        let ctx = context.promptSafe()
        let vocabulary = VoicePromptBuilder.deduplicatedVocabulary(ctx.personalVocabulary, limit: 60)
            .filter { $0.count <= 40 }
        let terms = VoiceContextTerms.fromContext(ctx, limit: max(0, limit - vocabulary.count), includeScreen: true)
        return Array((vocabulary + terms).prefix(limit))
    }

    /// The recogniser returned its own prompt instead of the speech, which Whisper does on unclear audio.
    public static func isPromptEcho(_ transcript: String, prompt: String?) -> Bool {
        guard let prompt, !prompt.isEmpty else { return false }
        func normalized(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            })
        }
        let spoken = normalized(transcript)
        guard spoken.count >= 6 else { return false }
        return normalized(prompt).contains(spoken)
    }
}

// MARK: - Polish context

public enum VoicePolishContextBudget: Sendable {
    /// Cloud models: window, URL, cursor and surrounding text and an excerpt of the screen.
    case full
    /// Small local models (Qwen2.5-1.5B runs with a 2K window) and local services: a few short lines and key terms.
    case compact
}

public enum VoicePolishContextBuilder {
    /// The reference block for the polish system prompt, or "" when nothing may or need be shown.
    public static func referenceBlock(_ context: VoiceContext, budget: VoicePolishContextBudget, includeText: Bool = true) -> String {
        let ctx = context.promptSafe()
        var lines: [String] = []

        let app = VoiceContextText.singleLine(ctx.appName)
        let title = VoiceContextText.windowTitle(ctx, limit: budget == .full ? 80 : 40)
        if !app.isEmpty || !title.isEmpty {
            lines.append("应用：" + [app, title].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        guard includeText else { return wrap(lines) }

        let before = VoiceContextText.clean(ctx.beforeContext)
        let after = VoiceContextText.clean(ctx.afterContext)
        switch budget {
        case .full:
            if let url = VoiceContextText.sanitizedURL(ctx.webURL) {
                lines.append("网址：\(url)")
            }
            let beforeText = VoiceContextText.tail(before, 400)
            let afterText = VoiceContextText.head(after, 200)
            if !beforeText.isEmpty { lines.append("光标前文：\(beforeText)") }
            if !afterText.isEmpty { lines.append("光标后文：\(afterText)") }
            let above = VoiceContextText.tail(VoiceContextText.clean(ctx.surroundingBefore), 300)
            if !above.isEmpty, !before.contains(above) { lines.append("输入框上方：\(above)") }
            let below = VoiceContextText.head(VoiceContextText.clean(ctx.surroundingAfter), 200)
            if !below.isEmpty, !after.contains(below) { lines.append("输入框下方：\(below)") }
            let screen = screenExcerpt(ctx.visibleScreenText, skipping: [before, after], limit: 1_200)
            if !screen.isEmpty { lines.append("屏幕可见内容（节选）：\n\(screen)") }
        case .compact:
            let beforeText = VoiceContextText.tail(VoiceContextText.singleLine(before), 80)
            let afterText = VoiceContextText.head(VoiceContextText.singleLine(after), 40)
            if !beforeText.isEmpty { lines.append("光标前文：\(beforeText)") }
            if !afterText.isEmpty { lines.append("光标后文：\(afterText)") }
            let terms = VoiceContextTerms.fromContext(ctx, limit: 12, includeScreen: true)
            if !terms.isEmpty { lines.append("屏幕关键词：\(terms.joined(separator: "、"))") }
        }
        return wrap(lines)
    }

    private static func wrap(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return "【参考上下文】\n" + lines.joined(separator: "\n") + "\n【参考上下文结束】"
    }

    /// Screen lines in order, without repeats or lines the cursor text already shows.
    static func screenExcerpt(_ raw: String?, skipping: [String], limit: Int) -> String {
        let text = VoiceContextText.clean(raw)
        guard !text.isEmpty, limit > 0 else { return "" }
        var seen = Set<String>()
        var out: [String] = []
        var used = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, seen.insert(trimmed).inserted else { continue }
            // A short line is only skipped when it is the cursor text itself, so common words survive.
            if skipping.contains(where: { $0 == trimmed || (trimmed.count >= 8 && $0.contains(trimmed)) }) { continue }
            let piece = trimmed.count > 200 ? VoiceContextText.head(trimmed, 200) : trimmed
            if used + piece.count + 1 > limit { break }
            out.append(piece)
            used += piece.count + 1
        }
        return out.joined(separator: "\n")
    }
}
