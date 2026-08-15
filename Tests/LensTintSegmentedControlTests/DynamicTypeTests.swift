import SwiftUI
import XCTest
@testable import LensTintSegmentedControl

/// The Dynamic Type behavior: the rail's title font is computed (the stock
/// 13pt face scaled by footnote metrics) and its height derived from that
/// font, because `UISegmentedControl` does neither on its own.
final class DynamicTypeTests: XCTestCase {

    // MARK: - Rail height

    /// UIKit never grows the control for a scaled title font, so the height
    /// is computed, preserving the stock chrome around the text. Rules out an
    /// implementation that keeps reading the intrinsic height.
    func test_railHeight_growsByExactlyTheFontsExtraLineHeight() {
        let height = SegmentedPickerSizing.railHeight(
            intrinsic: 32, titleLineHeight: 53, stockLineHeight: 18)

        XCTAssertEqual(height, 67)
    }

    /// THE FLOOR: at the stock line height the computed rail is the intrinsic
    /// height exactly — default text size renders the stock control.
    func test_railHeight_atStockLineHeight_isTheIntrinsicHeightExactly() {
        let height = SegmentedPickerSizing.railHeight(
            intrinsic: 32, titleLineHeight: 18, stockLineHeight: 18)

        XCTAssertEqual(height, 32)
    }

    /// Small text sizes must not shrink the rail below the control's own
    /// height. Rules out applying the delta symmetrically.
    func test_railHeight_neverDipsBelowTheIntrinsicHeight() {
        let height = SegmentedPickerSizing.railHeight(
            intrinsic: 32, titleLineHeight: 14, stockLineHeight: 18)

        XCTAssertEqual(height, 32)
    }

    // MARK: - Sizing

    /// A call site's explicit height outranks the computed rail.
    func test_definiteProposedHeight_winsOverTheRailHeight() {
        let size = SegmentedPickerSizing.size(
            for: ProposedViewSize(width: 340, height: 44),
            intrinsic: CGSize(width: 180, height: 32),
            railHeight: 67
        )

        XCTAssertEqual(size.height, 44)
    }

    /// No proposal: the rail stands its own font-derived height.
    func test_noProposedHeight_answersTheRailHeight() {
        let size = SegmentedPickerSizing.size(
            for: ProposedViewSize(width: 340, height: nil),
            intrinsic: CGSize(width: 180, height: 32),
            railHeight: 67
        )

        XCTAssertEqual(size.height, 67)
    }

    /// The infinity probe is a flexibility question, not an allocation — a
    /// taller row must not stretch the rail.
    func test_infiniteProposal_keepsTheRailHeight() {
        let size = SegmentedPickerSizing.size(
            for: .infinity,
            intrinsic: CGSize(width: 180, height: 32),
            railHeight: 67
        )

        XCTAssertEqual(size.height, 67)
    }

    // MARK: - Font resolver

    /// At the default size the scaled font's line is the stock line exactly.
    /// Rules out a wrong metrics style or base size.
    func test_defaultSize_scalesToTheStockLineHeightExactly() {
        let scaled = SegmentedTitleFont.scaled(for: .large)

        XCTAssertEqual(scaled.lineHeight, SegmentedTitleFont.stockLineHeight)
    }

    /// An accessibility size must come back much larger — the whole point.
    func test_largestAccessibilitySize_scalesWellBeyondStock() {
        let scaled = SegmentedTitleFont.scaled(for: .accessibility5)

        XCTAssertGreaterThan(scaled.lineHeight, SegmentedTitleFont.stockLineHeight * 2)
    }

    /// Point size never decreases up the ladder — catches the UIKit bridge
    /// being replaced with a mapping that misorders a case.
    func test_pointSizeIsMonotonicAcrossTheWholeSizeLadder() {
        let ladder: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5
        ]

        let pointSizes = ladder.map { SegmentedTitleFont.scaled(for: $0).pointSize }

        XCTAssertEqual(pointSizes, pointSizes.sorted())
    }

    // MARK: - Title attribute application

    /// `applyTitleFont` merges the font into BOTH states without disturbing
    /// the colours each state carries — a replace-not-merge implementation
    /// would strip the resting colour from one state or the other.
    @MainActor
    func test_applyTitleFont_setsBothStatesAndPreservesColors() {
        let control = UISegmentedControl(items: ["W", "M"])
        control.setTitleTextAttributes([.foregroundColor: UIColor.red], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.green], for: .selected)
        let view = LensTintSegmentedControlView(control: control, accent: .green)

        view.applyTitleFont(UIFont.systemFont(ofSize: 40))

        let normal = control.titleTextAttributes(for: .normal)
        let selected = control.titleTextAttributes(for: .selected)
        XCTAssertEqual((normal?[.font] as? UIFont)?.pointSize, 40)
        XCTAssertEqual((selected?[.font] as? UIFont)?.pointSize, 40)
        XCTAssertEqual(normal?[.foregroundColor] as? UIColor, .red)
        XCTAssertEqual(selected?[.foregroundColor] as? UIColor, .green)
    }
}
