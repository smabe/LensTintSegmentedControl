import UIKit
import os

/// A real `UISegmentedControl` (system Liquid Glass thumb kept) with a
/// lens-POSITIONAL accent grafted on, the way the system Health app's picker
/// behaves: the title colours are neutralized so no colour comes from
/// selection, and an accent copy of the label row — double-masked by glyph
/// alpha and the live lens silhouette — is injected into the control's own
/// segment container. The lens's position, not the selected state, decides
/// which glyph pixels are accented, which is what lets one glyph be half
/// accent and half resting at the rim.
///
/// The injection point is load-bearing. During a hold the system erases its
/// label row under the glass (destination-out compositing) and portal-redraws
/// it MAGNIFIED; an overlay ABOVE the control loses that fight (the magnified
/// resting-colour image draws over the unmagnified accent copy). Living inside
/// the sampled row means the accent copy is erased, re-rendered, magnified and
/// chromatically fringed in lockstep with the labels it shadows.
///
/// It reaches into a PRIVATE view hierarchy — subview walking, frame reads and
/// one `addSubview`, matched by class-name substring; nothing is messaged
/// beyond `UIView`/`UILabel`. Because that can break on any OS update, the
/// view watches its own lookups: if they fail for `fallbackThreshold` seconds
/// it removes the graft and restores a state-keyed accent `.selected` title,
/// degrading to plain native styling instead of an accentless control.
///
/// The commit contract: the control can fire `valueChanged` per segment
/// crossing during a thumb drag, so the selection callback is deferred until
/// the touch ends — `onCommit` fires once per gesture. A CANCELLED gesture
/// (incoming call, system sheet) rolls the control back to the committed
/// selection instead of committing mid-drag state. Programmatic index writes
/// fire no actions (UIKit-documented), so external writes cannot echo.
@MainActor
public final class LensTintSegmentedControlView: UIView {

    public let control: UISegmentedControl

    /// Fires once per user gesture, on release, with the settled index.
    public var onCommit: ((Int) -> Void)?

    /// Spoken labels, one per segment, re-asserted onto the segment views
    /// whenever the label row changes (short titles like "3M" read as bare
    /// letters otherwise).
    public var segmentAccessibilityLabels: [String] = [] {
        didSet { lastGlyphSignature = "" }
    }

    /// Feather width of the accent mask's edge, in points.
    public var softness: Double = 10 {
        didSet { if softness != lastSoftness { rebuildLensMaskImage(force: true) } }
    }

    /// Ceiling on the system thumb's RESTING platter fill, 0…1 (1 = stock).
    ///
    /// The settled thumb's milky look is a plain fill view inside the lens
    /// that the system fades IN on settle (alpha 0 while held, 1 settled —
    /// observed via hierarchy dumps); the glass itself is mostly clear.
    /// Capping that view's alpha each tick lets the fade land at this ceiling
    /// instead of full opacity. The held state is untouched (the system holds
    /// it at 0, and a cap never raises).
    public var restingFillAlpha: Double = 1 {
        didSet {
            guard restingFillAlpha != oldValue else { return }
            // A cap can only lower; an upward change needs one explicit
            // re-raise at rest (the system re-raises on its own only when it
            // next fades the platter in).
            if restingFillAlpha > oldValue { fillRaisePending = true }
            noteActivity()
        }
    }
    private var fillRaisePending = false

    /// How much the RAIL grows while the lens is held, as a fraction at full
    /// lift (0 = stock). Health's picker grows its rail ~20-25% around its own
    /// center in sync with the lens lift; the stock control keeps its rail
    /// pinned.
    public var railGrowth: Double = 0 {
        didSet { if railGrowth != oldValue { noteActivity() } }
    }
    /// How much the rail DENSIFIES while held: peak alpha of a black capsule
    /// wash between the rail and its labels (0 = stock). Health's rail
    /// occludes the content behind it noticeably more while held.
    public var railDensify: Double = 0 {
        didSet { if railDensify != oldValue { noteActivity() } }
    }

    private let railDensifyLayer = CALayer()
    /// Displayed lift progress, 0…1, eased toward `railTouchActive` each tick.
    ///
    /// Deliberately NOT derived from the lens's height: the liquid lens bobs
    /// while travelling between segments, and a rail keyed to its geometry
    /// visibly oscillates. (`isTracking` cannot gate it either — the control's
    /// thumb drag bypasses UIControl tracking entirely, so `isTracking` stays
    /// false and `.touchDown` actions never fire.) Health's model: grow on
    /// touch, hold while held, relax on release. A touch drives it.
    private var railProgress = 0.0
    /// True while any touch is down on the control, from our own recognizer —
    /// the one reliable signal (no `.touchDown` action, no `isTracking`).
    private var railTouchActive = false

    private let accent: UIColor

    /// The injected accent copy. Lives inside the control's segment container.
    private let overlay = UIView()
    private let accentLayer = CALayer()
    private let glyphMask = CALayer()
    private let lensMask = CALayer()
    private var displayLink: CADisplayLink?
    private weak var lensView: UIView?
    private weak var segmentContainer: UIView?
    private var lastLensImageSize = CGSize.zero
    private var lastSoftness = -1.0
    private var lastGlyphSignature = ""

    /// Seconds the private-hierarchy lookups have failed for, from
    /// display-link timestamps (callback COUNTS mislead: link frequency varies
    /// with Low Power Mode, thermals and display refresh rate).
    private var lookupFailSeconds = 0.0
    /// Beyond this the graft is abandoned for this instance.
    private let fallbackThreshold = 1.0
    private var isFallenBack = false

    /// Seconds with nothing moving; drives the idle pause.
    private var stillSeconds = 0.0
    private var lastLensFrame = CGRect.zero
    private var pendingCommitIndex: Int?
    /// The last selection the outside world knows about — written by
    /// `applySelection` (programmatic sync) and by the commit flush. A
    /// CANCELLED gesture restores the control here instead of committing.
    private var committedIndex = 0

    /// True from touch-down until the gesture's outcome is delivered — the
    /// window in which external selection syncs must not fight the finger.
    public var isUserInteracting: Bool {
        railTouchActive || pendingCommitIndex != nil
    }

    /// Programmatic selection sync (for binding writes). Also the anchor a
    /// cancelled gesture rolls back to.
    public func applySelection(index: Int) {
        committedIndex = index
        guard control.selectedSegmentIndex != index else { return }
        control.selectedSegmentIndex = index
        // Programmatic writes fire no control actions; wake the tracking loop
        // so the lens's settle slide is masked correctly.
        noteActivity()
    }

    public init(control: UISegmentedControl, accent: UIColor) {
        self.control = control
        self.accent = accent
        super.init(frame: .zero)
        addSubview(control)

        overlay.isUserInteractionEnabled = false
        accentLayer.backgroundColor = accent.cgColor
        accentLayer.mask = glyphMask
        overlay.layer.addSublayer(accentLayer)
        overlay.layer.mask = lensMask

        control.addTarget(self, action: #selector(controlChanged), for: .valueChanged)

        // Touch presence for the rail lift. minimumPressDuration 0 fires on
        // contact; cancelsTouchesInView false + simultaneous recognition keep
        // the control's own gestures untouched.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(railTouch(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.delegate = self
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // bounds + center, never `frame`: the rail lift scales the control's
        // transform, and setting frame on a transformed view is undefined.
        control.bounds = CGRect(origin: .zero, size: bounds.size)
        control.center = CGPoint(x: bounds.midX, y: bounds.midY)
        // The glyph mask is NOT rebuilt here: the control lays out its
        // segments AFTER this pass, so label frames read stale. The tick
        // rebuilds once the frames settle.
        noteActivity()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Kicks the tracking loop out of its idle pause. Called automatically on
    /// touches, control events, layout, and programmatic selection writes.
    public func noteActivity() {
        stillSeconds = 0
        displayLink?.isPaused = false
    }

    /// The idle pause's resume trigger. `UISegmentedControl` sends NO
    /// `.touchDown` action and, on a fast flick, fires `.valueChanged` only at
    /// release — with those as the wake-ups the link sleeps through the whole
    /// drag. Every touch routes through hitTest before the control sees it, so
    /// this is the one reliable earliest hook.
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        noteActivity()
        return super.hitTest(point, with: event)
    }

    // MARK: - Control events

    @objc private func railTouch(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            railTouchActive = true
        case .ended:
            railTouchActive = false
        case .cancelled, .failed:
            // An interrupted gesture (incoming call, system sheet) is not a
            // choice: discard the pending index and put the thumb back on the
            // committed selection instead of committing mid-drag state.
            railTouchActive = false
            pendingCommitIndex = nil
            control.selectedSegmentIndex = committedIndex
        default:
            break
        }
        noteActivity()
    }

    @objc private func controlChanged() {
        // May fire per segment crossing during a slow drag, or once at release
        // on a fast flick; deferring to end-of-touch makes both shapes commit
        // exactly once per gesture.
        pendingCommitIndex = control.selectedSegmentIndex
        noteActivity()
    }

    // MARK: - Per-refresh drive

    @objc private func tick(_ link: CADisplayLink) {
        // Real elapsed time, not a callback count: the link's rate varies with
        // Low Power Mode, thermals and ProMotion, and the tuned feel must not
        // change with it.
        let dt = max(link.targetTimestamp - link.timestamp, 0)
        flushPendingCommitIfReleased()

        guard !isFallenBack else {
            pauseIfStill(lensFrame: .zero, dt: dt)
            return
        }
        guard let container = findSegmentContainer(), let lens = findLensView(),
              let lensSuperlayer = lens.layer.superlayer else {
            lookupFailSeconds += dt
            if lookupFailSeconds >= fallbackThreshold { engageFallback() }
            return
        }
        lookupFailSeconds = 0

        // (Re)inject on top of the segments — the control rebuilds parts of
        // its tree on trait/selection changes, so ownership is re-asserted
        // rather than assumed.
        if overlay.superview !== container {
            container.addSubview(overlay)
        }
        container.bringSubviewToFront(overlay)
        if overlay.frame != container.bounds {
            overlay.frame = container.bounds
            CATransaction.withoutActions {
                accentLayer.frame = overlay.bounds
                glyphMask.frame = overlay.bounds
            }
        }

        // Presentation layer so the settle animation after release is tracked,
        // not just the model jumps during the drag.
        let live = lens.layer.presentation() ?? lens.layer
        let lensFrame = overlay.layer.convert(live.frame, from: lensSuperlayer)
        CATransaction.withoutActions {
            lensMask.opacity = 1
            lensMask.frame = lensFrame
        }
        rebuildLensMaskImage(force: false)
        rebuildGlyphMaskIfLabelsMoved()
        applyRestingFillCap(on: lens)
        applyRailLift(dt: dt)
        pauseIfStill(lensFrame: lensFrame, dt: dt)
    }

    /// False while the post-release decay is still converging — keeps the
    /// idle pause from freezing the rail mid-relax.
    private var railSettled = true

    /// See `railGrowth`/`railDensify`. The WHOLE control scales as one
    /// floating bar — the way Health's picker behaves. Scaling the four
    /// segment-background images individually does NOT work: the control's
    /// own layout fights per-subview transforms between ticks (growth caps
    /// and seams open at segment boundaries). Transforming the control itself
    /// leaves its internal layout in untransformed space, so there is nothing
    /// to fight — and the labels grow slightly with the bar, matching Health.
    /// The densify wash lives inside the control's layer, so it scales free.
    private func applyRailLift(dt: Double) {
        guard railGrowth > 0 || railDensify > 0 else {
            railSettled = true
            return
        }
        // Touch-driven: ease toward 1 while a finger is down (0.1s time
        // constant), toward 0 after release (0.2s relax) — exponential in
        // REAL time so the feel is refresh-rate independent. No lens geometry
        // in the loop, so the lens's travel wobble cannot reach the rail. The
        // lift is ADDED motion, so it honors Reduce Motion by staying flat
        // (the system's own lens lift remains the system's choice).
        let target = railTouchActive && !UIAccessibility.isReduceMotionEnabled ? 1.0 : 0.0
        let tau = target > railProgress ? 0.1 : 0.2
        railProgress += (target - railProgress) * (1 - exp(-dt / tau))
        if abs(railProgress - target) < 0.005 { railProgress = target }
        railSettled = railProgress == target
        let progress = railProgress

        let scale = 1 + railGrowth * progress
        control.transform = scale == 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)

        if railDensify > 0,
           let topRail = control.subviews.last(where: { $0 is UIImageView }) {
            // Above the rail images, below the label/lens subtree.
            control.layer.insertSublayer(railDensifyLayer, above: topRail.layer)
        }
        CATransaction.withoutActions {
            railDensifyLayer.frame = control.bounds
            railDensifyLayer.cornerRadius = control.bounds.height / 2
            railDensifyLayer.backgroundColor = UIColor.black.cgColor
            railDensifyLayer.opacity = Float(railDensify * progress)
        }
    }

    /// See `restingFillAlpha`. Targets only PLAIN `UIView` children of the
    /// lens's host view — the fill is the one non-subclassed sibling of the
    /// glass pipeline's views there — so the glass itself is never touched.
    /// Re-asserted per tick: the system re-raises the alpha on every settle,
    /// and a cap that runs once would be undone by the next fade-in.
    private func applyRestingFillCap(on lens: UIView) {
        guard restingFillAlpha < 1 || fillRaisePending else { return }
        guard let host = lens.subviews.first else { return }
        let raise = fillRaisePending && !railTouchActive
        for sub in host.subviews where type(of: sub) == UIView.self {
            if sub.alpha > restingFillAlpha {
                sub.alpha = restingFillAlpha
            } else if raise, sub.alpha < restingFillAlpha {
                // Only at rest: while held the system deliberately keeps the
                // platter at 0 and a raise here would fight it.
                sub.alpha = restingFillAlpha
            }
        }
        if raise { fillRaisePending = false }
    }

    /// Gated on OUR touch signal, not `control.isTracking` — the control's
    /// thumb drag bypasses UIControl tracking, so `isTracking` reads false
    /// mid-gesture and would flush per-crossing `valueChanged`s while the
    /// finger is still down, committing more than once per gesture.
    private func flushPendingCommitIfReleased() {
        guard let pending = pendingCommitIndex, !railTouchActive else { return }
        pendingCommitIndex = nil
        committedIndex = pending
        onCommit?(pending)
    }

    private func pauseIfStill(lensFrame: CGRect, dt: Double) {
        // `railTouchActive`, not `isTracking` (see above): a stationary hold
        // must keep the link alive — nothing re-fires hitTest mid-gesture, so
        // a pause here would freeze the mask until the first crossing.
        let still = !railTouchActive && pendingCommitIndex == nil
            && lensFrame == lastLensFrame && railSettled
        lastLensFrame = lensFrame
        stillSeconds = still ? stillSeconds + dt : 0
        // 1.5s of nothing moving: stop burning a display link on a parked
        // lens. Touch events and programmatic writes resume it.
        if stillSeconds > 1.5 { displayLink?.isPaused = true }
    }

    /// The graft could not find the system's hierarchy (an OS change, most
    /// likely). Degrade to plain native styling: glass thumb, accent
    /// STATE-keyed selected title. Positional tint is lost; an accented,
    /// fully-native control remains.
    private func engageFallback() {
        isFallenBack = true
        overlay.removeFromSuperview()
        control.setTitleTextAttributes([.foregroundColor: accent], for: .selected)
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "LensTintSegmentedControl",
            category: "LensTint"
        )
        .info("Lens graft fell back to state-keyed tint: lens=\(self.findLensView() != nil), container=\(self.findSegmentContainer() != nil)")
    }

    // MARK: - Private-tree lookups (subview walking + frames only)

    private func findLensView() -> UIView? {
        if let lensView, lensView.window != nil { return lensView }
        lensView = firstSubview(of: control) { $0.contains("LiquidLens") }
        return lensView
    }

    /// The view that directly holds the `UISegment`s — the row the system's
    /// portal samples, which is what makes it the right home for the overlay.
    private func findSegmentContainer() -> UIView? {
        if let segmentContainer, segmentContainer.window != nil { return segmentContainer }
        segmentContainer = firstSubview(of: control) { $0 == "UISegment" }?.superview
        return segmentContainer
    }

    private func firstSubview(of view: UIView, matching: (String) -> Bool) -> UIView? {
        for sub in view.subviews {
            if matching(String(describing: type(of: sub))) { return sub }
            if let hit = firstSubview(of: sub, matching: matching) { return hit }
        }
        return nil
    }

    // MARK: - Masks

    /// Rebuild keyed to where the labels actually ARE, not to our own layout
    /// pass — the control lays its segments out after us.
    private func rebuildGlyphMaskIfLabelsMoved() {
        let labels = allLabels(in: control)
        guard !labels.isEmpty else { return }
        let signature = labels
            .map { "\($0.text ?? "")\($0.convert($0.bounds, to: overlay))" }
            .joined()
        guard signature != lastGlyphSignature else { return }
        lastGlyphSignature = signature
        rebuildGlyphMask(labels: labels)
        applyAccessibilityLabels()
    }

    /// White-on-clear render of the control's own label row: same text, same
    /// font, same frames, read live from the control's labels. Its alpha is
    /// what confines the accent to glyph pixels.
    private func rebuildGlyphMask(labels: [UILabel]) {
        let size = overlay.bounds.size
        guard size.width > 0 else { return }
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            for label in labels {
                guard let text = label.text else { continue }
                let rect = label.convert(label.bounds, to: overlay)
                (text as NSString).draw(
                    in: rect,
                    withAttributes: [.font: label.font as Any, .foregroundColor: UIColor.white]
                )
            }
        }
        CATransaction.withoutActions { glyphMask.contents = image.cgImage }
    }

    private func allLabels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { sub -> [UILabel] in
            if let label = sub as? UILabel { return [label] }
            return allLabels(in: sub)
        }
    }

    /// Short titles read as bare letters under VoiceOver; give each segment
    /// view its spoken label instead, left-to-right.
    private func applyAccessibilityLabels() {
        guard !segmentAccessibilityLabels.isEmpty, let container = segmentContainer else { return }
        let segments = container.subviews
            .filter { String(describing: type(of: $0)) == "UISegment" }
            .sorted { $0.frame.minX < $1.frame.minX }
        for (segment, label) in zip(segments, segmentAccessibilityLabels) {
            segment.accessibilityLabel = label
        }
    }

    /// Feathered capsule the size of the live lens. Regenerated only when the
    /// lens SIZE changes (the lift/settle moments) — position changes just
    /// move the layer. The feather is a ring-stack approximation of a gaussian
    /// edge, inset so the ramp stays INSIDE the silhouette (a feather past the
    /// rim would tint glyphs the lens is not over).
    private func rebuildLensMaskImage(force: Bool) {
        let size = lensMask.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let grewOrShrank = abs(size.width - lastLensImageSize.width) > 0.5
            || abs(size.height - lastLensImageSize.height) > 0.5
        guard force || grewOrShrank else { return }
        lastLensImageSize = size
        lastSoftness = softness

        let soft = min(softness, Double(size.height) / 2 - 1)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let full = CGRect(origin: .zero, size: size)
            let core = full.insetBy(dx: soft, dy: soft)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: core, cornerRadius: core.height / 2).fill()
            guard soft > 0.5 else { return }
            let rings = 10
            let step = soft / Double(rings)
            for ring in 0..<rings {
                let inset = soft - step * Double(ring + 1)
                let rect = full.insetBy(dx: inset, dy: inset)
                let alpha = 1.0 - Double(ring + 1) / Double(rings + 1)
                UIColor.white.withAlphaComponent(alpha).setStroke()
                let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
                path.lineWidth = step
                path.stroke()
            }
        }
        CATransaction.withoutActions { lensMask.contents = image.cgImage }
    }
}

extension LensTintSegmentedControlView: UIGestureRecognizerDelegate {
    /// The press recognizer only OBSERVES touch presence; it must never win a
    /// gesture arbitration against the control's own recognizers.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension CATransaction {
    @MainActor
    static func withoutActions(_ body: () -> Void) {
        begin()
        setDisableActions(true)
        body()
        commit()
    }
}
