import XCTest
import IOKit
@testable import SeirenKit

/// Hardware-free behavior of the app-level controller: state bookkeeping, the
/// wake-time `reassert()` contract, and its retry policy. The HID send path
/// itself is verified on real hardware via `seiren-probe lighting`.
///
/// None of these tests call `start()`, so no IOKit callbacks can fire and
/// `currentDevice` is guaranteed nil - `.noDevice` outcomes are deterministic
/// whether or not a mic is attached to the test machine.
@MainActor
final class LightingControllerTests: XCTestCase {

    private final class Recorder: LightingControllerDelegate {
        var changes = 0
        func lightingControllerDidChange(_ controller: LightingController) { changes += 1 }
    }

    func testApplyWithoutDeviceRemembersStateAndReportsNoDevice() {
        let controller = LightingController()
        let recorder = Recorder()
        controller.delegate = recorder

        let state = LightingState(effect: .static, color: RGB(0, 255, 0),
                                  brightnessPercent: 80)
        controller.apply(state)

        XCTAssertEqual(controller.desiredState, state,
                       "the choice must survive to be re-asserted on attach/wake")
        XCTAssertEqual(controller.lastError, .noDevice)
        XCTAssertEqual(recorder.changes, 1)
    }

    func testReassertBeforeAnyUserChoiceIsANoOp() {
        // The "never touch an unconfigured device" contract: waking the Mac
        // must not make the app start driving lights nobody asked it to.
        let controller = LightingController()
        let recorder = Recorder()
        controller.delegate = recorder

        controller.reassert()

        XCTAssertNil(controller.lastError)
        XCTAssertEqual(recorder.changes, 0)
    }

    func testReassertWithoutDeviceFailsOnceAndDoesNotRetry() {
        // .noDevice is not transient (reconnection is the attach callback's
        // job), so a wake with no mic attached asserts exactly once.
        let controller = LightingController()
        let recorder = Recorder()
        controller.delegate = recorder
        controller.apply(LightingState(effect: .spectrum))
        XCTAssertEqual(recorder.changes, 1)

        controller.reassert(attempts: 3, interval: 0.05)
        XCTAssertEqual(recorder.changes, 2)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        XCTAssertEqual(recorder.changes, 2, "no retries may fire for .noDevice")
    }

    func testWakeRetryPolicy() {
        XCTAssertTrue(LightingController.isTransient(.io(kIOReturnError)),
                      "USB stack still resuming after wake")
        XCTAssertTrue(LightingController.isTransient(.noReply),
                      "device enumerated but not answering yet")
        XCTAssertTrue(LightingController.isTransient(.deviceRejected(2)),
                      "groggy firmware can refuse the first command")
        XCTAssertFalse(LightingController.isTransient(.noDevice),
                       "the attach callback owns reconnection")
        XCTAssertFalse(LightingController.isTransient(.permissionDenied),
                       "retrying cannot grant Input Monitoring")
    }
}
