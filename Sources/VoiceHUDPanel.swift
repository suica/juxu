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

    func resetForPresentation() {
        smoothedLevel = 0
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
        let levelTau: CGFloat = targetLevel > smoothedLevel ? 0.03 : 0.13
        smoothedLevel += (targetLevel - smoothedLevel) * (1 - exp(-CGFloat(dt) / levelTau))

        // Below the gate the bars collapse to a straight line of dots.
        let gated = max(0, (smoothedLevel - 0.04) / 0.96)
        let energy = pow(gated, 0.65)
        let dot = VoiceHUDMetrics.barWidth
        let span = VoiceHUDMetrics.barMaxHeight - dot

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<barLayers.count {
            var target = dot
            if mode == .listening, energy > 0 {
                let phase = Double(i) * 2.399
                let wobble = reduceMotion
                    ? 1.0
                    : 0.74 + 0.26 * (0.5 + 0.5 * sin(clock * 11.0 + phase) * cos(clock * 6.7 + phase * 1.7))
                target = dot + span * energy * barEnvelope[i] * CGFloat(wobble)
            }
            let tau: CGFloat = target > barHeights[i] ? 0.028 : 0.1
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
