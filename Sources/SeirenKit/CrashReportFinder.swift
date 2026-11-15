import Foundation

/// Finds the report macOS wrote after the app crashed. macOS writes one file per
/// crash to `~/Library/Logs/DiagnosticReports`, named after the process, such as
/// `seiren-mac-2026-11-14-101010.ips` (`.crash` on older systems).
public enum CrashReportFinder {
    /// The most recently modified `<processName>*.ips` or `<processName>*.crash`
    /// file in `directory` that was modified after `date`, or nil when there is none.
    /// Throws when `directory` is missing or can't be read.
    public static func newestReport(in directory: URL, processName: String, after date: Date) throws -> URL? {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        var newest: (url: URL, modified: Date)?
        for url in files where url.lastPathComponent.hasPrefix(processName)
            && ["ips", "crash"].contains(url.pathExtension) {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified > date else { continue }
            if newest.map({ modified > $0.modified }) ?? true { newest = (url, modified) }
        }
        return newest?.url
    }
}
