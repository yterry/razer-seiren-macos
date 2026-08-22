import XCTest
import CoreAudio
import SeirenDSP
@testable import SeirenKit

/// Drives the creator-path RT callback (`routeIOProc`) with synthetic buffer
/// lists, the way Core Audio would, to pin down the one thing hardware can't
/// be relied on to show on CI: which output buffers get the headphone monitor
/// (× level) and which get the Seiren FX broadcast (unity). The aggregate's
/// output list is [Seiren output streams…, Seiren FX], so a V3 Pro (one
/// headphone stream) puts FX at buffer 1 while a jack-less V3 Mini puts FX at
/// buffer 0 - `gMonitorOutBuffers` is the count that tells them apart.
@MainActor
final class RouteProcTests: XCTestCase {

    private var allocations: [UnsafeMutablePointer<Float>] = []
    private var lists: [UnsafeMutableAudioBufferListPointer] = []

    override func setUp() {
        super.setUp()
        MonitorEngine.ensureScratch()
        // Pass-through DSP so the numbers are exact: no EQ, gate, or Studio.
        seiren_dsp_publish(nil, 0)
        seiren_dsp_set_gate(0, -50, 48000)
        seiren_dsp_set_studio(0)
        seiren_dsp_reset()
    }

    override func tearDown() {
        gMonitorOutBuffers = 1   // the V3 Pro default other code assumes
        for l in lists { l.unsafeMutablePointer.deallocate() }
        for p in allocations { p.deallocate() }
        lists = []
        allocations = []
        super.tearDown()
    }

    /// `count` mono Float32 buffers of `frames` frames, each filled with `fill`.
    private func bufferList(count: Int, frames: Int, fill: Float)
        -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: count)
        list.count = count
        for i in 0..<count {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: fill, count: frames)
            allocations.append(p)
            list[i] = AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(p))
        }
        lists.append(list)
        return list
    }

    private func samples(_ list: UnsafeMutableAudioBufferListPointer, _ i: Int,
                         frames: Int) -> [Float] {
        let p = list[i].mData!.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: p, count: frames))
    }

    private func run(inputs: UnsafeMutableAudioBufferListPointer,
                     outputs: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        var ts = AudioTimeStamp()
        return routeIOProc(0, &ts, inputs.unsafePointer, &ts,
                           outputs.unsafeMutablePointer, &ts, nil)
    }

    func testJackLessMicSendsBroadcastAtUnityToBufferZero() {
        // V3 Mini layout: the Seiren contributes no output stream, so the
        // only output buffer is Seiren FX and must carry the unity broadcast -
        // not the level-scaled monitor, which would quietly attenuate what
        // OBS/Zoom record.
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        engine.level = 0.25
        gMonitorOutBuffers = 0
        let frames = 64
        let inputs = bufferList(count: 1, frames: frames, fill: 0.5)
        let outputs = bufferList(count: 1, frames: frames, fill: 0)

        XCTAssertEqual(run(inputs: inputs, outputs: outputs), noErr)

        let fx = samples(outputs, 0, frames: frames)
        XCTAssertEqual(fx, [Float](repeating: 0.5, count: frames),
                       "Seiren FX must get the mic at unity, untouched by the monitor level")
    }

    func testHeadphoneMicSplitsMonitorAndBroadcast() {
        // V3 Pro layout: buffer 0 = headphones (× level), buffer 1 = Seiren FX.
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        engine.level = 0.25
        gMonitorOutBuffers = 1
        let frames = 64
        let inputs = bufferList(count: 1, frames: frames, fill: 0.5)
        let outputs = bufferList(count: 2, frames: frames, fill: 0)

        XCTAssertEqual(run(inputs: inputs, outputs: outputs), noErr)

        XCTAssertEqual(samples(outputs, 0, frames: frames),
                       [Float](repeating: 0.125, count: frames),
                       "headphones hear the mic scaled by the monitor level")
        XCTAssertEqual(samples(outputs, 1, frames: frames),
                       [Float](repeating: 0.5, count: frames),
                       "Seiren FX gets the broadcast at unity")
    }

    func testStereoInputUsesChannelZeroAndZeroesTrailingFrames() {
        // Interleaved stereo mic with a shorter buffer than the output: channel
        // 0 is the mic, and output frames past the input are zeroed, not stale.
        gMonitorOutBuffers = 0
        let inFrames = 8, outFrames = 12
        let inputs = bufferList(count: 1, frames: inFrames * 2, fill: 0)
        let inPtr = inputs[0].mData!.assumingMemoryBound(to: Float.self)
        for f in 0..<inFrames { inPtr[f * 2] = 0.75; inPtr[f * 2 + 1] = -1.0 }
        inputs[0].mNumberChannels = 2
        let outputs = bufferList(count: 1, frames: outFrames, fill: 0.3)

        XCTAssertEqual(run(inputs: inputs, outputs: outputs), noErr)

        let out = samples(outputs, 0, frames: outFrames)
        XCTAssertEqual(Array(out.prefix(inFrames)), [Float](repeating: 0.75, count: inFrames))
        XCTAssertEqual(Array(out.suffix(outFrames - inFrames)),
                       [Float](repeating: 0, count: outFrames - inFrames))
    }

    func testDiagnosticsReportLayoutAndPeak() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        gMonitorOutBuffers = 0
        let inputs = bufferList(count: 2, frames: 16, fill: 0.5)   // mic + FX's own input
        let outputs = bufferList(count: 1, frames: 16, fill: 0)
        let before = engine.routeDiagnostics.callbacks

        XCTAssertEqual(run(inputs: inputs, outputs: outputs), noErr)

        let d = engine.routeDiagnostics
        XCTAssertEqual(d.callbacks, before + 1)
        XCTAssertEqual(d.inputBuffers, 2)
        XCTAssertEqual(d.outputBuffers, 1)
        XCTAssertEqual(d.monitorBuffers, 0)
        XCTAssertGreaterThanOrEqual(d.inputPeak, 0.5, "peak tracks |raw mic| (never below this run's 0.5)")
    }
}
