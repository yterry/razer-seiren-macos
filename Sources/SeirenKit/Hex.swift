import Foundation

/// Loose hex parsing so captured command bytes can be pasted in any common
/// shape: `"02 80 07"`, `"0x02,0x80"`, run-together `"028007"`, with newlines.
public enum Hex {
    public static func parse(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let tokens = s
            .replacingOccurrences(of: "0x", with: " ")
            .replacingOccurrences(of: "0X", with: " ")
            .split(whereSeparator: { !$0.isHexDigit })

        for token in tokens {
            if token.count <= 2 {
                if let b = UInt8(token, radix: 16) { out.append(b) }
            } else {
                // run-together hex like "028007" -> [02, 80, 07]
                var chars = Array(token)
                if chars.count % 2 == 1 { chars.insert("0", at: 0) }
                var i = 0
                while i + 1 < chars.count {
                    if let b = UInt8(String(chars[i...i + 1]), radix: 16) { out.append(b) }
                    i += 2
                }
            }
        }
        return out
    }
}
