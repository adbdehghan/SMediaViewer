//
//  Extensions.swift
//  SMediaViewer
//
//  Created by Adib.
//

import CommonCrypto  // For SHA256
import Foundation

// Helper for SHA256 filename generation
extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }

    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}

// Helper for HLSAssetManager and VideoCacheManager to get original URL if custom scheme was used
extension URL {
    func hlsOriginalURLFromCustomScheme(customScheme: String) -> URL? {
        if self.scheme == customScheme {
            let originalURLString = self.absoluteString.replacingOccurrences(of: "\(customScheme):", with: "", options: .anchored)
            return URL(string: originalURLString)
        }
        // This might be an already original URL if the scheme wasn't the custom one
        return self
    }
}
