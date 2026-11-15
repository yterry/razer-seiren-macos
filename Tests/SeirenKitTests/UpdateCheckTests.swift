import Foundation
import XCTest
import SeirenKit

@MainActor
final class UpdateCheckTests: XCTestCase {
    /// Records each request and answers with a canned response, so no test touches the network.
    private final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private let answer: @Sendable (URLRequest) throws -> (Data, URLResponse)

        init(answer: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
            self.answer = answer
        }

        convenience init(status: Int = 200, body: String) {
            self.init { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        }

        convenience init(latestTag tag: String) {
            self.init(body: #"{"tag_name": "\#(tag)", "html_url": "https://example.com/elsewhere", "name": "Seiren \#(tag)"}"#)
        }

        var requests: [URLRequest] { lock.withLock { recorded } }

        var fetch: UpdateChecker.Fetch {
            { request in
                try self.lock.withLock {
                    self.recorded.append(request)
                    return try self.answer(request)
                }
            }
        }
    }

    private struct Offline: Error {}

    /// A throwaway suite stored in its own temporary directory, never the standard domain.
    private func makeDefaults() throws -> UserDefaults {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeirenKitTests.UpdateCheckTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = directory.appendingPathComponent("defaults").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try FileManager.default.removeItem(at: directory)
        }
        return defaults
    }

    func testVersionComparison() throws {
        let v1_10 = try XCTUnwrap(ReleaseVersion("1.10.0"))
        let v1_9 = try XCTUnwrap(ReleaseVersion("1.9.0"))
        XCTAssertGreaterThan(v1_10, v1_9)
        XCTAssertLessThan(v1_9, v1_10)
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("2.0.0")), v1_10)
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("1.9.1")), v1_9)
        XCTAssertEqual(ReleaseVersion("v1.10.0"), v1_10)
        XCTAssertEqual(v1_10.description, "1.10.0")

        // Development builds and anything that is not a release tag have no version to compare.
        for notARelease in ["0.0.0-dev", "1.6.0-beta.1", "unknown", "", "1.10", "1.10.0.1", "v", "1..0", "1.x.0"] {
            XCTAssertNil(ReleaseVersion(notARelease), notARelease)
        }
    }

    func testNewerReleaseIsAvailableAndLinksToItsReleasePage() async throws {
        let github = FakeGitHub(latestTag: "v1.10.0")
        let checker = UpdateChecker(settings: Settings(try makeDefaults()), runningVersion: "1.9.0", fetch: github.fetch)
        var changes = 0
        checker.onChange = { changes += 1 }

        await checker.check()

        let release = try XCTUnwrap(checker.available)
        XCTAssertEqual(release.version.description, "1.10.0")
        XCTAssertEqual(release.url.absoluteString, "https://github.com/yterry/razer-seiren-macos/releases/tag/v1.10.0")
        XCTAssertEqual(changes, 1)

        // A later check that finds the same release changes nothing.
        await checker.check()
        XCTAssertEqual(changes, 1)
    }

    func testRequestIsAPlainGETForTheLatestRelease() async throws {
        let github = FakeGitHub(latestTag: "v1.5.0")
        let checker = UpdateChecker(settings: Settings(try makeDefaults()), runningVersion: "1.5.0", fetch: github.fetch)

        await checker.check()

        let request = try XCTUnwrap(github.requests.first)
        XCTAssertEqual(github.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/yterry/razer-seiren-macos/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.allHTTPHeaderFields ?? [:], [:])
        XCTAssertNil(request.httpBody)
    }

    func testSameOrOlderReleaseShowsNothing() async throws {
        for running in ["1.10.0", "1.11.0", "2.0.0"] {
            let github = FakeGitHub(latestTag: "v1.10.0")
            let checker = UpdateChecker(settings: Settings(try makeDefaults()), runningVersion: running, fetch: github.fetch)
            await checker.check()
            XCTAssertEqual(github.requests.count, 1, running)
            XCTAssertNil(checker.available, running)
        }
    }

    func testTimerTickChecksAgainOnly24HoursOfClockTimeAfterTheLastCheck() async throws {
        let github = FakeGitHub(latestTag: "v1.5.0")
        let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var clock = launch
        let checker = UpdateChecker(settings: Settings(try makeDefaults()), runningVersion: "1.5.0",
                                    fetch: github.fetch, now: { clock })

        await checker.check()
        XCTAssertEqual(github.requests.count, 1)

        clock = launch.addingTimeInterval(23 * 60 * 60)
        await checker.checkIfDue()
        XCTAssertEqual(github.requests.count, 1)

        clock = launch.addingTimeInterval(24 * 60 * 60)
        await checker.checkIfDue()
        XCTAssertEqual(github.requests.count, 2)

        clock = launch.addingTimeInterval(47 * 60 * 60)
        await checker.checkIfDue()
        XCTAssertEqual(github.requests.count, 2)
    }

    func testDevelopmentBuildMakesNoRequest() async throws {
        let github = FakeGitHub(latestTag: "v1.10.0")
        let checker = UpdateChecker(settings: Settings(try makeDefaults()), runningVersion: "0.0.0-dev", fetch: github.fetch)

        await checker.check()

        XCTAssertTrue(github.requests.isEmpty)
        XCTAssertNil(checker.available)
    }

    func testFailedRequestShowsNothing() async throws {
        let failures = [
            FakeGitHub { _ in throw Offline() },
            FakeGitHub(status: 403, body: #"{"message": "API rate limit exceeded"}"#),
            FakeGitHub(status: 404, body: #"{"message": "Not Found"}"#),
            FakeGitHub(body: "<html>not json</html>"),
            FakeGitHub(latestTag: "nightly"),
        ]
        for github in failures {
            let checker = UpdateChecker(settings: Settings(try makeDefaults()), runningVersion: "1.9.0", fetch: github.fetch)
            var changes = 0
            checker.onChange = { changes += 1 }

            await checker.check()

            XCTAssertEqual(github.requests.count, 1)
            XCTAssertNil(checker.available)
            XCTAssertEqual(changes, 0)
        }
    }

    func testTurnedOffCheckMakesNoRequestOnAnyLaunch() async throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "updates.checkEnabled")

        for _ in 0..<2 {
            let github = FakeGitHub(latestTag: "v9.0.0")
            let checker = UpdateChecker(settings: Settings(defaults), runningVersion: "1.0.0", fetch: github.fetch)
            await checker.check()
            XCTAssertTrue(github.requests.isEmpty)
            XCTAssertNil(checker.available)
        }
    }
}
