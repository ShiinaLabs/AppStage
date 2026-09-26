import Foundation
import Security

public enum StageControlToken {
    /// Returns 32 cryptographically random bytes encoded as hexadecimal.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StageControlError.transport("Secure random source unavailable")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
