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
}
