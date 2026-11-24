import Foundation
import SeirenKit
import XCTest

final class DriverInstallerTests: XCTestCase {
    func testCopiesTheWholeSignedBundleFromAPathWithQuotesSpacesAndBackslashes() throws {
        let root = try makeTemporaryDirectory()
        let source = try makeSignedDriver(in: root.appendingPathComponent("Seiren's \"test\" \\ folder"))
        let destination = root.appendingPathComponent("Mac's \"test\" \\ HAL")

        try DriverInstallation.install(source: source, destinationDirectory: destination,
                                       privileged: false, signingIdentity: .adHoc)

        try run("/usr/bin/diff", arguments: ["-r", source.path,
                                              destination.appendingPathComponent(source.lastPathComponent).path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["SeirenFX.driver"])
    }

    func testRejectsADriverChangedAfterThePreflightCheckAndKeepsThePreviousInstall() throws {
        let root = try makeTemporaryDirectory()
        let source = try makeSignedDriver(in: root.appendingPathComponent("App"))
        let destination = root.appendingPathComponent("HAL")
        let previous = destination.appendingPathComponent("SeirenFX.driver/previous.txt")
        try FileManager.default.createDirectory(at: previous.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("previous driver".utf8).write(to: previous)

        XCTAssertThrowsError(try DriverInstallation.install(
            source: source, destinationDirectory: destination, privileged: false,
            signingIdentity: .adHoc, execute: { arguments in
                try Data("swapped after the check".utf8)
                    .write(to: source.appendingPathComponent("Contents/Resources/test.txt"))
                return try DriverInstallation.runAppleScript(arguments)
            }
        )) { error in
            XCTAssertEqual(error as? DriverInstallation.Failure, .invalidDriverSignature)
        }
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "previous driver")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["SeirenFX.driver"])
    }

    func testRejectsAChangedSealedResourceBeforeRunningThePrivilegedCommand() throws {
        let root = try makeTemporaryDirectory()
        let source = try makeSignedDriver(in: root)
        try Data("changed after signing".utf8).write(to: source.appendingPathComponent("Contents/Resources/test.txt"))

        XCTAssertThrowsError(try DriverInstallation.install(
            source: source, destinationDirectory: root.appendingPathComponent("HAL"), privileged: true,
            signingIdentity: .adHoc, execute: { _ in
                XCTFail("Signature validation must finish before starting osascript")
                return (0, "")
            }
        )) { error in
            XCTAssertEqual(error as? DriverInstallation.Failure, .invalidDriverSignature)
        }
    }

    func testRequiresATeamSignatureWhenTheAppHasADeveloperTeam() throws {
        let root = try makeTemporaryDirectory()
        let source = try makeSignedDriver(in: root)

        XCTAssertThrowsError(try DriverInstallation.install(
            source: source, destinationDirectory: root.appendingPathComponent("HAL"), privileged: true,
            signingIdentity: .developerTeam("ABCDE12345"), execute: { _ in
                XCTFail("An ad-hoc driver must not reach osascript when a team is required")
                return (0, "")
            }
        )) { error in
            XCTAssertEqual(error as? DriverInstallation.Failure, .invalidDriverSignature)
        }
    }

    func testPrivilegedInstallRequestsAuthorizationOnceAndReportsCancellation() throws {
        let root = try makeTemporaryDirectory()
        let source = try makeSignedDriver(in: root)
        let destination = root.appendingPathComponent("HAL")
        var invocations = 0

        XCTAssertThrowsError(try DriverInstallation.install(
            source: source, destinationDirectory: destination, privileged: true,
            signingIdentity: .adHoc, execute: { arguments in
                invocations += 1
                let script = try XCTUnwrap(arguments.dropFirst().first)
                XCTAssertFalse(script.contains(source.path))
                XCTAssertTrue(arguments.contains(source.path))
                let shell = try XCTUnwrap(arguments.dropFirst(2).first)
                try run("/bin/sh", arguments: ["-n", "-c", shell])
                try run("/usr/bin/osacompile", arguments: ["-o", root.appendingPathComponent("install.scpt").path,
                                                            "-e", script])
                return (1, "0:42: execution error: User canceled. (-128)\n")
            }
        )) { error in
            XCTAssertEqual(error as? DriverInstallation.Failure, .cancelled)
        }
        XCTAssertEqual(invocations, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUninstallRemovesOnlyTheBundleAtTheQuotedPath() throws {
        let root = try makeTemporaryDirectory()
        let installed = root.appendingPathComponent("Mac's \"test\" \\ HAL").appendingPathComponent("SeirenFX.driver")
        let sibling = installed.deletingLastPathComponent().appendingPathComponent("Other.driver")
        for path in [installed, sibling] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }

        try DriverInstallation.uninstall(at: installed, privileged: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSignedDriver(in parent: URL) throws -> URL {
        let driver = parent.appendingPathComponent("SeirenFX.driver")
        let contents = driver.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        for directory in [macOS, resources] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macOS.appendingPathComponent("SeirenFX"))
        let info = [
            "CFBundleExecutable": "SeirenFX",
            "CFBundleIdentifier": "com.yterry.seiren-driver-test",
            "CFBundlePackageType": "BNDL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("sealed driver resource".utf8).write(to: resources.appendingPathComponent("test.txt"))
        try run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", driver.path])
        return driver
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable): \(message)")
    }
}
