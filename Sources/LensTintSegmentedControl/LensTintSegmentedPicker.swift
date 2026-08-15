import SwiftUI

/// One segment of a `LensTintSegmentedPicker`.
public struct LensTintSegment<Value: Hashable> {
    /// The value the binding takes when this segment is selected.
    public let value: Value
    /// The rendered title.
    public let label: String
    /// The spoken label. Short titles like "3M" read as bare letters under
    /// VoiceOver; pass a full phrase ("Last 90 days"). `nil` keeps the title.
    public let accessibilityLabel: String?

    public init(value: Value, label: String, accessibilityLabel: String? = nil) {
        self.value = value
        self.label = label
        self.accessibilityLabel = accessibilityLabel
    }
}

/// A native `UISegmentedControl` carrying the lens-positional accent graft
/// (`LensTintSegmentedControlView`): the system's Liquid Glass thumb is kept,
/// and glyphs take the accent colour exactly where the glass covers them —
/// the way the system Health app's picker behaves — instead of by selected
/// state.
///
/// Both title states are pinned to the resting tier: in this control no
/// colour may come from selection, because the accent belongs to the lens's
/// POSITION. At rest the lens parks on the selected segment, so the selected
/// label still reads accented.
///
/// **Commit contract:** the binding is written once per gesture, on release —
/// per-crossing `valueChanged`s are deferred until the touch ends, and a
/// cancelled gesture (incoming call, system sheet) rolls back instead of
/// committing. External binding writes are never applied while a finger is
/// on the control.
///
/// Segments are fixed at creation, the same assumption the native control's
/// initializer makes.
public struct LensTintSegmentedPicker<Value: Hashable>: UIViewRepresentable {

    @Binding private var selection: Value
    /// Read so a live Dynamic Type change re-invokes `updateUIView` — SwiftUI
    /// neither remounts the backing control nor re-applies appearance proxies
    /// to a view already in a window, so this dependency is the only thing
    /// that carries a live size change in.
    @Environment(\.dynamicTypeSize) private var typeSize
    private let segments: [LensTintSegment<Value>]
    private let accent: Color
    private let restingTitleColor: Color
    private let restingFillAlpha: Double
    private let railGrowth: Double
    private let railDensify: Double
    private let softness: Double

    /// - Parameters:
    ///   - selection: Bound selected value. Written once per gesture, on
    ///     release.
    ///   - segments: The rendered segments, in order.
    ///   - accent: The lens-positional accent colour.
    ///   - restingTitleColor: Title colour outside the lens (both control
    ///     states are pinned to it).
    ///   - restingFillAlpha: Ceiling on the resting thumb's platter fill,
    ///     0…1 (1 = stock). Lower values keep the settled thumb closer to
    ///     clear glass — useful over dark backgrounds where the stock platter
    ///     reads milky.
    ///   - railGrowth: How much the whole bar grows while the lens is held,
    ///     as a fraction (0 = stock). Health uses roughly 0.2; subtler values
    ///     read well on tighter layouts.
    ///   - railDensify: Peak alpha of a black wash that densifies the held
    ///     rail (0 = stock).
    ///   - softness: Feather width of the accent mask's edge, in points.
    public init(
        selection: Binding<Value>,
        segments: [LensTintSegment<Value>],
        accent: Color,
        restingTitleColor: Color = Color(uiColor: .secondaryLabel),
        restingFillAlpha: Double = 0.5,
        railGrowth: Double = 0.10,
        railDensify: Double = 0.25,
        softness: Double = 10
    ) {
        _selection = selection
        self.segments = segments
        self.accent = accent
        self.restingTitleColor = restingTitleColor
        self.restingFillAlpha = restingFillAlpha
        self.railGrowth = railGrowth
        self.railDensify = railDensify
        self.softness = softness
    }

    public func makeUIView(context: Context) -> LensTintSegmentedControlView {
        let control = UISegmentedControl(items: segments.map(\.label))
        // nil segment tint keeps the system's Liquid Glass thumb — any colour
        // there replaces it with a flat fill.
        control.selectedSegmentTintColor = nil
        let resting: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(restingTitleColor),
            .font: SegmentedTitleFont.scaled(for: typeSize)
        ]
        control.setTitleTextAttributes(resting, for: .normal)
        control.setTitleTextAttributes(resting, for: .selected)

        let view = LensTintSegmentedControlView(control: control, accent: UIColor(accent))
        view.segmentAccessibilityLabels = segments.map { $0.accessibilityLabel ?? $0.label }
        return view
    }

    public func updateUIView(_ view: LensTintSegmentedControlView, context: Context) {
        view.applyTitleFont(SegmentedTitleFont.scaled(for: typeSize))
        // Rebound every update: the closure writes to THIS view value's
        // binding; an older closure would write through a stale one.
        let segments = segments
        view.onCommit = { index in
            guard segments.indices.contains(index) else { return }
            selection = segments[index].value
        }
        view.restingFillAlpha = restingFillAlpha
        view.railGrowth = railGrowth
        view.railDensify = railDensify
        view.softness = softness
        // Never fight an in-flight finger: parent state changes re-enter here
        // mid-drag, and a sync against the deliberately-uncommitted binding
        // would snap the thumb back under the user's touch. The gesture's own
        // commit re-runs this update once it lands.
        guard !view.isUserInteracting else { return }
        view.applySelection(index: segments.firstIndex { $0.value == selection } ?? 0)
    }

    /// Sizes like a native segmented `Picker`: fills the width it is offered,
    /// stands the control's own height. The wrapper carries no constraints and
    /// no intrinsic size of its own, so without this the default algorithm has
    /// nothing to stand on and every call site has to name a height.
    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: LensTintSegmentedControlView,
        context: Context
    ) -> CGSize? {
        let intrinsic = uiView.control.intrinsicContentSize
        return SegmentedPickerSizing.size(
            for: proposal,
            intrinsic: intrinsic,
            railHeight: SegmentedPickerSizing.railHeight(
                intrinsic: intrinsic.height,
                titleLineHeight: SegmentedTitleFont.scaled(for: typeSize).lineHeight,
                stockLineHeight: SegmentedTitleFont.stockLineHeight
            )
        )
    }
}

/// The title font the rail renders. The stock control draws a fixed 13pt
/// system face at every Dynamic Type size and UIKit offers no opt-in — so the
/// scaled equivalent is computed here and asserted through
/// `setTitleTextAttributes`, sized off the SwiftUI environment's
/// `dynamicTypeSize` rather than the control's traits (a control not yet in a
/// window answers traits SwiftUI has not configured yet).
enum SegmentedTitleFont {

    /// The stock control's title size; the scale anchor.
    private static let stockSize: CGFloat = 13

    /// What `railHeight` treats as the line the stock rail was built around,
    /// so at the default size the computed rail is exactly stock.
    static var stockLineHeight: CGFloat {
        UIFont.systemFont(ofSize: stockSize).lineHeight
    }

    static func scaled(for size: DynamicTypeSize) -> UIFont {
        // UIContentSizeCategory(_:) is UIKit's own bridge from SwiftUI's
        // DynamicTypeSize (iOS 15+) — never hand-roll the 12-case mapping.
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .systemFont(ofSize: stockSize),
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: UIContentSizeCategory(size))
        )
    }
}

/// How the picker answers a size proposal.
///
/// The axes answer differently on purpose, which is the whole content of this
/// type. **Width is whatever is offered**, including the zero and infinity
/// probes a stack uses to measure flexibility: answering those with the
/// intrinsic width would declare the control unstretchable and it would stop
/// filling its row. **Height is the control's own** unless a call site names
/// one — that is what keeps `.frame(height:)` meaningful while leaving the
/// rail unstretched by a tall row.
enum SegmentedPickerSizing {

    /// Explicit call-site heights win; otherwise the rail stands its own
    /// font-derived height.
    static func size(
        for proposal: ProposedViewSize, intrinsic: CGSize, railHeight: CGFloat
    ) -> CGSize {
        CGSize(
            width: proposal.width ?? intrinsic.width,
            height: definiteHeight(proposal.height) ?? railHeight
        )
    }

    /// The rail's height under a Dynamic-Type-scaled title font. UIKit never
    /// grows the control for its font, so the height is computed: the
    /// intrinsic height plus however much taller the scaled font's line is
    /// than the stock one — which preserves the stock chrome around the text
    /// and makes the default size exactly the stock rail. Never below the
    /// intrinsic: small text sizes must not shrink the rail.
    static func railHeight(
        intrinsic: CGFloat, titleLineHeight: CGFloat, stockLineHeight: CGFloat
    ) -> CGFloat {
        max(intrinsic, intrinsic + (titleLineHeight - stockLineHeight))
    }

    /// A height worth honoring: a real, finite request. The zero and infinity
    /// probes are questions about flexibility, not allocations, and this
    /// control has no vertical flexibility to report.
    private static func definiteHeight(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
