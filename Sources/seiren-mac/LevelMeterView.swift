import AppKit

/// Peak level of the processed voice sent to Seiren FX. The bar spans -60 to
/// 0 dBFS. A separate mark holds for two seconds after the raw microphone
/// input reaches full scale.
@MainActor
final class LevelMeterView: NSView {
    private let readPeak: @MainActor () -> Float
    private let readClip: @MainActor () -> Bool
    private var timer: Timer?
    private var peak: Float = 0
    private var clipUntil: TimeInterval = 0
    private var clipped = false

    init(readPeak: @escaping @MainActor () -> Float, readClip: @escaping @MainActor () -> Bool) {
        self.readPeak = readPeak
        self.readClip = readClip
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 14))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(Strings.meterLabel)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
        toolTip = Strings.meterLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSampling(_ active: Bool) {
        guard active != (timer != nil) else { return }
        if active {
            _ = readPeak()   // Discard audio from before the menu opened.
            _ = readClip()
            let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(sample(_:)),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            clipUntil = 0
            update(peak: 0, inputClipped: false, at: 0)
        }
    }

    @objc private func sample(_ timer: Timer) {
        update(peak: readPeak(), inputClipped: readClip(), at: ProcessInfo.processInfo.systemUptime)
    }

    func update(peak: Float, inputClipped: Bool, at now: TimeInterval) {
        if inputClipped { clipUntil = now + 2 }
        let clipped = now < clipUntil
        guard self.peak != peak || self.clipped != clipped else { return }
        self.peak = peak
        self.clipped = clipped
        needsDisplay = true
    }

    override func accessibilityValue() -> Any? { min(peak, 1) }

    override func accessibilityValueDescription() -> String? {
        let level = peak > 0 ? Strings.meterDecibels(Int(decibels.rounded())) : Strings.meterSilent
        return clipped ? Strings.meterClipped(level) : level
    }

    private var decibels: Float { 20 * log10(min(peak, 1)) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 14, y: bounds.midY - 2, width: bounds.width - 35, height: 4)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let fraction = CGFloat(max(0, 1 + decibels / 60))
        var fill = track
        fill.size.width *= fraction
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()

        if clipped {
            let mark = NSRect(x: track.maxX + 4, y: bounds.midY - 4, width: 3, height: 8)
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: mark, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
