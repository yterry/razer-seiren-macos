import AppKit
import SeirenKit
import XCTest
@testable import seiren_mac

@MainActor
final class StatusItemTests: XCTestCase {
    func testAttentionStatesUseCrossedOutMicAndOthersKeepTheirGlyph() {
        let expected: [(MonitorEngine.State, String)] = [
            (.permissionDenied, "mic.badge.xmark"),
            (.needsFX, "mic.badge.xmark"),
            (.failed(-1), "mic.badge.xmark"),
            (.running, "waveform.and.mic"),
            (.waiting, "mic"),
            (.noDevice, "mic"),
            (.stopped, "mic"),
        ]
        for (state, symbol) in expected {
            XCTAssertEqual(AppDelegate.statusSymbolName(for: state, fxRouteFailed: false), symbol, "\(state)")
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testRunningWithAFailedSeirenFXRouteUsesCrossedOutMic() {
        XCTAssertEqual(AppDelegate.statusSymbolName(for: .running, fxRouteFailed: true), "mic.badge.xmark")
    }

    func testStatusImageIsDescribedByTheStatusLine() throws {
        let cases: [(MonitorEngine.State, String)] = [
            (.running, "Monitoring: Seiren"),
            (.waiting, "Auto: waiting for an app to use the mic"),
            (.stopped, "Monitoring off"),
            (.noDevice, "No Seiren detected"),
            (.needsFX, "Seiren needs Seiren FX"),
            (.permissionDenied, "Microphone access denied"),
            (.failed(-1), "Couldn't start audio"),
        ]
        for (state, status) in cases {
            let image = try XCTUnwrap(AppDelegate.statusButtonImage(for: state, fxRouteFailed: false, status: status),
                                      "\(state)")
            XCTAssertEqual(image.accessibilityDescription, status, "\(state)")
            XCTAssertTrue(image.isTemplate, "\(state)")
        }
    }

    func testNewReleaseItemNamesTheVersionAndCarriesItsReleasePage() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/yterry/razer-seiren-macos/releases/tag/v1.10.0"))
        let release = UpdateChecker.Release(version: try XCTUnwrap(ReleaseVersion("v1.10.0")), url: url)

        let item = AppDelegate.newReleaseItem(release, target: nil)

        XCTAssertEqual(item.title, "Version 1.10.0 is available")
        XCTAssertNotNil(item.action)
        XCTAssertEqual(item.representedObject as? URL, url)
    }
}
