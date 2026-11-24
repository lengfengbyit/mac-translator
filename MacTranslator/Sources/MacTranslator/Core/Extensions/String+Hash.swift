import Foundation
import CryptoKit

extension String {
    /// Lowercase hex SHA-256, used for cache keys and de-duplication.
    var sha256Hex: String {
        let digest = SHA256.hash(data: Data(utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    /// Lowercase hex SHA-256, used for image cache keys.
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
