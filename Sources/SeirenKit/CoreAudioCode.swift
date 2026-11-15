import CoreAudio

/// Core Audio packs many of its constants and error codes into four ASCII
/// characters, and Apple's headers and forum posts quote them that way
/// (`'nope'`), so a code is easier to look up in that form than as a number.
public enum CoreAudioCode {
    /// `value` as four characters in single quotes, such as `'nope'`, or nil
    /// when any of its four bytes is not printable ASCII.
    public static func fourCharacters(_ value: UInt32) -> String? {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                     UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
              let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        return "'\(text)'"
    }

    /// `Core Audio error 'nope' (1852797029)`, or `Core Audio error -50` when
    /// the code has no four-character form.
    public static func errorDescription(_ status: OSStatus) -> String {
        guard let characters = fourCharacters(UInt32(bitPattern: status)) else {
            return "Core Audio error \(status)"
        }
        return "Core Audio error \(characters) (\(status))"
    }
}
