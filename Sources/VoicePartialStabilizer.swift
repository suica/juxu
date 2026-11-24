import Foundation

/// What the live caption shows. The last `tentativeCount` characters are not confirmed yet.
public struct VoicePartialDisplay: Equatable, Sendable {
    public let text: String
    public let tentativeCount: Int

    public init(text: String, tentativeCount: Int = 0) {
        self.text = text
        self.tentativeCount = tentativeCount
    }
}

/// Stabilises the live caption without freezing mid-clause mistakes.
///
/// The active clause stays mutable so the ASR model can revise earlier homophones as the rest of
/// the clause arrives (e.g. "语音书" → "语音输入的时候"). Text is locked (shown in full white)
/// only once a clause ends with punctuation and the speaker has moved on to agreed words after it,
/// or once an unpunctuated run grows past `maxUnsealedChars` (leaving the trailing window mutable).
///
/// Passes are aligned on overlapping text rather than character index because the transcription
/// window slides over long utterances.
public struct VoicePartialStabilizer {
    private static let overlapSearchLength = 48
    private static let minOverlap = 4
    private static let endSlack = 2
    private static let missesBeforeRewrite = 2
    private static let maxUnsealedChars = 28
    private static let mutableTailChars = 12
    private static let clauseEnders: Set<Character> = Set("，。！？；,.!?;")

    private var locked: [Character] = []
    private var tail: [Character] = []
    private var startsMidUtterance = false
    private var misses = 0

    public init() {}

    private static func isCore(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func core(_ text: [Character]) -> (chars: [Character], indices: [Int]) {
        var chars: [Character] = []
        var indices: [Int] = []
        for (i, c) in text.enumerated() where isCore(c) {
            chars.append(Character(c.lowercased()))
            indices.append(i)
        }
        return (chars, indices)
    }

    /// The part of `current` that continues the locked text, or nil when they cannot be aligned.
    private func continuation(of current: [Character]) -> [Character]? {
        guard !locked.isEmpty else { return current }
        let lockedCore = Self.core(locked).chars
        let (currentCore, indices) = Self.core(current)
        guard !lockedCore.isEmpty else { return current }
        let needed = min(Self.minOverlap, lockedCore.count)

        for slack in 0...min(Self.endSlack, lockedCore.count - needed) {
            let end = lockedCore.count - slack
            let longest = min(Self.overlapSearchLength, end, currentCore.count)
            guard longest >= needed else { continue }
            for length in stride(from: longest, through: needed, by: -1) {
                let suffix = lockedCore[(end - length)..<end]
                // Search from the right: the newest occurrence is the one that continues the text.
                for start in stride(from: currentCore.count - length, through: 0, by: -1)
                where currentCore[start..<(start + length)].elementsEqual(suffix) {
                    var nextStart = indices[start + length - 1] + 1
                    if let lastLocked = locked.last, !Self.isCore(lastLocked) {
                        while nextStart < current.count, !Self.isCore(current[nextStart]) {
                            nextStart += 1
                        }
                    }
                    return Array(current[nextStart...])
                }
            }
        }
        return nil
    }

    /// Length of `next` that both passes agree on, ending on a whole word.
    private static func agreedPrefix(_ previous: [Character], _ next: [Character]) -> Int {
        let a = core(previous)
        let b = core(next)
        var matched = 0
        while matched < a.chars.count, matched < b.chars.count, a.chars[matched] == b.chars[matched] {
            matched += 1
        }
        // Do not lock half of a Latin word that is still being spelled out.
        while matched > 0, matched < b.chars.count,
              b.chars[matched - 1].isASCII, b.chars[matched - 1].isLetter,
              b.chars[matched].isASCII, b.chars[matched].isLetter,
              b.indices[matched] == b.indices[matched - 1] + 1 {
            matched -= 1
        }
        return matched == 0 ? 0 : b.indices[matched - 1] + 1
    }

    /// How many leading characters of `next` are ready to lock:
    /// 1. Through the last clause-ending punctuation that has agreed words after it, or
    /// 2. For long unpunctuated runs, everything agreed before the trailing mutable window.
    private static func lockablePrefix(in next: [Character], agreed: Int) -> Int {
        guard agreed > 0 else { return 0 }
        if let punctIndex = (0..<agreed).reversed().first(where: { clauseEnders.contains(next[$0]) }) {
            var end = punctIndex + 1
            while end < next.count, next[end].isWhitespace { end += 1 }
            return end
        }
        guard next.count > maxUnsealedChars else { return 0 }
        let cap = min(agreed, next.count - mutableTailChars)
        guard cap > 0 else { return 0 }
        var end = cap
        // Keep Latin words intact when locking part of a long unpunctuated run.
        while end > 0, end < next.count,
              next[end - 1].isASCII, next[end - 1].isLetter,
              next[end].isASCII, next[end].isLetter {
            end -= 1
        }
        return end
    }

    /// Guards against a single noisy pass abruptly wiping a longer unsealed clause.
    private static func looksLikeAbruptNoise(previous: [Character], current: [Character]) -> Bool {
        guard previous.count >= 4, current.count * 2 < previous.count else { return false }
        let prevCore = Set(core(previous).chars)
        let currCore = core(current).chars
        return !currCore.contains(where: { prevCore.contains($0) })
    }

    private func display() -> VoicePartialDisplay {
        // Each pass ends its unfinished sentence with a full stop that the next pass replaces.
        var shownTail = tail[...]
        while let last = shownTail.last, !Self.isCore(last) { shownTail.removeLast() }
        return VoicePartialDisplay(
            text: (startsMidUtterance ? "…" : "") + String(locked + shownTail),
            tentativeCount: shownTail.count
        )
    }

    /// Takes one partial pass. `windowed` means the pass did not see the start of the utterance.
    public mutating func update(_ text: String, windowed: Bool) -> VoicePartialDisplay {
        let current = Array(text)
        if locked.isEmpty, Self.looksLikeAbruptNoise(previous: tail, current: current) {
            misses += 1
            guard misses >= Self.missesBeforeRewrite else { return display() }
            misses = 0
            tail = current
            return display()
        }
        guard let next = continuation(of: current) else {
            misses += 1
            // One pass that cannot be aligned is noise, so the caption does not move.
            guard misses >= Self.missesBeforeRewrite else { return display() }
            misses = 0
            if windowed {
                locked = []
                startsMidUtterance = true
            } else {
                let agreed = Self.agreedPrefix(locked, current)
                locked = Array(current.prefix(Self.lockablePrefix(in: current, agreed: agreed)))
                startsMidUtterance = false
            }
            tail = Array(current.dropFirst(locked.count))
            return display()
        }
        misses = 0
        if locked.isEmpty, windowed { startsMidUtterance = true }
        let agreed = Self.agreedPrefix(tail, next)
        let lockCount = Self.lockablePrefix(in: next, agreed: agreed)
        if lockCount > 0 {
            locked += next.prefix(lockCount)
            tail = Array(next.dropFirst(lockCount))
        } else {
            tail = next
        }
        return display()
    }
}
