import os.log

/// Shared by the listener's queue and the main thread.
let log = Logger(subsystem: "wiki.qaq.irisind", category: "daemon")

// iOS 12 port: `os.Logger` and `OSLogMessage` arrived in iOS 14. This module's
// own `Logger` keeps the call sites' spelling and hands the finished text to
// `os_log`, which iOS 12 has. Defined here rather than taken from a library:
// nothing but IrisinProtocol links into irisind.

struct LogMessage: ExpressibleByStringInterpolation {
    enum Privacy {
        case `public`
        case `private`
        case auto
        case sensitive
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount _: Int) {
            text.reserveCapacity(literalCapacity * 2)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation<T>(_ value: T, privacy _: Privacy = .auto) {
            text += String(describing: value)
        }
    }

    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }
}

struct Logger: @unchecked Sendable {
    private let handle: OSLog

    init(subsystem: String, category: String) {
        handle = OSLog(subsystem: subsystem, category: category)
    }

    private func write(_ type: OSLogType, _ message: LogMessage) {
        os_log("%{public}@", log: handle, type: type, message.text)
    }

    func debug(_ message: LogMessage) { write(.debug, message) }
    func info(_ message: LogMessage) { write(.info, message) }
    func notice(_ message: LogMessage) { write(.default, message) }
    func warning(_ message: LogMessage) { write(.error, message) }
    func error(_ message: LogMessage) { write(.error, message) }
    func fault(_ message: LogMessage) { write(.fault, message) }
    func critical(_ message: LogMessage) { write(.fault, message) }
}
