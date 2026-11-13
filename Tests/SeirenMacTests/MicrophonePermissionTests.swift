import AVFoundation
import SeirenKit
import XCTest
@testable import seiren_mac

@MainActor
final class MicrophonePermissionTests: XCTestCase {
    func testResolvedPermissionAppliesModeWithoutRequestingAgain() {
        for status in [AVAuthorizationStatus.authorized, .denied, .restricted] {
            var applied = false
            AppDelegate.requestMicrophoneAccessThen({ applied = true }, authorizationStatus: { status },
                requestAccess: { _ in XCTFail("Resolved access must not prompt again") })
            XCTAssertTrue(applied)
        }
    }

    func testFirstPermissionResponseAppliesModeEvenWhenDenied() async {
        for granted in [false, true] {
            let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false,
                                       microphoneAccess: { granted ? .granted : .denied })
            defer { engine.shutdown() }
            let applied = expectation(description: "Mode applied after permission response: \(granted)")
            var requested = false
            AppDelegate.requestMicrophoneAccessThen({
                engine.setMode(.always)
                applied.fulfill()
            },
                authorizationStatus: { .notDetermined }, requestAccess: { completion in
                    requested = true
                    completion(granted)
                })
            XCTAssertTrue(requested)
            await fulfillment(of: [applied], timeout: 1)
            XCTAssertEqual(engine.mode, .always)
            XCTAssertEqual(engine.state, granted ? .noDevice : .permissionDenied)
        }
    }
}
