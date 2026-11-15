import AppKit

/// A slider that accessibility reads as a percentage of its range instead of the
/// raw value, so 0...1 and 0...100 sliders sound alike. Accessibility ignores an
/// NSSlider and exposes its cell, so the value description lives on the cell.
final class PercentSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { PercentSliderCell.self }
        set {}
    }
}

final class PercentSliderCell: NSSliderCell {
    override func accessibilityValueDescription() -> String? {
        let fraction = (doubleValue - minValue) / (maxValue - minValue)
        return "\(Int((fraction * 100).rounded()))%"
    }
}
