import AppKit
import XCTest
@testable import seiren_mac

/// Accessibility ignores a single-cell control and exposes its cell, so these
/// tests read the label, value and visibility from the cells VoiceOver reads.
@MainActor
final class MenuAccessibilityTests: XCTestCase {
    func testPercentSliderDescribesItsValueAsAPercentageOfItsRange() throws {
        let unit = PercentSlider(value: 0.42, minValue: 0, maxValue: 1, target: nil, action: nil)
        let unitCell = try XCTUnwrap(unit.cell)
        XCTAssertEqual(unitCell.accessibilityValueDescription(), "42%")
        unit.doubleValue = 1
        XCTAssertEqual(unitCell.accessibilityValueDescription(), "100%")

        let percent = PercentSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
        let percentCell = try XCTUnwrap(percent.cell)
        XCTAssertEqual(percentCell.accessibilityValueDescription(), "0%")
        percent.doubleValue = 75
        XCTAssertEqual(percentCell.accessibilityValueDescription(), "75%")
    }

    func testSliderItemLabelsTheSliderAndHidesTheCaptionFromAccessibility() throws {
        let slider = PercentSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        let item = AppDelegate.sliderItem(caption: "Volume", label: "Headphone monitor volume", slider: slider)

        let view = try XCTUnwrap(item.view)
        XCTAssertTrue(slider.superview === view)
        let cell = try XCTUnwrap(slider.cell)
        XCTAssertEqual(cell.accessibilityLabel(), "Headphone monitor volume")
        XCTAssertEqual(cell.accessibilityValueDescription(), "50%")

        let caption = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(caption.stringValue, "Volume")
        XCTAssertEqual(caption.cell?.isAccessibilityElement(), false)
    }
}
