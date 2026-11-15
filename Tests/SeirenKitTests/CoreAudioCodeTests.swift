import CoreAudio
import SeirenKit
import XCTest

final class CoreAudioCodeTests: XCTestCase {
    func testAPrintableCodeIsShownAsFourCharactersAndItsNumber() {
        XCTAssertEqual(kAudioHardwareIllegalOperationError, 1852797029)
        XCTAssertEqual(CoreAudioCode.fourCharacters(UInt32(bitPattern: kAudioHardwareIllegalOperationError)), "'nope'")
        XCTAssertEqual(CoreAudioCode.errorDescription(kAudioHardwareIllegalOperationError),
                       "Core Audio error 'nope' (1852797029)")
    }

    func testACodeStartingWithPunctuationIsStillFourCharacters() {
        XCTAssertEqual(kAudioHardwareBadDeviceError, 560227702)
        XCTAssertEqual(CoreAudioCode.fourCharacters(UInt32(bitPattern: kAudioHardwareBadDeviceError)), "'!dev'")
        XCTAssertEqual(CoreAudioCode.errorDescription(kAudioHardwareBadDeviceError),
                       "Core Audio error '!dev' (560227702)")
    }

    func testANegativeCodeIsShownAsTheNumberAlone() {
        XCTAssertNil(CoreAudioCode.fourCharacters(UInt32(bitPattern: -50)))
        XCTAssertEqual(CoreAudioCode.errorDescription(-50), "Core Audio error -50")
    }

    func testZeroIsShownAsTheNumberAlone() {
        XCTAssertNil(CoreAudioCode.fourCharacters(0))
        XCTAssertEqual(CoreAudioCode.errorDescription(0), "Core Audio error 0")
    }

    func testOneUnprintableByteRulesOutTheFourCharacterForm() {
        XCTAssertEqual(CoreAudioCode.fourCharacters(0x6C70_636D), "'lpcm'")
        XCTAssertNil(CoreAudioCode.fourCharacters(0x6C70_637F))
        XCTAssertNil(CoreAudioCode.fourCharacters(0x1F70_636D))
    }
}
