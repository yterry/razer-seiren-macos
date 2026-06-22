import Foundation
import SeirenDSP

// EQEngine — a parametric equalizer for the Seiren voice path.
//
// Design (see docs/CREATOR_DESIGN.md §3): the per-sample filtering runs in the
// C SeirenDSP core on the real-time thread; this Swift layer only computes
// biquad coefficients (off the RT thread, from RBJ's Audio-EQ-Cookbook formulas)
// and publishes them via the lock-free C handoff. No Swift object is ever touched
// on the audio thread.
//
// Reach: the EQ shapes whatever audio flows through the IOProc it is wired into.
// In the creator build that proc reads the Seiren mic and writes both the
// headphone monitor and the SeirenFX virtual device, so the EQ reaches other
// apps (OBS/Zoom) that record from SeirenFX — not monitor-only.

// MARK: - Model

public enum BiquadType: String, Codable, Sendable {
    case peaking, lowShelf, highShelf, highpass, lowpass
}

/// One parametric band. `gainDB` is ignored for `.highpass`/`.lowpass`.
public struct EQBand: Codable, Equatable, Sendable {
    public var type: BiquadType
    public var freq: Float       // center/corner frequency, Hz
    public var gainDB: Float     // -24...+24 typical; clamped by callers/UI
    public var q: Float          // resonance / bandwidth

    public init(type: BiquadType, freq: Float, gainDB: Float = 0, q: Float = 0.707) {
        self.type = type
        self.freq = freq
        self.gainDB = gainDB
        self.q = q
    }
}

/// A named set of bands. `Flat` has no bands (passthrough).
public struct EQPreset: Codable, Equatable, Sendable {
    public var name: String
    public var bands: [EQBand]

    public init(name: String, bands: [EQBand]) {
        self.name = name
        self.bands = bands
    }

    /// No processing — a true bypass.
    public static let flat = EQPreset(name: "Flat", bands: [])

    /// Spoken-word clarity: rumble cut, boxiness dip, clear presence + air.
    /// Tuned to be plainly audible (≈+4 dB presence), not a subtle polish.
    public static let podcast = EQPreset(name: "Podcast", bands: [
        EQBand(type: .highpass,  freq: 85,    gainDB: 0,    q: 0.707),
        EQBand(type: .peaking,   freq: 300,   gainDB: -3,   q: 1.0),
        EQBand(type: .peaking,   freq: 3500,  gainDB: 4.5,  q: 1.0),
        EQBand(type: .highShelf, freq: 10000, gainDB: 3,    q: 0.707),
    ])

    /// Gentle, neutral sweetening for a treated room — the subtle option.
    public static let studio = EQPreset(name: "Studio", bands: [
        EQBand(type: .highpass,  freq: 50,    gainDB: 0,   q: 0.707),
        EQBand(type: .lowShelf,  freq: 120,   gainDB: 1.5, q: 0.707),
        EQBand(type: .peaking,   freq: 500,   gainDB: -2,  q: 1.0),
        EQBand(type: .peaking,   freq: 2500,  gainDB: 2,   q: 1.0),
        EQBand(type: .highShelf, freq: 10000, gainDB: 1.5, q: 0.707),
    ])

    /// Bold radio-voice: chest/warmth low-shelf, de-boxed mids, strong presence
    /// and air. The most obvious of the presets (≈+6 dB presence).
    public static let broadcast = EQPreset(name: "Broadcast", bands: [
        EQBand(type: .highpass,  freq: 90,    gainDB: 0,   q: 0.707),
        EQBand(type: .lowShelf,  freq: 150,   gainDB: 4,   q: 0.707),
        EQBand(type: .peaking,   freq: 500,   gainDB: -4,  q: 1.2),
        EQBand(type: .peaking,   freq: 4000,  gainDB: 6,   q: 1.1),
        EQBand(type: .highShelf, freq: 9000,  gainDB: 4,   q: 0.707),
    ])

    /// The presets shown in the menu, in order.
    public static let builtIns: [EQPreset] = [.flat, .podcast, .studio, .broadcast]
}

// MARK: - Coefficient math (RBJ Audio-EQ-Cookbook)

public enum EQCoefficients {

    /// One biquad's normalized coefficients `[b0, b1, b2, a1, a2]` (divided by
    /// a0), or `nil` if the band is degenerate (out of band, fs ≤ 0, etc.).
    public static func biquad(_ band: EQBand, sampleRate: Double) -> [Float]? {
        let fs = sampleRate
        guard fs > 0, band.freq > 0, Double(band.freq) < fs / 2 else { return nil }

        let A = pow(10.0, Double(band.gainDB) / 40.0)
        let w0 = 2.0 * Double.pi * Double(band.freq) / fs
        let cosw = cos(w0)
        let sinw = sin(w0)
        let q = max(Double(band.q), 0.001)
        let alpha = sinw / (2.0 * q)

        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.type {
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = sqrt(A)
            b0 =      A * ((A + 1) - (A - 1) * cosw + 2 * s * alpha)
            b1 =  2 * A * ((A - 1) - (A + 1) * cosw)
            b2 =      A * ((A + 1) - (A - 1) * cosw - 2 * s * alpha)
            a0 =          (A + 1) + (A - 1) * cosw + 2 * s * alpha
            a1 =     -2 * ((A - 1) + (A + 1) * cosw)
            a2 =          (A + 1) + (A - 1) * cosw - 2 * s * alpha
        case .highShelf:
            let s = sqrt(A)
            b0 =      A * ((A + 1) + (A - 1) * cosw + 2 * s * alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
            b2 =      A * ((A + 1) + (A - 1) * cosw - 2 * s * alpha)
            a0 =          (A + 1) - (A - 1) * cosw + 2 * s * alpha
            a1 =      2 * ((A - 1) - (A + 1) * cosw)
            a2 =          (A + 1) - (A - 1) * cosw - 2 * s * alpha
        case .highpass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .lowpass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        }

        guard a0 != 0, a0.isFinite else { return nil }
        return [
            Float(b0 / a0), Float(b1 / a0), Float(b2 / a0),
            Float(a1 / a0), Float(a2 / a0),
        ]
    }

    /// Flatten a preset to the `[b0,b1,b2,a1,a2, …]` layout SeirenDSP expects.
    /// Zero-gain peaking/shelf bands are dropped as no-ops to save sections.
    public static func sections(_ preset: EQPreset, sampleRate: Double) -> [Float] {
        var out: [Float] = []
        for band in preset.bands {
            let shaping = band.type == .peaking || band.type == .lowShelf || band.type == .highShelf
            if shaping && band.gainDB == 0 { continue }
            if let c = biquad(band, sampleRate: sampleRate) { out.append(contentsOf: c) }
        }
        return out
    }
}

// MARK: - Engine

/// Holds the active EQ state and pushes coefficients to the RT DSP core.
@MainActor
public final class EQEngine {
    public private(set) var isEnabled: Bool = false
    public private(set) var preset: EQPreset = .flat
    public private(set) var sampleRate: Double = 48000

    public init() {}

    public func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        republish()
    }

    public func setPreset(_ preset: EQPreset) {
        guard preset != self.preset else { return }
        self.preset = preset
        republish()
    }

    /// Recompute coefficients for a new sample rate (e.g. device/format change).
    public func setSampleRate(_ fs: Double) {
        guard fs > 0, fs != sampleRate else { return }
        sampleRate = fs
        republish()
    }

    /// Clear the RT filter state (call on stream/format change before audio).
    public func reset() { seiren_dsp_reset() }

    private func republish() {
        guard isEnabled else { seiren_dsp_publish(nil, 0); return }
        let coeffs = EQCoefficients.sections(preset, sampleRate: sampleRate)
        let n = coeffs.count / SeirenDSP_coeffsPerSection
        guard n > 0 else { seiren_dsp_publish(nil, 0); return }
        coeffs.withUnsafeBufferPointer { buf in
            seiren_dsp_publish(buf.baseAddress, Int32(n))
        }
    }
}

/// Mirror of `SEIREN_DSP_COEFFS_PER_SECTION` (the macro isn't imported into Swift).
let SeirenDSP_coeffsPerSection = 5
