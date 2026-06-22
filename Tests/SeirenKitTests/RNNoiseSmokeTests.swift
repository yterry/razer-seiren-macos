import XCTest
import RNNoise

/// Proves the vendored RNNoise C target links and runs (Stage A acceptance):
/// the public API is reachable, the frame size is the expected 480 @ 48 kHz,
/// and a create→process→destroy cycle produces finite output.
final class RNNoiseSmokeTests: XCTestCase {

    func testFrameSizeIs480() {
        XCTAssertEqual(Int(rnnoise_get_frame_size()), 480)
    }

    func testCreateProcessDestroyProducesFiniteOutput() {
        guard let st = rnnoise_create(nil) else {
            XCTFail("rnnoise_create returned nil")
            return
        }
        defer { rnnoise_destroy(st) }

        let n = Int(rnnoise_get_frame_size())
        // RNNoise expects ~int16-range floats (±32768), not ±1.0.
        var input = (0..<n).map { Float(sin(Double($0) * 0.12)) * 3000.0 }
        var output = [Float](repeating: 0, count: n)

        _ = rnnoise_process_frame(st, &output, &input)

        XCTAssertTrue(output.allSatisfy { $0.isFinite }, "denoised frame is finite")
    }
}
