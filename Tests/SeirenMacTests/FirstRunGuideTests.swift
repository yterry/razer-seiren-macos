import Foundation
import XCTest
@testable import seiren_mac

final class FirstRunGuideTests: XCTestCase {
    private let readme = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("README.md")

    private func section(_ title: String) throws -> String {
        let markdown = try String(contentsOf: readme, encoding: .utf8)
        return try XCTUnwrap(markdown.components(separatedBy: "\n## ").first { $0.hasPrefix(title + "\n") },
                             "Missing README section: \(title)")
    }

    func testFirstRunAndSupportNameTheVisibleActions() throws {
        for (title, actions) in [
            ("First run", [Strings.modeAlways, Strings.modeAuto, Strings.welcomeTurnOnAuto,
                           Strings.welcomeNotNow, Strings.volumeCaption]),
            ("Troubleshooting", [Strings.copyDiagnostics])
        ] {
            // Check the instructions themselves, before the reference sections below them.
            let introduction = try section(title).components(separatedBy: "\n### ")[0]
            let visibleText = String(try AttributedString(markdown: introduction).characters)
            for action in actions {
                XCTAssertTrue(visibleText.contains(action), "\(title) should name ‘\(action)’")
            }
        }
    }

    func testGuideLinksResolveToLocalFilesAndHeadings() throws {
        for title in ["First run", "Troubleshooting"] {
            let guide = try AttributedString(markdown: section(title), baseURL: readme)
            let links = Set(guide.runs.compactMap(\.link).filter(\.isFileURL))
            XCTAssertFalse(links.isEmpty, "Expected local links in \(title)")
            for link in links {
                let target = URL(fileURLWithPath: link.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "Broken link in \(title): \(link)")
                if let fragment = link.fragment {
                    let markdown = try String(contentsOf: target, encoding: .utf8)
                    let headings = markdown.split(separator: "\n").filter { $0.hasPrefix("#") }
                    let anchors = headings.map { heading in
                        heading.drop(while: { $0 == "#" || $0 == " " }).lowercased()
                            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }
                            .replacingOccurrences(of: " ", with: "-")
                    }
                    XCTAssertTrue(anchors.contains(fragment), "Broken link in \(title): \(link.lastPathComponent)#\(fragment)")
                }
            }
        }
    }
}
