import XCTest
import SeirenDSP

/// Hardware-free tests for the Studio (RNNoise) DSP plumbing: the 2:1 half-band
/// resampler (deterministic) and the ±32768 scaling guard around RNNoise.
final class StudioDSPTests: XCTestCase {

    override func setUp() { super.setUp(); seiren_dsp_set_studio(0); seiren_dsp_reset() }
    override func tearDown() { seiren_dsp_set_studio(0); seiren_dsp_reset(); super.tearDown() }

    private func rms(_ s: ArraySlice<Float>) -> Double {
        let sum = s.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(s.count)).squareRoot()
    }

    /// A 1 kHz tone (well inside the 24 kHz passband) survives 96k→48k→96k.
    func testResamplerRoundTripPreservesVoiceBand() {
        seiren_dsp_reset()
        let n = 4096
        var x = (0..<n).map { Float(sin(2 * Double.pi * 1000.0 * Double($0) / 96000.0)) * 0.5 }
        var down = [Float](repeating: 0, count: n / 2)
        x.withUnsafeBufferPointer { ip in
            down.withUnsafeMutableBufferPointer { op in
                seiren_dsp_downsample2(ip.baseAddress, op.baseAddress, Int32(n / 2))
            }
        }
        var up = [Float](repeating: 0, count: n)
        down.withUnsafeBufferPointer { ip in
            up.withUnsafeMutableBufferPointer { op in
                seiren_dsp_upsample2(ip.baseAddress, op.baseAddress, Int32(n / 2))
            }
        }
        let inRMS = rms(x[1024..<(n - 64)])
        let outRMS = rms(up[1024..<(n - 64)])
        XCTAssertEqual(outRMS, inRMS, accuracy: inRMS * 0.1, "1 kHz preserved through 2:1 round trip")
    }

    /// A 30 kHz tone (above the 48k Nyquist) is filtered out before decimation,
    /// so it doesn't alias back into the voice band.
    func testResamplerRejectsAboveNyquist() {
        seiren_dsp_reset()
        let n = 4096
        var x = (0..<n).map { Float(sin(2 * Double.pi * 30000.0 * Double($0) / 96000.0)) * 0.5 }
        var down = [Float](repeating: 0, count: n / 2)
        x.withUnsafeBufferPointer { ip in
            down.withUnsafeMutableBufferPointer { op in
                seiren_dsp_downsample2(ip.baseAddress, op.baseAddress, Int32(n / 2))
            }
        }
        let inRMS = rms(x[0..<n])
        let outRMS = rms(down[256..<(n / 2)])
        XCTAssertLessThan(outRMS, inRMS * 0.05, "30 kHz attenuated >26 dB → no audible alias")
    }

    /// The ±32768 scaling around RNNoise must pair up: output stays in the ±1.0
    /// domain (a missed down-scale would blow up ~32768×). Verified at 48 kHz.
    func testStudioScalingStaysInUnitRange() {
        seiren_dsp_set_studio(1)
        seiren_dsp_reset()
        var maxAbs: Float = 0
        var phase = 0.0
        let block = 128
        for _ in 0..<60 {                              // ~7680 samples @ 48k (well past priming)
            var buf = [Float](repeating: 0, count: block)
            for k in 0..<block {
                buf[k] = Float(sin(phase)) * 0.5
                phase += 2 * Double.pi * 440.0 / 48000.0
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            buf.withUnsafeMutableBufferPointer {
                seiren_dsp_studio_process($0.baseAddress, Int32($0.count), 0)
            }
            for v in buf {
                XCTAssertTrue(v.isFinite, "studio output is finite")
                maxAbs = max(maxAbs, abs(v))
            }
        }
        XCTAssertLessThan(maxAbs, 2.0, "stays ~unit range — scaling pairs correctly (no ×32768 blowup)")
        seiren_dsp_set_studio(0)
    }
}
