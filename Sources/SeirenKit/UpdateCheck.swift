import Foundation

/// A release version as `major.minor.patch`, with an optional leading "v" as in
/// the release tags. Anything else - a development build such as `0.0.0-dev`,
/// or "unknown" - has no release version and is never compared.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        let numbers = string.hasPrefix("v") ? string.dropFirst() : Substring(string)
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part) else { return nil }
            components.append(value)
        }
        self.components = components
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

/// Asks GitHub for the latest release, at launch and once a day, and says when
/// it is newer than the running app. The request is a plain GET with no cookies,
/// no cache and nothing about this install; a failed request changes nothing.
@MainActor
public final class UpdateChecker {
    public struct Release: Equatable, Sendable {
        public let version: ReleaseVersion
        /// The release's page on GitHub.
        public let url: URL

        public init(version: ReleaseVersion, url: URL) {
            self.version = version
            self.url = url
        }
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/yterry/razer-seiren-macos/releases/latest")!
    static let releasePageBase = "https://github.com/yterry/razer-seiren-macos/releases/tag/"
    private nonisolated static let session = URLSession(configuration: .ephemeral)
    /// The real request: an ephemeral session keeps no cookies or cache.
    public nonisolated static let fetchFromNetwork: Fetch = { try await session.data(for: $0) }

    /// The newer release, once a check has found one.
    public private(set) var available: Release?
    /// Called when `available` changes.
    public var onChange: (() -> Void)?

    private let settings: Settings
    private let runningVersion: ReleaseVersion?
    private let fetch: Fetch
    private var timer: Timer?

    public init(settings: Settings, runningVersion: String,
                fetch: @escaping Fetch = UpdateChecker.fetchFromNetwork) {
        self.settings = settings
        self.runningVersion = ReleaseVersion(runningVersion)
        self.fetch = fetch
    }

    /// Checks now and then every 24 hours.
    public func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    /// One check. Makes no request when the check is turned off or the running
    /// app is a development build.
    public func check() async {
        guard settings.updateCheckEnabled, let runningVersion else { return }
        guard let (data, response) = try? await fetch(URLRequest(url: Self.latestReleaseURL)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = try? JSONDecoder().decode(LatestRelease.self, from: data),
              let version = ReleaseVersion(latest.tag_name),
              let url = URL(string: Self.releasePageBase + latest.tag_name)
        else { return }
        let release = version > runningVersion ? Release(version: version, url: url) : nil
        guard release != available else { return }
        available = release
        onChange?()
    }

    private struct LatestRelease: Decodable {
        let tag_name: String
    }
}
