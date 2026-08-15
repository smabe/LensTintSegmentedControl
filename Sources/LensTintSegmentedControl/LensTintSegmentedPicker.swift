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
            .foregroundColor: UIColor(restingTitleColor)
        ]
        control.setTitleTextAttributes(resting, for: .normal)
        control.setTitleTextAttributes(resting, for: .selected)

        let view = LensTintSegmentedControlView(control: control, accent: UIColor(accent))
        view.segmentAccessibilityLabels = segments.map { $0.accessibilityLabel ?? $0.label }
        return view
    }

    public func updateUIView(_ view: LensTintSegmentedControlView, context: Context) {
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
}
