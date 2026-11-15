import XCTest
import CoreAudio
import Foundation
import os
import SeirenDSP

/// Stress tests for the lock-free handoffs between the thread that configures
/// the DSP and the real-time thread that runs it. Each test runs a writer for a
/// fixed number of iterations while a reader processes buffers until the writer
/// is done. Run them under `swift test --sanitize=thread` to check the handoffs
/// for data races, and under `--sanitize=address` for use-after-free and
/// out-of-bounds access. The assertions catch torn or garbage reads.
final class DSPConcurrencyTests: XCTestCase {
    override func tearDown() {
        // Leave the process-wide DSP state as the other tests expect it. Two
        // disabling calls each also free the block retired by the previous call.
        seiren_dsp_publish(nil, 0)
        seiren_dsp_publish(nil, 0)
        seiren_dsp_set_gate(0, -50, 48000)
        seiren_dsp_set_studio(0)
        seiren_dsp_set_studio(0)
        seiren_dsp_reset()
        super.tearDown()
    }

    /// Runs `reader` repeatedly on its own thread while `writer` runs on another,
    /// and returns how many times the reader ran. The reader starts first and
    /// keeps going until the writer has finished, so the two always overlap.
    /// The writer gets a function that waits until the reader has started and
    /// finished a whole pass since the call.
    private func runConcurrently(writer: @escaping @Sendable (_ waitForReader: () -> Void) -> Void,
                                 reader: @escaping @Sendable () -> Void) -> Int {
        let writerDone = OSAllocatedUnfairLock(initialState: false)
        let readerStarted = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let readerRuns = OSAllocatedUnfairLock(initialState: 0)

        group.enter()
        Thread {
            readerStarted.signal()
            repeat {
                reader()
                readerRuns.withLock { $0 += 1 }
            } while !writerDone.withLock { $0 }
            group.leave()
        }.start()

        group.enter()
        Thread {
            readerStarted.wait()
            writer {
                // The pass in progress may predate the call, so wait for two.
                let target = readerRuns.withLock { $0 } + 2
                while readerRuns.withLock({ $0 }) < target {}
            }
            writerDone.withLock { $0 = true }
            group.leave()
        }.start()

        group.wait()
        return readerRuns.withLock { $0 }
    }

    func testEQPublishWhileProcessing() {
        // Two presets with no filter memory (b1 = b2 = a1 = a2 = 0), so every
        // buffer comes out as the input times one preset's whole-cascade gain.
        let unity: [Float] = [1, 0, 0, 0, 0]                        // 1 section, gain 1
        let quarter: [Float] = [0.5, 0, 0, 0, 0, 0.5, 0, 0, 0, 0]   // 2 sections, gain 0.25
        let input: Float = 0.5
        let expected: Set<Float> = [input * 1, input * 0.25]
        let frames = 256
        let mismatches = OSAllocatedUnfairLock(initialState: 0)

        let runs = runConcurrently(writer: { waitForReader in
            for i in 0..<10_000 {
                let preset = i.isMultiple(of: 2) ? unity : quarter
                preset.withUnsafeBufferPointer { seiren_dsp_publish($0.baseAddress, Int32(preset.count / 5)) }
                // seiren_dsp_publish frees a block two publishes after replacing
                // it and assumes the audio thread has finished with it by then,
                // which a publish per audio buffer or slower guarantees. Faster
                // publishing is unsafe until issue #86 is fixed.
                waitForReader()
            }
        }, reader: {
            var buffer = [Float](repeating: input, count: frames)
            seiren_dsp_process_mono(&buffer, Int32(frames), 0)
            // One call loads one coefficient block, so the whole buffer must
            // match exactly one preset.
            if !expected.contains(buffer[0]) || buffer.contains(where: { $0 != buffer[0] }) {
                mismatches.withLock { $0 += 1 }
            }
        })

        XCTAssertGreaterThan(runs, 0)
        XCTAssertEqual(mismatches.withLock { $0 }, 0, "buffers processed with a torn coefficient block")
    }

    func testGateAndStudioToggleWhileProcessing() {
        let frames = 480
        let nonFinite = OSAllocatedUnfairLock(initialState: 0)

        let runs = runConcurrently(writer: { waitForReader in
            for i in 0..<200 {
                let on: Int32 = i.isMultiple(of: 2) ? 1 : 0
                seiren_dsp_set_gate(on, i.isMultiple(of: 4) ? -50 : -30, 48000)
                seiren_dsp_set_studio(on)
                // seiren_dsp_set_studio has the same timing assumption as
                // seiren_dsp_publish, and also resets the audio thread's frame
                // bridge, until issue #86 is fixed.
                waitForReader()
            }
        }, reader: {
            var buffer = (0..<frames).map { Float(sin(Double($0) * 0.05)) * 0.2 }
            buffer.withUnsafeMutableBufferPointer { p in
                seiren_dsp_gate(p.baseAddress, Int32(frames), 1)
                seiren_dsp_studio_process(p.baseAddress, Int32(frames), 0)
            }
            if buffer.contains(where: { !$0.isFinite || abs($0) > 1 }) {
                nonFinite.withLock { $0 += 1 }
            }
        })

        XCTAssertGreaterThan(runs, 0)
        XCTAssertEqual(nonFinite.withLock { $0 }, 0, "gate or Studio produced samples outside [-1, 1]")
    }

    func testMixerGainWhileProcessing() throws {
        let frames = 256
        let mixer = try XCTUnwrap(seiren_mixer_create(48000, 0))
        defer { seiren_mixer_destroy(mixer) }
        seiren_mixer_map_input(mixer, 0, 0)
        seiren_mixer_map_input(mixer, 1, 1)

        let input = AudioBufferList.allocate(maximumBuffers: 2)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let inputSamples = UnsafeMutablePointer<Float>.allocate(capacity: 2 * frames * 2)
        let outputSamples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer {
            input.unsafeMutablePointer.deallocate()
            output.unsafeMutablePointer.deallocate()
            inputSamples.deallocate()
            outputSamples.deallocate()
        }
        inputSamples.initialize(repeating: 0.4, count: 2 * frames * 2)
        outputSamples.initialize(repeating: 0, count: frames * 2)
        let bytes = UInt32(frames * 2 * MemoryLayout<Float>.size)
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: inputSamples)
        input[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: inputSamples + frames * 2)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: outputSamples)

        // Raw addresses so the closures stay Sendable; only the reader touches
        // the buffers, and the mixer's gains are its documented atomics.
        let mixerAddress = UInt(bitPattern: mixer)
        let inputAddress = UInt(bitPattern: input.unsafePointer)
        let outputAddress = UInt(bitPattern: output.unsafeMutablePointer)
        let outputSamplesAddress = UInt(bitPattern: outputSamples)
        let proc = try XCTUnwrap(seiren_mixer_proc())
        let outOfRange = OSAllocatedUnfairLock(initialState: 0)

        let runs = runConcurrently(writer: { _ in
            let mixer = OpaquePointer(bitPattern: mixerAddress)
            for i in 0..<100_000 {
                seiren_mixer_set_gain(mixer, Int32(i % 2), i.isMultiple(of: 3) ? 0 : 1)
            }
        }, reader: {
            var time = AudioTimeStamp()
            let status = proc(0, &time, UnsafePointer(bitPattern: inputAddress)!, &time,
                              UnsafeMutablePointer(bitPattern: outputAddress)!, &time,
                              UnsafeMutableRawPointer(bitPattern: mixerAddress))
            let samples = UnsafeBufferPointer(start: UnsafePointer<Float>(bitPattern: outputSamplesAddress),
                                              count: frames * 2)
            // Two inputs at 0.4 with gains in 0...1 sum to at most 0.8, under
            // the limiter's -1 dBFS ceiling, so nothing is ever limited.
            if status != noErr || samples.contains(where: { !$0.isFinite || $0 < 0 || $0 > 0.8 + 1e-6 }) {
                outOfRange.withLock { $0 += 1 }
            }
        })

        XCTAssertGreaterThan(runs, 0)
        XCTAssertEqual(outOfRange.withLock { $0 }, 0, "mixer produced samples outside the gain range")
        XCTAssertEqual(seiren_mixer_callbacks(mixer), UInt64(runs))
    }
}
