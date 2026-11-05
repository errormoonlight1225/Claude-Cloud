//
//  Digests.swift
//  LegacyCrypto
//
//  The slice of CryptoKit the port uses (SHA256 and Insecure.MD5), on
//  CommonCrypto: CryptoKit is iOS 13. Same spelling, so a file swaps
//  `import CryptoKit` for `import LegacyCrypto` and nothing else.
//

import CommonCrypto
import Foundation

/// CryptoKit's `Digest`: a sequence of bytes.
public protocol Digest: Sequence, Hashable, ContiguousBytes where Element == UInt8 {}

/// A finished digest: its bytes, as CryptoKit's digests are a sequence of
/// UInt8.
public struct LegacyDigest: Digest, CustomStringConvertible {
    public let bytes: [UInt8]

    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    public var hexString: String { bytes.map { String(format: "%02x", $0) }.joined() }

    public var description: String { "digest: \(hexString)" }

    public static var byteCount: Int { 0 }
}

public struct SHA256 {
    public typealias Digest = LegacyDigest
    private var context = CC_SHA256_CTX()

    public static var byteCount: Int { Int(CC_SHA256_DIGEST_LENGTH) }

    public init() {
        CC_SHA256_Init(&context)
    }

    public mutating func update(data: some DataProtocol) {
        for region in data.regions {
            region.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                var offset = 0
                while offset < buffer.count {
                    let chunk = min(buffer.count - offset, Int(UInt32.max))
                    CC_SHA256_Update(&context, base + offset, CC_LONG(chunk))
                    offset += chunk
                }
            }
        }
    }

    public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        guard let base = bufferPointer.baseAddress, bufferPointer.count > 0 else { return }
        CC_SHA256_Update(&context, base, CC_LONG(bufferPointer.count))
    }

    public func finalize() -> LegacyDigest {
        var copy = context
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&out, &copy)
        return LegacyDigest(bytes: out)
    }

    public static func hash(data: some DataProtocol) -> LegacyDigest {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }
}

public enum Insecure {
    public struct MD5 {
        public typealias Digest = LegacyDigest
        private var context = CC_MD5_CTX()

        public init() {
            CC_MD5_Init(&context)
        }

        public mutating func update(data: some DataProtocol) {
            for region in data.regions {
                region.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                    CC_MD5_Update(&context, base, CC_LONG(buffer.count))
                }
            }
        }

        public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
            guard let base = bufferPointer.baseAddress, bufferPointer.count > 0 else { return }
            CC_MD5_Update(&context, base, CC_LONG(bufferPointer.count))
        }

        public func finalize() -> LegacyDigest {
            var copy = context
            var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            CC_MD5_Final(&out, &copy)
            return LegacyDigest(bytes: out)
        }

        public static func hash(data: some DataProtocol) -> LegacyDigest {
            var hasher = MD5()
            hasher.update(data: data)
            return hasher.finalize()
        }
    }
}
