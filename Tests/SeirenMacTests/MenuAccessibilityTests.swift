import AppKit
import SeirenKit
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
    func testVolumeItemLabelsItsSliderAndReadsAPercentage() throws {
        let (item, slider) = AppDelegate.volumeItem(level: 0.37, enabled: true, target: nil)
        let view = try XCTUnwrap(item.view)
        XCTAssertEqual(view.subviews.compactMap { $0 as? PercentSlider }, [slider])
        let cell = try XCTUnwrap(slider.cell)
        XCTAssertEqual(cell.accessibilityLabel(), "Headphone monitor volume")
        XCTAssertEqual(cell.accessibilityValueDescription(), "37%")
        XCTAssertEqual(try caption(in: view).stringValue, "Volume")
        XCTAssertEqual(try caption(in: view).cell?.isAccessibilityElement(), false)
    }

    func testBrightnessItemLabelsItsSliderAndReadsAPercentage() throws {
        let item = AppDelegate.lightingBrightnessItem(percent: 64, target: nil)
        let view = try XCTUnwrap(item.view)
        let slider = try XCTUnwrap(view.subviews.compactMap { $0 as? PercentSlider }.first)
        XCTAssertEqual(slider.maxValue, 100)
        let cell = try XCTUnwrap(slider.cell)
        XCTAssertEqual(cell.accessibilityLabel(), "Lighting brightness")
        XCTAssertEqual(cell.accessibilityValueDescription(), "64%")
        XCTAssertEqual(try caption(in: view).stringValue, "Brightness")
        XCTAssertEqual(try caption(in: view).cell?.isAccessibilityElement(), false)
    }

    func testMixerRowLabelsItsSliderAndFollowsUpdates() throws {
        let channel = MixerEngine.Channel(source: .voice, name: "Voice", level: 0.7)
        let row = MixerChannelView(channel: channel, icon: nil) { _ in }
        let slider = try XCTUnwrap(row.subviews.compactMap { $0 as? PercentSlider }.first)
        let cell = try XCTUnwrap(slider.cell)
        XCTAssertEqual(cell.accessibilityLabel(), "Voice level on stream")
        XCTAssertEqual(cell.accessibilityValueDescription(), "70%")

        row.update(MixerEngine.Channel(source: .app(bundleID: "com.example.music"), name: "Music",
                                       level: 0.25, muted: true))
        XCTAssertEqual(cell.accessibilityLabel(), "Music level on stream")
        XCTAssertEqual(cell.accessibilityValueDescription(), "25%")
    }

    func testPercentSliderReadsEdgeAndOutOfRangeValuesAsTheClampedPercentage() throws {
        let unit = PercentSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        let unitCell = try XCTUnwrap(unit.cell)
        let expected: [(Double, String)] = [
            (0, "0%"), (1, "100%"), (0.004, "0%"), (0.005, "1%"), (0.994, "99%"), (0.995, "100%"),
            (1.5, "100%"), (-0.5, "0%"),
        ]
        for (value, description) in expected {
            unit.doubleValue = value
            XCTAssertEqual(unitCell.accessibilityValueDescription(), description, "\(value)")
        }

        let percent = PercentSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
        let percentCell = try XCTUnwrap(percent.cell)
        for (value, description) in [(100.0, "100%"), (250.0, "100%"), (-20.0, "0%"), (0.4, "0%"), (99.6, "100%")] {
            percent.doubleValue = value
            XCTAssertEqual(percentCell.accessibilityValueDescription(), description, "\(value)")
        }

        let item = AppDelegate.lightingBrightnessItem(percent: 180, target: nil)
        let slider = try XCTUnwrap(item.view?.subviews.compactMap { $0 as? PercentSlider }.first)
        XCTAssertEqual(slider.cell?.accessibilityValueDescription(), "100%")
    }

    private func caption(in view: NSView) throws -> NSTextField {
        try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
    }
}
