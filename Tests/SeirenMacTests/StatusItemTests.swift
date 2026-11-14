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
            XCTAssertEqual(AppDelegate.statusSymbolName(for: state), symbol, "\(state)")
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
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
            let image = try XCTUnwrap(AppDelegate.statusButtonImage(for: state, status: status), "\(state)")
            XCTAssertEqual(image.accessibilityDescription, status, "\(state)")
            XCTAssertTrue(image.isTemplate, "\(state)")
        }
    }
}
