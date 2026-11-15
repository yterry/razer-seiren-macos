import AppKit
import SeirenKit

/// Menu-hosted controls keep tracking without dismissing the menu. Slider and
/// mute actions update this row immediately; delegate updates reuse the view.
/// VoiceOver reads only the slider and the mute button: the slider's label names
/// the channel and its value is the percentage, so the icon, name and value are
/// hidden. Accessibility ignores a single-cell control and exposes its cell, and
/// a setting made on the control never reaches the cell, so all of it is set on
/// the cells.
@MainActor
final class MixerChannelView: NSView {
    private(set) var channel: MixerEngine.Channel
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: PercentSlider
    private let mute = NSButton()
    private let changed: (MixerEngine.Channel) -> Void

    init(channel: MixerEngine.Channel, icon: NSImage?, changed: @escaping (MixerEngine.Channel) -> Void) {
        self.channel = channel
        self.changed = changed
        slider = PercentSlider(value: Double(channel.level), minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        autoresizingMask = [.width]   // the menu sizes the row to its own width
        let image = NSImageView(frame: NSRect(x: 14, y: 24, width: 16, height: 16))
        image.image = icon
        image.imageScaling = .scaleProportionallyDown
        image.cell?.setAccessibilityElement(false)
        addSubview(image)
        nameLabel.frame = NSRect(x: 36, y: 24, width: 108, height: 16)
        nameLabel.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.autoresizingMask = [.width]
        nameLabel.cell?.setAccessibilityElement(false)
        addSubview(nameLabel)
        valueLabel.frame = NSRect(x: 144, y: 24, width: 58, height: 16)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.autoresizingMask = [.minXMargin]
        valueLabel.cell?.setAccessibilityElement(false)
        addSubview(valueLabel)
        mute.frame = NSRect(x: 204, y: 22, width: 24, height: 20)
        mute.isBordered = false
        mute.imagePosition = .imageOnly
        mute.autoresizingMask = [.minXMargin]
        mute.target = self
        mute.action = #selector(toggleMute)
        addSubview(mute)
        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 19)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(levelChanged)
        addSubview(slider)
        update(channel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ channel: MixerEngine.Channel) {
        self.channel = channel
        let name = Strings.mixerChannelName(channel)
        nameLabel.stringValue = name
        valueLabel.stringValue = channel.muted ? Strings.mixerMuted : Strings.percent(Int((channel.level * 100).rounded()))
        slider.doubleValue = Double(channel.level)
        // A muted channel keeps its level for when it comes back; dimming the
        // slider shows that it isn't reaching the stream right now.
        slider.alphaValue = channel.muted ? 0.4 : 1
        slider.cell?.setAccessibilityLabel(Strings.mixerLevelLabel(name))
        mute.image = NSImage(systemSymbolName: channel.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             accessibilityDescription: nil)
        mute.toolTip = channel.muted ? Strings.mixerUnmute : Strings.mixerMute
        mute.cell?.setAccessibilityLabel(Strings.mixerMuteLabel(name, mute.toolTip ?? ""))
        mute.cell?.setAccessibilityValue(channel.muted ? Strings.mixerMuted : Strings.mixerUnmuted)
    }

    @objc private func levelChanged() {
        channel.level = slider.floatValue
        update(channel)
        changed(channel)
    }

    @objc private func toggleMute() {
        channel.muted.toggle()
        update(channel)
        changed(channel)
    }
}
