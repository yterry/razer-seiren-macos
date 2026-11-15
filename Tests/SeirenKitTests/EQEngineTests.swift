import XCTest
@testable import SeirenKit
import SeirenDSP

/// Hardware-free verification of the EQ: publish coefficients to the C DSP core,
/// push a sine through `seiren_dsp_process`, and measure the realized gain. This
/// proves both the RBJ coefficient math (Swift) and the biquad processing (C).
final class EQEngineTests: XCTestCase {

    let fs = 48000.0

    override func setUp() {
        super.setUp()
        seiren_dsp_publish(nil, 0)   // start disabled
        seiren_dsp_reset()
    }

    override func tearDown() {
        seiren_dsp_publish(nil, 0)
        seiren_dsp_reset()
        super.tearDown()
    }

    /// Measured gain (dB) of the currently-published EQ at `freq`, using a small
    /// amplitude so boosts never reach the post-EQ limiter (which would distort
    /// the measurement). Skips a warm-up so the IIR settles before measuring.
    private func measureGainDB(at freq: Double, amp: Float = 0.02) -> Double {
        seiren_dsp_reset()
        let block = 128
        let blocks = Int(fs) / block           // ~1 second
        let warm = blocks / 4
        var phase = 0.0
        var sumIn = 0.0, sumOut = 0.0, count = 0.0
        var inb = [Float](repeating: 0, count: block)

        for bi in 0..<blocks {
            for k in 0..<block {
                inb[k] = Float(sin(phase)) * amp
                phase += 2.0 * Double.pi * freq / fs
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            }
            var outb = inb
            outb.withUnsafeMutableBufferPointer { p in
                seiren_dsp_process(p.baseAddress, Int32(block), 1)
            }
            if bi >= warm {
                for k in 0..<block {
                    sumIn  += Double(inb[k])  * Double(inb[k])
                    sumOut += Double(outb[k]) * Double(outb[k])
                    count  += 1
                }
            }
        }
        let inRMS = (sumIn / count).squareRoot()
        let outRMS = (sumOut / count).squareRoot()
        return 20.0 * log10(outRMS / inRMS)
    }

    private func publish(_ sections: [Float]) {
        let n = sections.count / 5
        sections.withUnsafeBufferPointer { seiren_dsp_publish($0.baseAddress, Int32(n)) }
    }

    // MARK: Passthrough

    func testDisabledIsUnityGain() {
        seiren_dsp_publish(nil, 0)
        XCTAssertEqual(measureGainDB(at: 1000), 0, accuracy: 0.05)
        XCTAssertEqual(measureGainDB(at: 100), 0, accuracy: 0.05)
    }

    func testFlatPresetProducesNoSections() {
        XCTAssertTrue(EQCoefficients.sections(.flat, sampleRate: fs).isEmpty)
    }

    // MARK: Single bands

    func testPeakingBoostHitsTargetGainAtCenter() {
        let band = EQBand(type: .peaking, freq: 1000, gainDB: 6, q: 1.0)
        publish(EQCoefficients.biquad(band, sampleRate: fs)!)
        XCTAssertEqual(measureGainDB(at: 1000), 6.0, accuracy: 0.6, "boost at center")
        XCTAssertEqual(measureGainDB(at: 100),  0.0, accuracy: 0.6, "untouched far below")
        XCTAssertEqual(measureGainDB(at: 12000), 0.0, accuracy: 0.6, "untouched far above")
    }

    func testPeakingCutIsNegative() {
        let band = EQBand(type: .peaking, freq: 2000, gainDB: -8, q: 1.5)
        publish(EQCoefficients.biquad(band, sampleRate: fs)!)
        XCTAssertEqual(measureGainDB(at: 2000), -8.0, accuracy: 0.7)
    }

    func testHighpassAttenuatesLows() {
        let band = EQBand(type: .highpass, freq: 200, q: 0.707)
        publish(EQCoefficients.biquad(band, sampleRate: fs)!)
        XCTAssertLessThan(measureGainDB(at: 40), -10.0, "deep cut well below corner")
        XCTAssertEqual(measureGainDB(at: 2000), 0.0, accuracy: 0.6, "passband flat")
    }

    func testHighShelfLiftsHighs() {
        let band = EQBand(type: .highShelf, freq: 6000, gainDB: 6, q: 0.707)
        publish(EQCoefficients.biquad(band, sampleRate: fs)!)
        XCTAssertEqual(measureGainDB(at: 14000), 6.0, accuracy: 1.0, "shelf plateau")
        XCTAssertEqual(measureGainDB(at: 200), 0.0, accuracy: 0.6, "lows untouched")
    }

    // MARK: Presets

    func testPodcastPresetHasClearPresenceAndRumbleCut() {
        publish(EQCoefficients.sections(.podcast, sampleRate: fs))
        XCTAssertGreaterThan(measureGainDB(at: 3500), 3.0, "clearly audible presence lift")
        XCTAssertLessThan(measureGainDB(at: 40), -5.0, "rumble cut by the HPF")
        XCTAssertLessThan(measureGainDB(at: 300), -1.5, "boxiness dip")
    }

    func testBroadcastPresetIsBoldAndMoreAggressiveThanStudio() {
        publish(EQCoefficients.sections(.broadcast, sampleRate: fs))
        XCTAssertGreaterThan(measureGainDB(at: 4000), 4.5, "bold presence (~+6 dB)")
        // Warmth is intentionally mild: the +4 dB low-shelf is partly offset by
        // the 90 Hz HPF, so it adds body without boom (~+1 dB net near 150 Hz).
        XCTAssertGreaterThan(measureGainDB(at: 150), 0.8, "low-shelf warmth")
        XCTAssertLessThan(measureGainDB(at: 500), -2.0, "de-box dip")
        let broadcastPresence = measureGainDB(at: 4000)
        publish(EQCoefficients.sections(.studio, sampleRate: fs))
        XCTAssertGreaterThan(broadcastPresence, measureGainDB(at: 2500), "bolder than Studio")
    }

    // MARK: Safety

    /// The post-EQ limiter's ceiling, -1 dBFS.
    private let ceiling = Float(pow(10.0, -1.0 / 20))

    /// One EQ section that passes audio through unchanged, so the limiter's
    /// gain is the output divided by the input.
    private let unity: [Float] = [1, 0, 0, 0, 0]

    private func sine(_ freq: Double, amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { Float(sin(2 * Double.pi * freq * Double($0) / fs)) * amplitude }
    }

    /// The published sections applied to `x` in Float with no limiter.
    private func eqOnly(_ x: [Float], sections: [Float]) -> [Float] {
        var z = [Float](repeating: 0, count: sections.count / 5 * 2)
        return x.map { input in
            var s = input
            for i in 0..<(sections.count / 5) {
                let c = Array(sections[(i * 5)..<(i * 5 + 5)])
                let y = c[0] * s + z[i * 2]
                z[i * 2] = c[1] * s - c[3] * y + z[i * 2 + 1]
                z[i * 2 + 1] = c[2] * s - c[4] * y
                s = y
            }
            return s
        }
    }

    private func processMono(_ x: inout [Float], bank: Int32) {
        x.withUnsafeMutableBufferPointer { seiren_dsp_process_mono($0.baseAddress, Int32($0.count), bank) }
    }

    func testBroadcastLimitsALoudToneWithoutCuttingItFlat() {
        publish(EQCoefficients.sections(.broadcast, sampleRate: fs))
        var out = sine(4000, amplitude: 0.9, count: Int(fs))
        processMono(&out, bank: 0)
        XCTAssertLessThanOrEqual(out.map(abs).max()!, ceiling + 0.000001)
        // A flat top is a run of samples held at the ceiling.
        var run = 0, longest = 0
        for sample in out.dropFirst(Int(fs * 0.005)) {
            run = abs(sample) >= ceiling - 0.00001 ? run + 1 : 0
            longest = max(longest, run)
        }
        XCTAssertLessThan(longest, 3)
    }

    func testQuietSpeechLevelPassesThroughBroadcastUnlimited() {
        let sections = EQCoefficients.sections(.broadcast, sampleRate: fs)
        publish(sections)
        let input = sine(4000, amplitude: 0.1, count: Int(fs))   // -20 dBFS
        var out = input
        processMono(&out, bank: 0)
        // The same EQ 24 dB lower, scaled back up: the float EQ scales exactly
        // by a power of two, so only a limiter acting at -20 dBFS differs.
        seiren_dsp_reset()
        var low = input.map { $0 / 16 }
        processMono(&low, bank: 0)
        for (actual, expected) in zip(out, low.map { $0 * 16 }) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        // And that is the Broadcast EQ, to within the C compiler's choice of
        // fused multiply-adds.
        for (actual, expected) in zip(out, eqOnly(input, sections: sections)) {
            XCTAssertEqual(actual, expected, accuracy: 0.00001)
        }
    }

    func testMonoStateBanksLimitIndependently() {
        publish(unity)
        var loud = [Float](repeating: 2, count: 64) + [Float](repeating: 0.1, count: 64)
        var quiet = [Float](repeating: 0.1, count: 128)
        processMono(&loud, bank: 0)
        processMono(&quiet, bank: 1)
        XCTAssertEqual(loud[0], ceiling, accuracy: 0.000001)
        XCTAssertLessThan(loud.last!, 0.1 * ceiling / 1.9, "bank 0 is still releasing")
        XCTAssertEqual(quiet, [Float](repeating: 0.1, count: 128), "bank 1 never saw the burst")
    }

    func testInterleavedLimiterLinksTheChannelsOfAFrame() {
        publish(unity)
        var frame: [Float] = [2, 0.5]
        frame.withUnsafeMutableBufferPointer { seiren_dsp_process($0.baseAddress, 1, 2) }
        XCTAssertEqual(frame[0], ceiling, accuracy: 0.000001)
        XCTAssertEqual(frame[1], frame[0] / 4, accuracy: 0.000001)
    }

    func testOutputIsClampedToFullScale() {
        // A big boost on a full-scale sine must not exceed the ceiling at the output.
        let band = EQBand(type: .peaking, freq: 1000, gainDB: 12, q: 1.0)
        publish(EQCoefficients.biquad(band, sampleRate: fs)!)
        seiren_dsp_reset()
        var buf = [Float](repeating: 0, count: 2048)
        var phase = 0.0
        for k in 0..<buf.count {
            buf[k] = Float(sin(phase)) * 0.95
            phase += 2.0 * Double.pi * 1000.0 / fs
        }
        buf.withUnsafeMutableBufferPointer { seiren_dsp_process($0.baseAddress, Int32($0.count), 1) }
        XCTAssertLessThanOrEqual(buf.max() ?? 0, ceiling)
        XCTAssertGreaterThanOrEqual(buf.min() ?? 0, -ceiling)
    }

    // MARK: Engine API

    @MainActor
    func testEngineEnableDisableRoundTrips() {
        let eq = EQEngine()
        eq.setPreset(.podcast)
        eq.setEnabled(true)
        XCTAssertGreaterThan(measureGainDB(at: 4000), 1.0, "enabled → shaping")
        eq.setEnabled(false)
        XCTAssertEqual(measureGainDB(at: 4000), 0.0, accuracy: 0.05, "disabled → passthrough")
    }

    // MARK: Noise gate

    /// RMS of a tone after the gate, at a given amplitude, after letting the
    /// gate settle. Tone is well above the gate's detection band.
    private func gatedRMS(amp: Float, seconds: Double = 0.6) -> Double {
        seiren_dsp_reset()
        let block = 128
        let blocks = Int(fs * seconds) / block
        let warm = blocks * 2 / 3
        var phase = 0.0, sum = 0.0, n = 0.0
        var buf = [Float](repeating: 0, count: block)
        for bi in 0..<blocks {
            for k in 0..<block {
                buf[k] = Float(sin(phase)) * amp
                phase += 2.0 * Double.pi * 1000.0 / fs
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            }
            buf.withUnsafeMutableBufferPointer { seiren_dsp_gate($0.baseAddress, Int32($0.count), 1) }
            if bi >= warm { for k in 0..<block { sum += Double(buf[k]*buf[k]); n += 1 } }
        }
        return (sum / n).squareRoot()
    }

    func testGateDisabledIsPassthrough() {
        seiren_dsp_set_gate(0, -50, Float(fs))
        let amp: Float = 0.0005   // well below a -50 dB threshold
        XCTAssertEqual(gatedRMS(amp: amp), Double(amp) / 2.0.squareRoot(), accuracy: 0.0002)
    }

    func testGateMutesBelowThresholdAndPassesAbove() {
        seiren_dsp_set_gate(1, -50, Float(fs))   // threshold ≈ 0.00316 linear
        // Loud tone (−6 dBFS): gate opens, signal passes near unity.
        let loud = gatedRMS(amp: 0.5)
        XCTAssertGreaterThan(loud, 0.3, "speech-level signal passes the gate")
        // Quiet tone (≈ −66 dBFS): below threshold, gated to near silence.
        let quiet = gatedRMS(amp: 0.0005)
        XCTAssertLessThan(quiet, 0.00005, "sub-threshold noise is muted")
    }

    /// The mono EQ (state bank 1, used by the broadcast branch) must match the
    /// proven interleaved EQ (bank 0) sample-for-sample on the same input — the
    /// split monitor/broadcast routing relies on the two banks being identical.
    func testProcessMonoMatchesInterleaved() {
        let c = EQCoefficients.biquad(EQBand(type: .peaking, freq: 1000, gainDB: 6, q: 1.0),
                                      sampleRate: fs)!
        func sine(_ n: Int) -> [Float] {
            var ph = 0.0
            return (0..<n).map { _ -> Float in
                let v = Float(sin(ph)) * 0.1
                ph += 2 * Double.pi * 1000.0 / fs
                return v
            }
        }
        publish(c); seiren_dsp_reset()
        var a = sine(2048)
        a.withUnsafeMutableBufferPointer { seiren_dsp_process($0.baseAddress, Int32($0.count), 1) }

        seiren_dsp_reset()
        var b = sine(2048)
        b.withUnsafeMutableBufferPointer { seiren_dsp_process_mono($0.baseAddress, Int32($0.count), 1) }

        for i in 0..<a.count { XCTAssertEqual(a[i], b[i], accuracy: 1e-5) }
    }

    func testPresetsAreCodableRoundTrip() throws {
        for p in EQPreset.builtIns {
            let data = try JSONEncoder().encode(p)
            let back = try JSONDecoder().decode(EQPreset.self, from: data)
            XCTAssertEqual(p, back)
        }
    }
}
