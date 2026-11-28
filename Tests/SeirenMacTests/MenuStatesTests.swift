import AppKit
import CoreAudio
import SeirenKit
import XCTest
@testable import seiren_mac

/// Submenus that show an empty or error state instead of their usual items.
@MainActor
final class MenuStatesTests: XCTestCase {
    func testAddAppWithNothingToAddShowsOneDisabledLine() throws {
        let menu = AppDelegate.addAppMenu([], atLimit: false, target: nil)
        XCTAssertEqual(menu.items.map(\.title), ["No other apps are open"])
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(item.action)
    }

    func testAddAppListsEachChoiceWithItsBundleID() throws {
        let target = NSObject()
        let menu = AppDelegate.addAppMenu([.init(bundleID: "com.example.music", name: "Music", icon: nil)],
                                          atLimit: false, target: target)
        XCTAssertEqual(menu.items.map(\.title), ["Music"])
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.action, NSSelectorFromString("addMixerApp:"))
        XCTAssertTrue(item.target === target)
        XCTAssertEqual(item.representedObject as? String, "com.example.music")
    }

    func testAddAppAtTheChannelLimitSaysSoAndListsNothing() throws {
        let menu = AppDelegate.addAppMenu([.init(bundleID: "com.example.music", name: "Music", icon: nil)],
                                          atLimit: true, target: nil)
        XCTAssertEqual(menu.items.map(\.title), ["Up to 6 apps"])
        XCTAssertFalse(try XCTUnwrap(menu.items.first).isEnabled)
    }

    func testStudioAtAnUnsupportedRateShowsTheGateOnlyOnAnActiveFXRoute() {
        let choices = ["Off", "Reduce noise (gate)", "Studio Denoise (RNNoise)"]
        let fallback = "Using the noise gate because Studio Denoise requires 48 or 96 kHz."
        for active in [false, true] {
            let items = AppDelegate.noiseSuppressionItems(selected: .studio, studioAvailable: false,
                                                          isRoutingThroughFX: active, hasHeadphones: true, target: nil)
            XCTAssertEqual(items.map(\.title), active ? choices + [fallback] : choices)
            XCTAssertEqual(items.map(\.isEnabled), active ? [true, true, false, false] : [true, true, false])
            XCTAssertEqual(items.filter { $0.state == .on }.map(\.title), ["Studio Denoise (RNNoise)"])
        }
    }

    func testAvailableStudioExplainsLatencyWithAndWithoutHeadphones() {
        for hasHeadphones in [false, true] {
            let items = AppDelegate.noiseSuppressionItems(selected: .studio, studioAvailable: true,
                                                          isRoutingThroughFX: true, hasHeadphones: hasHeadphones,
                                                          target: nil)
            let caption = hasHeadphones
                ? "Studio: removes steady noise · your monitor stays low-latency"
                : "Studio: removes steady noise · adds ~10 ms to Seiren FX"
            XCTAssertEqual(items.map(\.title), ["Off", "Reduce noise (gate)", "Studio Denoise (RNNoise)", caption])
            XCTAssertEqual(items.map(\.isEnabled), [true, true, true, false])
            XCTAssertEqual(items.filter { $0.state == .on }.map(\.title), ["Studio Denoise (RNNoise)"])
        }
    }

    func testOtherSuppressionChoicesHaveNoStudioCaptionAtAnUnsupportedRate() {
        for (mode, title) in [(MonitorEngine.NoiseSuppression.off, "Off"), (.gate, "Reduce noise (gate)")] {
            let items = AppDelegate.noiseSuppressionItems(selected: mode, studioAvailable: false,
                                                          isRoutingThroughFX: true, hasHeadphones: false, target: nil)
            XCTAssertEqual(items.map(\.title), ["Off", "Reduce noise (gate)", "Studio Denoise (RNNoise)"])
            XCTAssertEqual(items.filter { $0.state == .on }.map(\.title), [title])
        }
    }

    func testALightingErrorOffersTryAgainUnderTheErrorLine() throws {
        let target = NSObject()
        let menu = AppDelegate.lightingMenu(lastError: .noReply, deviceConnected: true, current: nil, target: target)
        let titles = menu.items.map(\.title)
        let error = try XCTUnwrap(titles.firstIndex(of: "Couldn't reach the mic's lighting"))
        XCTAssertFalse(menu.items[error].isEnabled)
        XCTAssertEqual(titles.count, error + 2)
        let retry = menu.items[error + 1]
        XCTAssertEqual(retry.title, "Try Again")
        XCTAssertTrue(retry.isEnabled)
        XCTAssertEqual(retry.action, NSSelectorFromString("retryLighting"))
        XCTAssertTrue(retry.target === target)
        XCTAssertTrue(AppDelegate.instancesRespond(to: NSSelectorFromString("retryLighting")))
    }

    func testLightingWithoutAnErrorOrWithADeniedPermissionOffersNoTryAgain() {
        for error in [nil, LightingError.permissionDenied] {
            let menu = AppDelegate.lightingMenu(lastError: error, deviceConnected: true, current: nil, target: nil)
            XCTAssertFalse(menu.items.contains { $0.title == "Try Again" }, "\(String(describing: error))")
            XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Couldn't reach") }, "\(String(describing: error))")
        }
    }

    func testUnpluggedLightingWithAStaleTransientErrorShowsOnlyTheConnectLine() {
        assertUnpluggedLightingShowsOnlyTheConnectLine(lastError: .noReply)
    }

    func testUnpluggedLightingWithNoDeviceErrorShowsOnlyTheConnectLine() {
        assertUnpluggedLightingShowsOnlyTheConnectLine(lastError: .noDevice)
    }

    func testAFailedMixerWithVoiceOffSeparatesTheErrorBlockFromTheVoiceLine() throws {
        let target = NSObject()
        let items = AppDelegate.mixerStateItems(state: .failed(kAudioHardwareIllegalOperationError), voiceOff: true,
                                                target: target)
        XCTAssertEqual(items.map(\.title), ["Couldn't start the Stream Mixer",
                                            "Core Audio error 'nope' (1852797029)",
                                            "Try Again", "",
                                            "Voice is silent while monitoring is Off"])
        XCTAssertEqual(items.map(\.isSeparatorItem), [false, false, false, true, false])
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertFalse(items[1].isEnabled)
        let retry = items[2]
        XCTAssertTrue(retry.isEnabled)
        XCTAssertEqual(retry.action, NSSelectorFromString("retryMixer"))
        XCTAssertTrue(retry.target === target)
        XCTAssertTrue(AppDelegate.instancesRespond(to: NSSelectorFromString("retryMixer")))
        XCTAssertFalse(items[4].isEnabled)
    }

    func testAFailedMixerWithVoiceOnHasNoSeparatorOrVoiceLine() {
        let items = AppDelegate.mixerStateItems(state: .failed(kAudioHardwareIllegalOperationError), voiceOff: false,
                                                target: nil)
        XCTAssertEqual(items.map(\.title), ["Couldn't start the Stream Mixer",
                                            "Core Audio error 'nope' (1852797029)", "Try Again"])
        XCTAssertFalse(items.contains(where: \.isSeparatorItem))
    }

    func testARunningMixerWithVoiceOffPutsTheVoiceLineDirectlyUnderTheLiveLine() {
        let items = AppDelegate.mixerStateItems(state: .running, voiceOff: true, target: nil)
        XCTAssertEqual(items.map(\.title), ["Live · mixing into Seiren Stream Mix",
                                            "Voice is silent while monitoring is Off"])
        XCTAssertFalse(items.contains(where: \.isSeparatorItem))
        XCTAssertFalse(items.contains(where: \.isEnabled))
    }

    private func assertUnpluggedLightingShowsOnlyTheConnectLine(lastError: LightingError,
                                                                file: StaticString = #filePath,
                                                                line: UInt = #line) {
        let menu = AppDelegate.lightingMenu(lastError: lastError, deviceConnected: false, current: nil,
                                            target: NSObject())
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, "Applies when the Seiren is connected", file: file, line: line)
        XCTAssertFalse(titles.contains { $0.hasPrefix("Couldn't reach") }, file: file, line: line)
        XCTAssertFalse(titles.contains("Try Again"), file: file, line: line)
    }
}
