import XCTest
import CoreAudio
import SeirenDSP
@testable import SeirenKit

final class MixerEngineTests: XCTestCase {
    func testChannelNormalizationAndCodable() throws {
        let channels: [MixerEngine.Channel] = [
            .init(source: .app(bundleID: "first"), name: "First", level: 2),
            .init(source: .desktop, name: "Wrong", level: -1, muted: true),
            .init(source: .app(bundleID: "first"), name: "Duplicate"),
        ] + (0..<8).map { .init(source: .app(bundleID: "app\($0)"), name: "App \($0)") }
        let normalized = MixerEngine.normalizedChannels(channels)
        XCTAssertEqual(normalized.count, 8)
        XCTAssertEqual(normalized[0], .init(source: .voice, name: "Voice", level: 1))
        XCTAssertEqual(normalized[1], .init(source: .desktop, name: "Desktop audio", level: 0, muted: true))
        XCTAssertEqual(normalized[2].name, "First")
        XCTAssertEqual(normalized[2].level, 1)
        XCTAssertEqual(try JSONDecoder().decode([MixerEngine.Channel].self,
                                               from: JSONEncoder().encode(normalized)), normalized)
    }

    func testNormalizationUsesDefaultsAndKeepsFirstBuiltins() {
        XCTAssertEqual(MixerEngine.normalizedChannels([]), MixerEngine.defaultChannels)
        let channels: [MixerEngine.Channel] = [
            .init(source: .voice, name: "First voice", level: 0.4, muted: true),
            .init(source: .voice, name: "Second voice", level: 1),
            .init(source: .app(bundleID: ""), name: "Invalid"),
        ]
        let result = MixerEngine.normalizedChannels(channels)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].level, 0.4)
        XCTAssertTrue(result[0].muted)
        XCTAssertEqual(MixerEngine.normalizedChannels(result), result)
    }

    @MainActor
    func testMixerAggregateCannotBecomeVoiceSource() {
        let mixer = MonitorEngine.Candidate(id: 9, uid: MixerEngine.aggregateUID,
            name: "Seiren Mixer", hasInput: true, hasOutput: true)
        XCTAssertFalse(mixer.isEligible)
    }

    func testGainLaw() {
        XCTAssertEqual(MixerEngine.Channel(source: .voice, name: "Voice", level: 0.5).gain, 0.25)
        XCTAssertEqual(MixerEngine.Channel(source: .desktop, name: "Desktop", level: 1, muted: true).gain, 0)
        XCTAssertEqual(MixerEngine.Channel(source: .voice, name: "Voice", level: .nan).gain, 0)
    }

    func testProcessAttribution() {
        let bundles = ["/Applications/Chrome.app": "com.google.Chrome",
                       "/Applications/Outer.app": "outer"]
        func owner(_ id: String?, _ path: String?) -> String? {
            MixerEngine.owningAppBundleID(bundleID: id, executablePath: path) { bundles[$0] }
        }
        XCTAssertEqual(owner("helper", "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "com.google.Chrome")
        XCTAssertEqual(owner("inner", "/Applications/Outer.app/Contents/Inner.app/Contents/MacOS/Inner"), "outer")
        XCTAssertEqual(owner("plain", "/usr/bin/plain"), "plain")
        XCTAssertEqual(owner("com.apple.WebKit.GPU", "/System/Library/XPCServices/GPU"), "com.apple.Safari")
        XCTAssertEqual(owner("com.apple.WebKit.WebContent", nil), "com.apple.Safari")
        XCTAssertNil(owner(nil, "/usr/bin/plain"))
        XCTAssertEqual(owner(nil, "/Applications/Outer.app/Contents/MacOS/Outer"), "outer")
    }

    func testRunPolicy() {
        for enabled in [false, true] {
            for supported in [false, true] {
                for fx in [false, true] {
                    for mix in [false, true] {
                        for recording in [false, true] {
                            let expected: MixerEngine.State = !enabled ? .off : !supported ? .unsupportedOS
                                : !fx ? .needsFX : !mix ? .needsDriverUpdate : recording ? .running : .idle
                            XCTAssertEqual(MixerEngine.runPolicy(enabled: enabled, supportedOS: supported,
                                                                hasFX: fx, hasStreamMix: mix,
                                                                hasRecorders: recording), expected)
                        }
                    }
                }
            }
        }
    }
}

final class MixerDSPTests: XCTestCase {
    private var allocations: [UnsafeMutablePointer<Float>] = []
    private var lists: [UnsafeMutableAudioBufferListPointer] = []

    override func tearDown() {
        for list in lists { list.unsafeMutablePointer.deallocate() }
        for pointer in allocations { pointer.deallocate() }
        lists = []; allocations = []
        super.tearDown()
    }

    private func buffers(_ values: [Float], frames: Int = 32, channels: Int = 2)
        -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: values.count)
        list.count = values.count
        for (i, value) in values.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            p.initialize(repeating: value, count: frames * channels)
            allocations.append(p)
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels),
                                  mDataByteSize: UInt32(frames * channels * 4), mData: p)
        }
        lists.append(list)
        return list
    }

    private func samples(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: list[index].mData!.assumingMemoryBound(to: Float.self),
                                  count: Int(list[index].mDataByteSize) / 4))
    }

    func testMappedMixSkipsLoopbackSilencesFXAndAppliesGainsAndMute() throws {
        let mixer = try XCTUnwrap(seiren_mixer_create(48000, 1))
        defer { seiren_mixer_destroy(mixer) }
        seiren_mixer_map_input(mixer, 0, 0)
        seiren_mixer_map_input(mixer, 2, 1)
        seiren_mixer_map_input(mixer, 3, 2)
        seiren_mixer_set_gain(mixer, 0, 1)
        seiren_mixer_set_gain(mixer, 1, 0.25)
        seiren_mixer_set_gain(mixer, 2, 0.5)
        let input = buffers([0.1, 10, 0.2, 0.3])
        let output = buffers([1, 1])
        seiren_mixer_process(mixer, input.unsafePointer, output.unsafeMutablePointer)
        seiren_mixer_process(mixer, input.unsafePointer, output.unsafeMutablePointer)
        XCTAssertTrue(samples(output, 0).allSatisfy { $0 == 0 })
        for value in samples(output, 1) { XCTAssertEqual(value, 0.3, accuracy: 0.00001) }
        seiren_mixer_set_gain(mixer, 2, 0)
        seiren_mixer_process(mixer, input.unsafePointer, output.unsafeMutablePointer)
        XCTAssertEqual(samples(output, 1).last!, 0.15, accuracy: 0.00001)
        XCTAssertEqual(seiren_mixer_input_peak(mixer, 1), 10)
    }

    func testRampIsContinuousAcrossBuffers() throws {
        let mixer = try XCTUnwrap(seiren_mixer_create(48000, 0))
        defer { seiren_mixer_destroy(mixer) }
        seiren_mixer_map_input(mixer, 0, 0)
        let input = buffers([0.4], frames: 4)
        let output = buffers([0], frames: 4)
        seiren_mixer_set_gain(mixer, 0, 1)
        seiren_mixer_process(mixer, input.unsafePointer, output.unsafeMutablePointer)
        XCTAssertEqual(samples(output, 0), [0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4])
        seiren_mixer_set_gain(mixer, 0, 0)
        seiren_mixer_process(mixer, input.unsafePointer, output.unsafeMutablePointer)
        for (actual, expected) in zip(samples(output, 0), [Float](arrayLiteral: 0.3, 0.3, 0.2, 0.2, 0.1, 0.1, 0, 0)) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
    }

    func testLimiterIsStereoLinkedAndQuietSignalsPass() throws {
        let mixer = try XCTUnwrap(seiren_mixer_create(48000, 0))
        defer { seiren_mixer_destroy(mixer) }
        seiren_mixer_map_input(mixer, 0, 0)
        seiren_mixer_set_gain(mixer, 0, 1)
        let quiet = buffers([0.1])
        let output = buffers([0])
        seiren_mixer_process(mixer, quiet.unsafePointer, output.unsafeMutablePointer)
        seiren_mixer_process(mixer, quiet.unsafePointer, output.unsafeMutablePointer)
        XCTAssertEqual(samples(output, 0), [Float](repeating: 0.1, count: 64))
        let loud = buffers([2])
        let data = loud[0].mData!.assumingMemoryBound(to: Float.self)
        for f in 0..<32 { data[f * 2 + 1] = 1 }
        seiren_mixer_process(mixer, loud.unsafePointer, output.unsafeMutablePointer)
        let values = samples(output, 0)
        XCTAssertLessThanOrEqual(values.map(abs).max()!, pow(10, -1.0 / 20) + 0.000001)
        XCTAssertEqual(values[0], values[1] * 2, accuracy: 0.000001)
    }

    func testLimiterReleasesOver120Milliseconds() throws {
        let mixer = try XCTUnwrap(seiren_mixer_create(1000, 0))
        defer { seiren_mixer_destroy(mixer) }
        seiren_mixer_map_input(mixer, 0, 0)
        seiren_mixer_set_gain(mixer, 0, 1)
        let loud = buffers([2])
        let loudOutput = buffers([0])
        seiren_mixer_process(mixer, loud.unsafePointer, loudOutput.unsafeMutablePointer)
        let quiet = buffers([0.1], frames: 120)
        let quietOutput = buffers([0], frames: 120)
        seiren_mixer_process(mixer, quiet.unsafePointer, quietOutput.unsafeMutablePointer)
        let expectedGain = 1 - (1 - pow(10.0, -1.0 / 20.0) / 2) * exp(-1.0)
        XCTAssertEqual(samples(quietOutput, 0).last!, Float(0.1 * expectedGain), accuracy: 0.00001)
        for _ in 0..<10 {
            seiren_mixer_process(mixer, quiet.unsafePointer, quietOutput.unsafeMutablePointer)
        }
        XCTAssertEqual(samples(quietOutput, 0).last!, 0.1, accuracy: 0.00001)
    }

    func testMissingInputSilencesEveryOutputAndCountsCallbacks() throws {
        let mixer = try XCTUnwrap(seiren_mixer_create(48000, 1))
        defer { seiren_mixer_destroy(mixer) }
        seiren_mixer_map_input(mixer, 3, 0)
        seiren_mixer_set_gain(mixer, 0, 1)
        let input = buffers([0.5])
        let output = buffers([0.9, 0.9, 0.9])
        let callback = try XCTUnwrap(seiren_mixer_proc())
        var ts = AudioTimeStamp()
        XCTAssertEqual(callback(0, &ts, input.unsafePointer, &ts, output.unsafeMutablePointer,
                                &ts, UnsafeMutableRawPointer(mixer)), noErr)
        for index in 0..<3 { XCTAssertTrue(samples(output, index).allSatisfy { $0 == 0 }) }
        XCTAssertEqual(seiren_mixer_callbacks(mixer), 1)
        XCTAssertEqual(seiren_mixer_input_buffers(mixer), 1)
        XCTAssertEqual(seiren_mixer_output_buffers(mixer), 3)
        XCTAssertEqual(seiren_mixer_output_peak(mixer), 0)
    }

    func testMonoDuplicatesAndShortInputZerosTail() throws {
        let mixer = try XCTUnwrap(seiren_mixer_create(48000, 0))
        defer { seiren_mixer_destroy(mixer) }
        seiren_mixer_map_input(mixer, 0, 0)
        seiren_mixer_set_gain(mixer, 0, 1)
        let input = buffers([0.2], frames: 2, channels: 1)
        let output = buffers([1], frames: 4)
        seiren_mixer_process(mixer, input.unsafePointer, output.unsafeMutablePointer)
        seiren_mixer_process(mixer, input.unsafePointer, output.unsafeMutablePointer)
        XCTAssertEqual(samples(output, 0), [0.2, 0.2, 0.2, 0.2, 0, 0, 0, 0])
    }
}
