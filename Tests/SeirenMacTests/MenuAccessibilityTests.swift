import AppKit
import SeirenKit
import XCTest
@testable import seiren_mac

/// Accessibility ignores a single-cell control and exposes its cell, so these
/// tests read the label, value and visibility from the cells VoiceOver reads.
@MainActor
final class MenuAccessibilityTests: XCTestCase {
    func testMeterDescribesSpeechAndHoldsTheMostRecentClipForTwoSeconds() {
        let meter = LevelMeterView(readPeak: { 0 }, readClip: { false })
        XCTAssertTrue(meter.isAccessibilityElement())
        XCTAssertEqual(meter.accessibilityRole(), .levelIndicator)
        XCTAssertEqual(meter.accessibilityLabel(), "Seiren FX input level")
        XCTAssertEqual(meter.accessibilityValueDescription(), "Silence")

        meter.update(peak: 0.5, inputClipped: false, at: 10)
        XCTAssertEqual(meter.accessibilityValueDescription(), "-6 dBFS")
        meter.update(peak: 0.891, inputClipped: true, at: 11)
        XCTAssertEqual(meter.accessibilityValueDescription(), "-1 dBFS, clipped")
        meter.update(peak: 0.891, inputClipped: true, at: 12)
        meter.update(peak: 0.25, inputClipped: false, at: 13.99)
        XCTAssertEqual(meter.accessibilityValueDescription(), "-12 dBFS, clipped")
        meter.update(peak: 0.25, inputClipped: false, at: 14)
        XCTAssertEqual(meter.accessibilityValueDescription(), "-12 dBFS")
    }

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

    func testMixerRowMuteButtonCarriesItsLabelAndValueOnItsCell() throws {
        let unmuted = MixerChannelView(channel: MixerEngine.Channel(source: .voice, name: "Voice", level: 0.7),
                                       icon: nil) { _ in }
        let unmutedCell = try muteCell(in: unmuted)
        XCTAssertEqual(unmutedCell.accessibilityLabel(), "Voice: Mute on stream")
        XCTAssertEqual(unmutedCell.accessibilityValue() as? String, "Unmuted")

        let muted = MixerChannelView(channel: MixerEngine.Channel(source: .voice, name: "Voice", level: 0.7,
                                                                  muted: true),
                                     icon: nil) { _ in }
        let mutedCell = try muteCell(in: muted)
        XCTAssertEqual(mutedCell.accessibilityLabel(), "Voice: Unmute on stream")
        XCTAssertEqual(mutedCell.accessibilityValue() as? String, "Muted")
    }

    func testMixerRowMuteButtonLabelAndValueFollowUpdates() throws {
        let row = MixerChannelView(channel: MixerEngine.Channel(source: .voice, name: "Voice", level: 0.7),
                                   icon: nil) { _ in }
        let cell = try muteCell(in: row)

        row.update(MixerEngine.Channel(source: .app(bundleID: "com.example.music"), name: "Music",
                                       level: 0.25, muted: true))
        XCTAssertEqual(cell.accessibilityLabel(), "Music: Unmute on stream")
        XCTAssertEqual(cell.accessibilityValue() as? String, "Muted")

        row.update(MixerEngine.Channel(source: .app(bundleID: "com.example.music"), name: "Music",
                                       level: 0.25, muted: false))
        XCTAssertEqual(cell.accessibilityLabel(), "Music: Mute on stream")
        XCTAssertEqual(cell.accessibilityValue() as? String, "Unmuted")
    }

    func testMixerRowHidesItsNameValueAndIconFromAccessibility() throws {
        let row = MixerChannelView(channel: MixerEngine.Channel(source: .voice, name: "Voice", level: 0.7),
                                   icon: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)) { _ in }
        let fields = row.subviews.compactMap { $0 as? NSTextField }
        let name = try XCTUnwrap(fields.first { $0.stringValue == "Voice" })
        let value = try XCTUnwrap(fields.first { $0.stringValue == "70%" })
        let icon = try XCTUnwrap(row.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertEqual(name.cell?.isAccessibilityElement(), false)
        XCTAssertEqual(value.cell?.isAccessibilityElement(), false)
        XCTAssertEqual(icon.cell?.isAccessibilityElement(), false)

        // VoiceOver reaches only the slider and the mute button.
        let slider = try XCTUnwrap(row.subviews.compactMap { $0 as? PercentSlider }.first)
        let exposed = try XCTUnwrap(row.accessibilityChildren()).map { $0 as AnyObject }
        XCTAssertEqual(exposed.count, 2)
        XCTAssertTrue(exposed.contains { $0 === slider.cell })
        XCTAssertTrue(exposed.contains { $0 === (try? muteCell(in: row)) })
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

    func testPercentSliderWithAnEmptyRangeReadsZeroPercent() throws {
        let slider = PercentSlider(value: 5, minValue: 5, maxValue: 5, target: nil, action: nil)
        XCTAssertEqual(slider.cell?.accessibilityValueDescription(), "0%")
    }

    private func muteCell(in row: MixerChannelView) throws -> NSCell {
        try XCTUnwrap(row.subviews.compactMap { $0 as? NSButton }.first?.cell)
    }

    private func caption(in view: NSView) throws -> NSTextField {
        try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
    }
}
