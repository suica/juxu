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

/// Keeps the live caption from rewriting itself. Text that two consecutive passes agree on is
/// locked (LocalAgreement); the rest stays tentative. Passes are aligned on overlapping text, not
/// position, because the transcription window slides over long utterances.
///
/// This only affects the caption. The committed text always comes from the final pass.
public struct VoicePartialStabilizer {
    private static let overlapSearchLength = 48
    private static let minOverlap = 4
    private static let endSlack = 2
    private static let missesBeforeRewrite = 2

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
                    return Array(current[(indices[start + length - 1] + 1)...])
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
        guard let next = continuation(of: current) else {
            misses += 1
            // One pass that cannot be aligned is noise, so the caption does not move.
            guard misses >= Self.missesBeforeRewrite else { return display() }
            misses = 0
            if windowed {
                locked = []
                startsMidUtterance = true
            } else {
                locked = Array(current.prefix(Self.agreedPrefix(locked, current)))
                startsMidUtterance = false
            }
            tail = Array(current.dropFirst(locked.count))
            return display()
        }
        misses = 0
        if locked.isEmpty, windowed { startsMidUtterance = true }
        let agreed = Self.agreedPrefix(tail, next)
        locked += next.prefix(agreed)
        tail = Array(next.dropFirst(agreed))
        return display()
    }
}
