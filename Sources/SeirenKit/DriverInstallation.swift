import Foundation
import Security

package enum DriverInstallation {
    package enum SigningIdentity {
        case adHoc
        case developerTeam(String)

        package static func runningApp() throws -> Self {
            var runningCode: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode,
                  SecCodeCheckValidity(runningCode, [], nil) == errSecSuccess,
                  SecCodeCopyStaticCode(runningCode, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                                &information) == errSecSuccess,
                  let signature = information as? [String: Any],
                  let flags = signature[kSecCodeInfoFlags as String] as? UInt32 else {
                throw Failure.invalidAppSignature
            }
            if SecCodeSignatureFlags(rawValue: flags).contains(.adhoc) { return .adHoc }
            guard let team = signature[kSecCodeInfoTeamIdentifier as String] as? String else {
                throw Failure.invalidAppSignature
            }
            return .developerTeam(team)
        }
    }

    package enum Failure: Swift.Error, Equatable {
        case invalidAppSignature
        case invalidDriverSignature
        case cancelled
        case scriptFailed(status: Int32, message: String)
    }

    package typealias ScriptRunner = ([String]) throws -> (status: Int32, stderr: String)

    package static func install(source: URL, destinationDirectory: URL, privileged: Bool,
                                signingIdentity: SigningIdentity, execute: ScriptRunner = runAppleScript) throws {
        let requirement = try driverRequirement(for: signingIdentity)
        try validateDriver(at: source, requirement: requirement)

        let installed = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        let takeOwnership = privileged
            ? #"/usr/sbin/chown -R root:wheel "$staged" && /bin/chmod -R 755 "$staged" || exit"# : ""
        let shell = """
        /bin/mkdir -p "$2" || exit
        staging=$(/usr/bin/mktemp -d "$2/.SeirenFX.XXXXXX") || exit
        trap '/bin/rm -rf "$staging"' EXIT
        staged="$staging/${3##*/}"
        /bin/cp -R "$1" "$staged" || exit
        \(takeOwnership)
        if [ -n "$4" ]; then
            /usr/bin/codesign --verify --strict --all-architectures -R "=$4" "$staged"
        else
            /usr/bin/codesign --verify --strict --all-architectures "$staged"
        fi || exit \(rejectedDriverStatus)
        /bin/rm -rf "$3" && /bin/mv "$staged" "$3"\(privileged ? " && \(restartAudio)" : "")
        """
        try run(shell, arguments: [source.path, destinationDirectory.path, installed.path, requirement ?? ""],
                privileged: privileged, execute: execute)
    }

    package static func uninstall(at installed: URL, privileged: Bool) throws {
        let remove = #"/bin/rm -rf "$1""#
        try run(remove + (privileged ? " && \(restartAudio)" : ""), arguments: [installed.path],
                privileged: privileged, execute: runAppleScript)
    }

    private static let restartAudio = "(/usr/bin/killall coreaudiod 2>/dev/null || true)"
    private static let rejectedDriverStatus: Int32 = 86

    private static func driverRequirement(for identity: SigningIdentity) throws -> String? {
        guard case .developerTeam(let team) = identity else { return nil }
        guard team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw Failure.invalidAppSignature
        }
        // Match the Apple-issued signing certificate's team on every architecture.
        return #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }

    private static func validateDriver(at url: URL, requirement text: String?) throws {
        var requirement: SecRequirement?
        if let text, SecRequirementCreateWithString(text as CFString, [], &requirement) != errSecSuccess {
            throw Failure.invalidAppSignature
        }

        var driver: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &driver) == errSecSuccess, let driver,
              SecStaticCodeCheckValidity(driver, flags, requirement) == errSecSuccess else {
            throw Failure.invalidDriverSignature
        }
    }

    private static func run(_ shell: String, arguments: [String], privileged: Bool, execute: ScriptRunner) throws {
        let authorization = privileged ? " with administrator privileges" : ""
        // Quote the fixed script and each argument separately for /bin/sh.
        let script = """
        on run argv
            set commandLine to "/bin/sh -c " & quoted form of item 1 of argv & " seiren-driver"
            repeat with pathArgument in rest of argv
                set commandLine to commandLine & " " & quoted form of (contents of pathArgument)
            end repeat
            do shell script commandLine\(authorization)
        end run
        """
        let (status, stderr) = try execute(["-e", script, shell] + arguments)
        guard status != 0 else { return }
        let error = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if error.hasSuffix("(-128)") { throw Failure.cancelled }
        if error.hasSuffix("(\(rejectedDriverStatus))") { throw Failure.invalidDriverSignature }
        throw Failure.scriptFailed(status: status, message: stderr)
    }

    package static func runAppleScript(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, stderr)
    }
}
