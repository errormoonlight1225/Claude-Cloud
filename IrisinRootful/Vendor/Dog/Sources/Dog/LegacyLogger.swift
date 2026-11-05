//
//  LegacyLogger.swift
//  Dog
//
//  iOS 12 port: `os.Logger` and `OSLogMessage` arrived in iOS 14. This keeps
//  the call sites' spelling, `logger.info("\(value, privacy: .public)")`, and
//  sends the finished text to `os_log`, which iOS 12 has.
//

import Foundation
import os.log

public struct LegacyLogMessage: ExpressibleByStringInterpolation {
    public enum Privacy {
        case `public`
        case `private`
        case auto
        case sensitive
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount _: Int) {
            text.reserveCapacity(literalCapacity * 2)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy _: Privacy = .auto) {
            text += String(describing: value)
        }
    }

    public let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }
}

/// The subset of `os.Logger` this codebase uses, on `os_log`.
public struct LegacyLogger: @unchecked Sendable {
    private let log: OSLog

    public init(subsystem: String, category: String) {
        log = OSLog(subsystem: subsystem, category: category)
    }

    private func write(_ type: OSLogType, _ message: LegacyLogMessage) {
        os_log("%{public}@", log: log, type: type, message.text)
    }

    public func log(_ message: LegacyLogMessage) { write(.default, message) }
    public func trace(_ message: LegacyLogMessage) { write(.debug, message) }
    public func debug(_ message: LegacyLogMessage) { write(.debug, message) }
    public func info(_ message: LegacyLogMessage) { write(.info, message) }
    public func notice(_ message: LegacyLogMessage) { write(.default, message) }
    public func warning(_ message: LegacyLogMessage) { write(.error, message) }
    public func error(_ message: LegacyLogMessage) { write(.error, message) }
    public func critical(_ message: LegacyLogMessage) { write(.fault, message) }
    public func fault(_ message: LegacyLogMessage) { write(.fault, message) }
}

extension FileHandle {
    /// `write(contentsOf:)` for iOS 12: write(2) on the descriptor, throwing
    /// instead of raising an Objective-C exception.
    func legacyWrite(_ data: Data) throws {
        let descriptor = fileDescriptor
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if written == 0 { throw POSIXError(.EIO) }
                cursor += written
                remaining -= written
            }
        }
    }
}
