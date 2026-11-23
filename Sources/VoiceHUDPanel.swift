import Accelerate
import AppKit
import QuartzCore

public enum VoiceHUDState: Equatable {
    case hidden
    case recording(level: Float, elapsed: TimeInterval, partial: String, modeLabel: String, tentativeCount: Int = 0)
    case transcribing(modeLabel: String)
    case polishing(preview: String)
    case notice(text: String, isError: Bool)
}

enum VoiceHUDMetrics {
    static let canvasSize = NSSize(width: 576, height: 112)
    static let pillBottom: CGFloat = 9
    static let pillHeight: CGFloat = 28
    static let listeningWidth: CGFloat = 64
    static let processingWidth: CGFloat = 87
    static let barCount = 11
    static let barWidth: CGFloat = 2
    static let barPitch: CGFloat = 3.6
    static let barMaxHeight: CGFloat = 19.6
    static let barsInset: CGFloat = 13
    static let cardGap: CGFloat = 8
    static let cardMaxWidth: CGFloat = 520
    static let cardLineHeight: CGFloat = 20
    static let cardPadX: CGFloat = 14
    static let cardPadY: CGFloat = 9
    static let noticeMaxTextWidth: CGFloat = 360
    static let fadeDuration: CFTimeInterval = 0.14
    /// New caption characters are placed at once and fade in over this time.
    static let captionFadeDuration: CFTimeInterval = 0.11
    static let captionMaxStagger: CFTimeInterval = 0.05
}

enum VoiceHUDTextFit {
    static func attributes(font: NSFont, lineHeight: CGFloat) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byCharWrapping
        return [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: style]
    }

    static func lineCount(_ text: String, attrs: [NSAttributedString.Key: Any], width: CGFloat, lineHeight: CGFloat) -> Int {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attrs
        )
        return max(1, Int(ceil((rect.height - 0.5) / lineHeight)))
    }

    /// Longest suffix of `text` that fits in `maxLines`, prefixed with an ellipsis when cut.
    static func tailFitting(_ text: String, attrs: [NSAttributedString.Key: Any], width: CGFloat, lineHeight: CGFloat, maxLines: Int) -> String {
        if lineCount(text, attrs: attrs, width: width, lineHeight: lineHeight) <= maxLines {
            return text
        }
        let chars = Array(text)
        var low = 0
        var high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = "…" + String(chars.suffix(mid))
            if lineCount(candidate, attrs: attrs, width: width, lineHeight: lineHeight) <= maxLines {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return "…" + String(chars.suffix(low))
    }
}

/// Layer-hosting HUD canvas. All drawing is done with Core Animation layers; nothing runs while hidden.
final class VoiceHUDContentView: NSView {
    private enum Mode {
        case listening
        case processing
        case notice
    }

    let groupLayer = CALayer()
    private let pillLayer = CALayer()
    private let barsLayer = CALayer()
    private var barLayers: [CALayer] = []
    private var barHeights: [CGFloat]
    private let barEnvelope: [CGFloat]
    private let spinnerLayer = CALayer()
    private var spokeLayers: [CALayer] = []
    private let noticeLayer = CATextLayer()
    private let errorDotLayer = CALayer()
    private let cardLayer = CALayer()
    private let cardTextLayer = CATextLayer()

    private var mode: Mode = .listening
    private var targetLevel: CGFloat = 0
    private var smoothedLevel: CGFloat = 0
    private var targetBands: [CGFloat]
    private var spectrumQueue: [[Float]] = []
    private var spectrumStepElapsed: CFTimeInterval = 0
    private var spectrumStaleElapsed: CFTimeInterval = 0
    private var hasSpectrumInput = false
    private var barsAlpha: CGFloat = 1
    private var clock: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    private var displayLinkHandle: CADisplayLink?
    private var currentPartial = ""
    private var currentTentativeCount = 0
    private var captionSource = ""
    private var captionFitted = ""
    private var captionFadeCount = 0
    private var captionFadeElapsed: CFTimeInterval = 0
    private var cardWidthFloor: CGFloat = 0
    private var cardLinesFloor = 1
    private var currentNotice = ""
    private var currentNoticeIsError = false
    var reduceMotion = false

    private let cardFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private let noticeFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    var isAnimating: Bool { displayLinkHandle != nil }

    override init(frame frameRect: NSRect) {
        let count = VoiceHUDMetrics.barCount
        let centre = CGFloat(count - 1) / 2
        barEnvelope = (0..<count).map { i in
            1 - pow(abs(CGFloat(i) - centre) / (centre + 1), 1.5)
        }
        barHeights = Array(repeating: VoiceHUDMetrics.barWidth, count: count)
        targetBands = Array(repeating: 0, count: count)
        super.init(frame: frameRect)

        let root = CALayer()
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        buildLayers(in: root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayers(in root: CALayer) {
        let canvas = VoiceHUDMetrics.canvasSize
        groupLayer.anchorPoint = CGPoint(
            x: 0.5,
            y: (VoiceHUDMetrics.pillBottom + VoiceHUDMetrics.pillHeight / 2) / canvas.height
        )
        groupLayer.frame = CGRect(origin: .zero, size: canvas)
        root.addSublayer(groupLayer)

        cardLayer.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        cardLayer.cornerRadius = 12
        cardLayer.cornerCurve = .continuous
        cardLayer.opacity = 0
        groupLayer.addSublayer(cardLayer)
        cardTextLayer.isWrapped = true
        cardTextLayer.alignmentMode = .left
        cardLayer.addSublayer(cardTextLayer)

        pillLayer.backgroundColor = NSColor.black.cgColor
        pillLayer.cornerRadius = VoiceHUDMetrics.pillHeight / 2
        pillLayer.cornerCurve = .circular
        groupLayer.addSublayer(pillLayer)

        barsLayer.frame = CGRect(
            x: VoiceHUDMetrics.barsInset,
            y: 0,
            width: CGFloat(VoiceHUDMetrics.barCount - 1) * VoiceHUDMetrics.barPitch + VoiceHUDMetrics.barWidth,
            height: VoiceHUDMetrics.pillHeight
        )
        pillLayer.addSublayer(barsLayer)
        for i in 0..<VoiceHUDMetrics.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 0.7
            bar.bounds = CGRect(x: 0, y: 0, width: VoiceHUDMetrics.barWidth, height: VoiceHUDMetrics.barWidth)
            bar.position = CGPoint(
                x: VoiceHUDMetrics.barWidth / 2 + CGFloat(i) * VoiceHUDMetrics.barPitch,
                y: VoiceHUDMetrics.pillHeight / 2
            )
            barsLayer.addSublayer(bar)
            barLayers.append(bar)
        }

        spinnerLayer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        spinnerLayer.opacity = 0
        pillLayer.addSublayer(spinnerLayer)
        for i in 0..<8 {
            let spoke = CALayer()
            spoke.backgroundColor = NSColor.white.cgColor
            spoke.bounds = CGRect(x: 0, y: 0, width: 1.8, height: 3.8)
            spoke.cornerRadius = 0.9
            let angle = -CGFloat(i) * .pi / 4
            spoke.position = CGPoint(x: 8 + 5.4 * sin(-angle), y: 8 + 5.4 * cos(angle))
            spoke.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            spinnerLayer.addSublayer(spoke)
            spokeLayers.append(spoke)
        }

        noticeLayer.alignmentMode = .left
        noticeLayer.truncationMode = .end
        noticeLayer.opacity = 0
        pillLayer.addSublayer(noticeLayer)
        errorDotLayer.backgroundColor = NSColor.systemRed.cgColor
        errorDotLayer.cornerRadius = 3
        errorDotLayer.opacity = 0
        pillLayer.addSublayer(errorDotLayer)

        setContentsScale(NSScreen.main?.backingScaleFactor ?? 2)
        layoutPill(animated: false)
    }

    func setContentsScale(_ scale: CGFloat) {
        for textLayer in [cardTextLayer, noticeLayer] {
            textLayer.contentsScale = scale
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setContentsScale(window?.backingScaleFactor ?? 2)
    }

    func apply(_ state: VoiceHUDState, animated: Bool) {
        let newMode: Mode
        var partial = ""
        var tentativeCount = 0
        var notice = ""
        var noticeIsError = false
        switch state {
        case .hidden:
            return
        case .recording(let level, _, let text, _, let tentative):
            newMode = .listening
            targetLevel = CGFloat(max(0, min(1, level)))
            partial = text
            tentativeCount = tentative
        case .transcribing, .polishing:
            newMode = .processing
            targetLevel = 0
        case .notice(let text, let isError):
            newMode = .notice
            targetLevel = 0
            notice = text
            noticeIsError = isError
        }

        let modeChanged = newMode != mode
        let noticeChanged = notice != currentNotice || noticeIsError != currentNoticeIsError
        mode = newMode
        currentNotice = notice
        currentNoticeIsError = noticeIsError
        if modeChanged || noticeChanged {
            layoutPill(animated: animated && !reduceMotion)
        }
        if partial != currentPartial || tentativeCount != currentTentativeCount {
            currentPartial = partial
            currentTentativeCount = tentativeCount
            if partial.isEmpty {
                cardWidthFloor = 0
                cardLinesFloor = 1
            }
            layoutCard()
        }
    }

    func enqueueSpectrumFrames(_ frames: [[Float]]) {
        guard !frames.isEmpty else { return }
        hasSpectrumInput = true
        spectrumStaleElapsed = 0
        if spectrumQueue.isEmpty {
            // Apply the first frame immediately so onset feels instantaneous.
            applyBandTargets(frames[0])
            if frames.count > 1 {
                spectrumQueue.append(contentsOf: frames.dropFirst())
            }
            spectrumStepElapsed = 0
        } else {
            spectrumQueue.append(contentsOf: frames)
            if spectrumQueue.count > 8 {
                spectrumQueue.removeFirst(spectrumQueue.count - 8)
            }
        }
    }

    private func applyBandTargets(_ frame: [Float]) {
        for i in 0..<min(targetBands.count, frame.count) {
            targetBands[i] = CGFloat(max(0, min(1, frame[i])))
        }
    }

    func resetForPresentation() {
        smoothedLevel = 0
        targetLevel = 0
        spectrumQueue.removeAll()
        spectrumStepElapsed = 0
        spectrumStaleElapsed = 0
        hasSpectrumInput = false
        for i in 0..<targetBands.count {
            targetBands[i] = 0
        }
        barsAlpha = 1
        lastTimestamp = nil
        currentPartial = ""
        captionFadeCount = 0
        cardWidthFloor = 0
        cardLinesFloor = 1
        layoutCard()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            barHeights[i] = VoiceHUDMetrics.barWidth
            bar.bounds.size.height = VoiceHUDMetrics.barWidth
        }
        barsLayer.opacity = 1
        CATransaction.commit()
    }

    private func layoutPill(animated: Bool) {
        let canvas = VoiceHUDMetrics.canvasSize
        var width = VoiceHUDMetrics.listeningWidth
        var noticeAttr: NSAttributedString?
        var noticeTextWidth: CGFloat = 0
        let dotSpace: CGFloat = currentNoticeIsError ? 12 : 0
        if mode == .processing {
            width = VoiceHUDMetrics.processingWidth
        } else if mode == .notice {
            let attrs: [NSAttributedString.Key: Any] = [.font: noticeFont, .foregroundColor: NSColor.white]
            let attr = NSAttributedString(string: currentNotice, attributes: attrs)
            noticeTextWidth = min(VoiceHUDMetrics.noticeMaxTextWidth, ceil(attr.size().width) + 1)
            noticeAttr = attr
            width = max(VoiceHUDMetrics.listeningWidth, noticeTextWidth + dotSpace + 28)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.18 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(!animated)
        pillLayer.frame = CGRect(
            x: round((canvas.width - width) / 2),
            y: VoiceHUDMetrics.pillBottom,
            width: width,
            height: VoiceHUDMetrics.pillHeight
        )
        spinnerLayer.position = CGPoint(x: width - 17, y: VoiceHUDMetrics.pillHeight / 2)
        spinnerLayer.opacity = mode == .processing ? 1 : 0
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.isHidden = mode == .notice
        noticeLayer.opacity = mode == .notice ? 1 : 0
        errorDotLayer.opacity = mode == .notice && currentNoticeIsError ? 1 : 0
        if let noticeAttr {
            noticeLayer.string = noticeAttr
            noticeLayer.frame = CGRect(x: 14 + dotSpace, y: 6, width: noticeTextWidth, height: 16)
            errorDotLayer.frame = CGRect(x: 14, y: 11, width: 6, height: 6)
        }
        CATransaction.commit()
    }

    private func layoutCard() {
        let text = currentPartial
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard mode == .listening, !text.isEmpty else {
            cardLayer.opacity = 0
            cardTextLayer.string = nil
            captionSource = ""
            captionFitted = ""
            captionFadeCount = 0
            return
        }

        let metrics = VoiceHUDMetrics.self
        let attrs = VoiceHUDTextFit.attributes(font: cardFont, lineHeight: metrics.cardLineHeight)
        let maxTextWidth = metrics.cardMaxWidth - metrics.cardPadX * 2
        let fitted = VoiceHUDTextFit.tailFitting(
            text,
            attrs: attrs,
            width: maxTextWidth - 2,
            lineHeight: metrics.cardLineHeight,
            maxLines: 2
        )
        let natural = ceil((fitted as NSString).size(withAttributes: attrs).width) + 3
        // Grow in steps and never shrink during an utterance, so the card does not jitter.
        let stepped = min(maxTextWidth, ceil(natural / 24) * 24)
        cardWidthFloor = max(cardWidthFloor, stepped)
        let lines = VoiceHUDTextFit.lineCount(
            fitted,
            attrs: attrs,
            width: cardWidthFloor - 2,
            lineHeight: metrics.cardLineHeight
        )
        cardLinesFloor = max(cardLinesFloor, min(2, lines))

        let cardWidth = cardWidthFloor + metrics.cardPadX * 2
        let textHeight = CGFloat(cardLinesFloor) * metrics.cardLineHeight
        let cardHeight = textHeight + metrics.cardPadY * 2
        cardLayer.frame = CGRect(
            x: round((metrics.canvasSize.width - cardWidth) / 2),
            y: metrics.pillBottom + metrics.pillHeight + metrics.cardGap,
            width: cardWidth,
            height: cardHeight
        )
        cardTextLayer.frame = CGRect(
            x: metrics.cardPadX,
            y: metrics.cardPadY,
            width: cardWidthFloor,
            height: textHeight
        )
        // Only characters that are actually new fade in; a rewrite fades from where it differs.
        let unchanged = zip(captionSource, text).prefix { $0 == $1 }.count
        captionFadeCount = reduceMotion ? 0 : min(max(0, text.count - unchanged), fitted.count)
        captionFadeElapsed = 0
        captionSource = text
        captionFitted = fitted
        renderCaption()
        cardLayer.opacity = 1
    }

    private func renderCaption() {
        let attrs = VoiceHUDTextFit.attributes(font: cardFont, lineHeight: VoiceHUDMetrics.cardLineHeight)
        let fitted = captionFitted
        let caption = NSMutableAttributedString(string: fitted, attributes: attrs)
        let total = fitted.count
        let dimmed = min(currentTentativeCount, total)
        if dimmed > 0 {
            let start = fitted.index(fitted.endIndex, offsetBy: -dimmed)
            caption.addAttribute(
                .foregroundColor,
                value: NSColor.white.withAlphaComponent(0.55),
                range: NSRange(start..., in: fitted)
            )
        }
        if captionFadeCount > 0 {
            let stagger = min(0.012, VoiceHUDMetrics.captionMaxStagger / Double(captionFadeCount))
            var index = fitted.index(fitted.endIndex, offsetBy: -captionFadeCount)
            for k in 0..<captionFadeCount {
                let next = fitted.index(after: index)
                let progress = max(0, min(1, (captionFadeElapsed - stagger * Double(k)) / VoiceHUDMetrics.captionFadeDuration))
                let base: CGFloat = captionFadeCount - k <= dimmed ? 0.55 : 1
                caption.addAttribute(
                    .foregroundColor,
                    value: NSColor.white.withAlphaComponent(base * CGFloat(progress)),
                    range: NSRange(index..<next, in: fitted)
                )
                index = next
            }
        }
        cardTextLayer.string = caption
    }

    // MARK: Animation

    func startAnimating() {
        guard displayLinkHandle == nil else { return }
        lastTimestamp = nil
        let link = displayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLinkHandle = link
    }

    func stopAnimating() {
        displayLinkHandle?.invalidate()
        displayLinkHandle = nil
        lastTimestamp = nil
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp.map { min(0.1, max(0.001, now - $0)) } ?? (1.0 / 60)
        lastTimestamp = now
        advance(dt: dt)
    }

    /// Advances the waveform and spinner. Public to the module so previews are deterministic.
    func advance(dt: CFTimeInterval) {
        clock += dt
        let dot = VoiceHUDMetrics.barWidth
        let span = VoiceHUDMetrics.barMaxHeight - dot

        if mode != .listening {
            spectrumQueue.removeAll()
            spectrumStepElapsed = 0
            for i in 0..<targetBands.count { targetBands[i] = 0 }
        } else if hasSpectrumInput {
            spectrumStepElapsed += dt
            var popped = false
            while spectrumStepElapsed >= VoiceSpectrumAnalyzer.frameDuration, !spectrumQueue.isEmpty {
                applyBandTargets(spectrumQueue.removeFirst())
                spectrumStepElapsed -= VoiceSpectrumAnalyzer.frameDuration
                popped = true
            }
            if popped {
                spectrumStaleElapsed = 0
            } else if spectrumQueue.isEmpty {
                spectrumStepElapsed = min(spectrumStepElapsed, VoiceSpectrumAnalyzer.frameDuration)
                spectrumStaleElapsed += dt
                if spectrumStaleElapsed > 0.16 {
                    let decay = exp(-CGFloat(dt) / 0.08)
                    for i in 0..<targetBands.count {
                        targetBands[i] *= decay
                    }
                }
            }
        } else {
            let levelTau: CGFloat = targetLevel > smoothedLevel ? 0.03 : 0.13
            smoothedLevel += (targetLevel - smoothedLevel) * (1 - exp(-CGFloat(dt) / levelTau))
        }

        let energy = max(0, (smoothedLevel - 0.02) / 0.98)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<barLayers.count {
            var target = dot
            if mode == .listening {
                if hasSpectrumInput {
                    let band = targetBands[i]
                    if band > 0.015 {
                        target = dot + span * band
                    }
                } else if energy > 0 {
                    let phase = Double(i) * 2.399
                    let wobble = reduceMotion
                        ? 1.0
                        : 0.74 + 0.26 * (0.5 + 0.5 * sin(clock * 11.0 + phase) * cos(clock * 6.7 + phase * 1.7))
                    target = dot + span * energy * barEnvelope[i] * CGFloat(wobble)
                }
            }
            let attackTau: CGFloat = reduceMotion ? 0.06 : (hasSpectrumInput ? 0.020 : 0.028)
            let releaseTau: CGFloat = reduceMotion ? 0.14 : (hasSpectrumInput ? 0.068 : 0.10)
            let tau: CGFloat = target > barHeights[i] ? attackTau : releaseTau
            barHeights[i] += (target - barHeights[i]) * (1 - exp(-CGFloat(dt) / tau))
            barLayers[i].bounds.size.height = max(dot, barHeights[i])
        }

        let alphaTarget: CGFloat = mode == .processing ? 0.42 : 1
        barsAlpha += (alphaTarget - barsAlpha) * (1 - exp(-CGFloat(dt) / 0.09))
        barsLayer.opacity = Float(barsAlpha)

        if captionFadeCount > 0 {
            captionFadeElapsed += dt
            let end = VoiceHUDMetrics.captionFadeDuration + VoiceHUDMetrics.captionMaxStagger
            if captionFadeElapsed >= end { captionFadeCount = 0 }
            renderCaption()
        }

        if mode == .processing {
            let head = reduceMotion ? 0 : Int(clock * 12) % spokeLayers.count
            for (i, spoke) in spokeLayers.enumerated() {
                let age = (head - i + spokeLayers.count) % spokeLayers.count
                spoke.opacity = Float(1.0 - 0.6 * Double(age) / Double(spokeLayers.count - 1))
            }
        }
        CATransaction.commit()
    }
}

/// Maps microphone loudness to a 0...1 display level on a decibel scale, so whisper, normal and
/// loud speech look different across both quiet far-field laptop mics and loud close-up mics.
/// A slow noise-floor estimate keeps room noise at rest, and an adaptive peak ceiling tracks
/// louder microphones upward without pinning normal speech.
/// Display only: it never touches the audio given to the recogniser or the speech gate.
struct VoiceLevelMeter {
    static let quietestDB: Float = -58
    static let lowestFloorDB: Float = -65
    static let highestFloorDB: Float = -41
    static let floorMarginDB: Float = 3.5
    static let minSpanDB: Float = 12
    static let initialCeilingDB: Float = -25
    static let maxCeilingDB: Float = -4

    private(set) var noiseFloorDB: Float?
    private(set) var peakCeilingDB: Float?

    mutating func process(rms: Float, seconds: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        let clamped = min(Self.highestFloorDB, max(Self.lowestFloorDB, db))
        if let floor = noiseFloorDB {
            // Falls quickly into pauses, rises slowly so sustained speech is not taken for noise.
            let tau: Float = clamped < floor ? 0.15 : 6
            noiseFloorDB = floor + (clamped - floor) * (1 - exp(-seconds / tau))
        } else {
            noiseFloorDB = clamped
        }
        let bottom = max(Self.quietestDB, (noiseFloorDB ?? Self.lowestFloorDB) + Self.floorMarginDB)
        let minTop = min(Self.maxCeilingDB, max(bottom + Self.minSpanDB, Self.initialCeilingDB))
        let targetPeak = min(Self.maxCeilingDB, max(minTop, db))
        if let peak = peakCeilingDB {
            // Expands quickly for loud close-up mics and relaxes slowly so transient peaks
            // keep loud-vs-soft contrast visible.
            let tau: Float = targetPeak > peak ? 0.25 : 5
            peakCeilingDB = peak + (targetPeak - peak) * (1 - exp(-seconds / tau))
        } else {
            peakCeilingDB = minTop
        }
        let top = max(minTop, peakCeilingDB ?? minTop)
        return max(0, min(1, (db - bottom) / (top - bottom)))
    }
}

/// Real-time 11-band speech spectrum analyzer (Accelerate vDSP FFT) driving the 11 HUD bars
/// independently from actual voice formants and consonants.
/// Display only: never touches the audio sent to the recogniser or speech gate.
final class VoiceSpectrumAnalyzer {
    static let barCount = VoiceHUDMetrics.barCount
    static let frameDuration: CFTimeInterval = 0.025

    // 11 log-spaced speech bands from 130 Hz (fundamental) to 4800 Hz (sibilants).
    static let bandEdgesHz: [Float] = [
        130, 210, 310, 450, 650, 920, 1300, 1800, 2400, 3100, 3900, 4800,
    ]
    // Place strongest vowel formants near center and crisp harmonics/consonants toward the flanks,
    // keeping all 11 bars mapped to distinct frequency bands (no mirror duplication).
    static let barToBand: [Int] = [9, 7, 0, 5, 2, 3, 4, 1, 6, 8, 10]
    static let barTaper: [Float] = [0.66, 0.78, 0.88, 0.94, 0.98, 1.00, 0.98, 0.94, 0.88, 0.78, 0.66]

    private var cachedSampleRate: Double = 0
    private var nfft: Int = 0
    private var log2n: vDSP_Length = 0
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var windowNorm: Float = 1
    private var binRanges: [Range<Int>] = []
    private var tiltDB: [Float] = []
    private var floorMarginsDB: [Float] = []

    private var bandFloorsDB: [Float?] = Array(repeating: nil, count: barCount)
    private var peakAboveDB: Float = 14

    // Scratch buffers reused on the audio thread.
    private var frameBuf: [Float] = []
    private var realPart: [Float] = []
    private var imagPart: [Float] = []
    private var magSq: [Float] = []

    init() {
        tiltDB = (0..<Self.barCount).map { b in
            let fc = sqrt(Self.bandEdgesHz[b] * Self.bandEdgesHz[b + 1])
            return 2.8 * log2(max(fc, 200) / 300)
        }
        floorMarginsDB = (0..<Self.barCount).map { b in
            // Slightly tighter margin on upper bands so quiet fricatives pop cleanly while
            // low-frequency laptop fan noise stays completely at rest.
            4.8 - 0.8 * (Float(b) / Float(Self.barCount - 1))
        }
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    private func ensureConfigured(sampleRate: Double) {
        guard sampleRate > 0, sampleRate != cachedSampleRate else { return }
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
            fftSetup = nil
        }
        cachedSampleRate = sampleRate
        nfft = sampleRate <= 24_000 ? 512 : 1024
        log2n = vDSP_Length(round(log2(Double(nfft))))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: nfft)
        vDSP_hann_window(&window, vDSP_Length(nfft), Int32(vDSP_HANN_NORM))
        var norm: Float = 0
        vDSP_dotpr(window, 1, window, 1, &norm, vDSP_Length(nfft))
        windowNorm = max(norm, 1e-6)

        let half = nfft / 2
        let binHz = Float(sampleRate) / Float(nfft)
        binRanges = (0..<Self.barCount).map { b in
            let lo = max(1, Int(floor(Self.bandEdgesHz[b] / binHz)))
            let hi = min(half, max(lo + 1, Int(ceil(Self.bandEdgesHz[b + 1] / binHz))))
            return lo..<hi
        }

        frameBuf = [Float](repeating: 0, count: nfft)
        realPart = [Float](repeating: 0, count: half)
        imagPart = [Float](repeating: 0, count: half)
        magSq = [Float](repeating: 0, count: half)
    }

    /// Slices a CoreAudio PCM buffer into ~25 ms sub-windows and returns one 11-bar frame per slice.
    func process(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> [[Float]] {
        guard count > 0, sampleRate > 0 else { return [] }
        ensureConfigured(sampleRate: sampleRate)
        let step = max(1, Int((sampleRate * Self.frameDuration).rounded()))
        var frames: [[Float]] = []
        frames.reserveCapacity(max(1, (count + step - 1) / step))
        var offset = 0
        while offset < count {
            let end = min(count, offset + step)
            let chunk = end - offset
            if chunk >= step / 2 || frames.isEmpty {
                // Use up to `nfft` samples ending at `end` so short 25 ms slices still get full FFT resolution.
                let sliceStart = max(0, end - nfft)
                let sliceCount = end - sliceStart
                let sec = Float(Double(chunk) / sampleRate)
                frames.append(analyzeSlice(samples + sliceStart, count: sliceCount, seconds: sec))
            }
            offset = end
        }
        return frames
    }

    /// Convenience helper for array inputs and deterministic unit tests.
    func processFrame(_ samples: [Float], sampleRate: Double, seconds: Float? = nil) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return Array(repeating: 0, count: Self.barCount) }
        ensureConfigured(sampleRate: sampleRate)
        let sliceCount = min(samples.count, nfft)
        let sec = seconds ?? Float(Double(samples.count) / sampleRate)
        return samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return Array(repeating: 0, count: Self.barCount) }
            return analyzeSlice(base + (samples.count - sliceCount), count: sliceCount, seconds: sec)
        }
    }

    private func analyzeSlice(_ ptr: UnsafePointer<Float>, count: Int, seconds: Float) -> [Float] {
        guard let setup = fftSetup, nfft > 0 else { return Array(repeating: 0, count: Self.barCount) }
        let copyCount = min(count, nfft)
        let pad = nfft - copyCount
        if pad > 0 {
            for i in 0..<pad { frameBuf[i] = 0 }
        }
        for i in 0..<copyCount {
            frameBuf[pad + i] = ptr[i]
        }
        vDSP_vmul(frameBuf, 1, window, 1, &frameBuf, 1, vDSP_Length(nfft))

        let half = nfft / 2
        realPart.withUnsafeMutableBufferPointer { rBuf in
            imagPart.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                frameBuf.withUnsafeBytes { rawBytes in
                    let complexPtr = rawBytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magSq, 1, vDSP_Length(half))
            }
        }

        // `vDSP_fft_zrip` scales the forward DFT by 2 (squared = 4); multiplying by 2 for +/- frequencies
        // yields `magSq / (2 * N * sum(w^2))` as RMS-equivalent band power.
        let powerScale = 1.0 / (2.0 * Float(nfft) * windowNorm)
        var rawAbove = [Float](repeating: 0, count: Self.barCount)
        var frameMax: Float = -100

        for b in 0..<Self.barCount {
            var bandPower: Float = 0
            for bin in binRanges[b] {
                bandPower += magSq[bin]
            }
            bandPower *= powerScale
            let db = 10 * log10(max(bandPower, 1e-12)) + tiltDB[b]
            let clamped = min(-38, max(-85, db))
            if let floor = bandFloorsDB[b] {
                let tau: Float = clamped < floor ? 0.20 : 6.0
                bandFloorsDB[b] = floor + (clamped - floor) * (1 - exp(-seconds / tau))
            } else {
                bandFloorsDB[b] = clamped
            }
            let floor = bandFloorsDB[b] ?? clamped
            let above = db - (floor + floorMarginsDB[b])
            rawAbove[b] = above
            if above > frameMax { frameMax = above }
        }

        let targetPeak = min(Float(36), max(Float(13), frameMax))
        let peakTau: Float = targetPeak > peakAboveDB ? 0.25 : 4.0
        peakAboveDB += (targetPeak - peakAboveDB) * (1 - exp(-seconds / peakTau))
        let span = max(Float(13), peakAboveDB)

        var bars = [Float](repeating: 0, count: Self.barCount)
        for i in 0..<Self.barCount {
            let norm = max(0, min(1, rawAbove[Self.barToBand[i]] / span))
            bars[i] = pow(norm, 1.15) * Self.barTaper[i]
        }
        return bars
    }
}

/// Strictly on-demand floating HUD panel for macOS voice dictation.
/// Never allocated until voice input is enabled and triggered; released on `unload()`.
@MainActor
public final class VoiceHUDPanelController {
    private static var _shared: VoiceHUDPanelController?

    public static var isLoaded: Bool { _shared != nil }

    public static var shared: VoiceHUDPanelController {
        if let existing = _shared {
            return existing
        }
        let created = VoiceHUDPanelController()
        _shared = created
        return created
    }

    public static func unload() {
        _shared?.hideImmediately()
        _shared?.panel.close()
        _shared = nil
    }

    private let panel: NSPanel
    private let contentView: VoiceHUDContentView
    private var hideWorkItem: DispatchWorkItem?
    private var orderOutItem: DispatchWorkItem?

    private init() {
        let initialFrame = NSRect(origin: .zero, size: VoiceHUDMetrics.canvasSize)
        let content = VoiceHUDContentView(frame: initialFrame)

        let p = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.animationBehavior = .none
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.worksWhenModal = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.contentView = content

        self.contentView = content
        self.panel = p
    }

    public func enqueueSpectrumFrames(_ frames: [[Float]]) {
        contentView.enqueueSpectrumFrames(frames)
    }

    public func show(
        state: VoiceHUDState,
        caretRect: NSRect,
        clientWindowLevel: CGWindowLevel? = nil,
        autoHideAfter: TimeInterval? = nil
    ) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if state == .hidden {
            hide()
            return
        }

        let wasHiding = orderOutItem != nil
        orderOutItem?.cancel()
        orderOutItem = nil
        let isPresenting = !panel.isVisible || wasHiding

        contentView.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if isPresenting {
            contentView.resetForPresentation()
        }
        contentView.apply(state, animated: !isPresenting)

        let caretPoint = NSPoint(x: caretRect.midX, y: caretRect.midY)
        // IMK reports a zero rect when the client has no caret; that is not a point on the primary display.
        let caretScreen = caretRect == .zero ? nil : NSScreen.screens.first(where: { $0.frame.contains(caretPoint) })
        let targetScreen = caretScreen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = VoiceHUDMetrics.canvasSize
        let targetOrigin = NSPoint(x: round(visible.midX - size.width / 2), y: round(visible.minY))

        let baseLevel = Int(CGWindowLevelForKey(.floatingWindow)) + 2
        let targetLevel = clientWindowLevel.map { max(baseLevel, Int($0) + 1) } ?? baseLevel
        if panel.level.rawValue != targetLevel {
            panel.level = NSWindow.Level(rawValue: targetLevel)
        }
        if panel.frame.origin != targetOrigin || panel.frame.size != size {
            panel.setFrame(NSRect(origin: targetOrigin, size: size), display: false, animate: false)
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if isPresenting {
            animateGroup(visible: true)
        }

        if case .notice = state {
            contentView.stopAnimating()
        } else {
            contentView.startAnimating()
        }

        if let autoHideAfter {
            let item = DispatchWorkItem { [weak self] in
                self?.hide()
            }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: item)
        }
    }

    public func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        contentView.stopAnimating()
        guard panel.isVisible, orderOutItem == nil else { return }
        animateGroup(visible: false)
        let item = DispatchWorkItem { [weak self] in
            self?.finishHide()
        }
        orderOutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceHUDMetrics.fadeDuration, execute: item)
    }

    private func hideImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        orderOutItem?.cancel()
        finishHide()
    }

    private func finishHide() {
        orderOutItem = nil
        contentView.stopAnimating()
        contentView.groupLayer.removeAllAnimations()
        panel.orderOut(nil)
    }

    private func animateGroup(visible: Bool) {
        let group = contentView.groupLayer
        let reduce = contentView.reduceMotion
        let fromOpacity = group.presentation()?.opacity ?? group.opacity
        let hiddenScale = CATransform3DMakeScale(0.94, 0.94, 1)
        let fromTransform = group.presentation()?.transform ?? group.transform
        let toTransform = visible || reduce ? CATransform3DIdentity : hiddenScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        group.removeAllAnimations()
        group.opacity = visible ? 1 : 0
        group.transform = toTransform
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = visible && panelJustOrdered(fromOpacity) ? 0 : fromOpacity
        fade.toValue = visible ? 1 : 0
        var animations: [CAAnimation] = [fade]
        if !reduce {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = visible && panelJustOrdered(fromOpacity) ? hiddenScale : fromTransform
            scale.toValue = toTransform
            animations.append(scale)
        }
        let animation = CAAnimationGroup()
        animation.animations = animations
        animation.duration = VoiceHUDMetrics.fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
        group.add(animation, forKey: "presentation")
    }

    /// A fully opaque model value on a just-ordered panel means there is no fade to continue from.
    private func panelJustOrdered(_ opacity: Float) -> Bool {
        opacity >= 0.999 || opacity <= 0.001
    }
}
