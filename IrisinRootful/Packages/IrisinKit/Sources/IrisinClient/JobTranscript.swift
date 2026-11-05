import Darwin
import Foundation
import IrisinProtocol

/// The helper's output, read from the descriptor the daemon handed back.
///
/// The descriptor is the read end of a pipe the helper writes into. It
/// belongs to this process: bytes flow from the helper through the kernel to
/// here, and the daemon that made the introduction keeps nothing. A
/// self-update that restarts the daemon does not interrupt this stream.
public final class JobTranscript: @unchecked Sendable {
    public let identifier: UInt64
    /// Every event the helper wrote, in order, ending with `.exit` when the
    /// helper got that far. Finishes at EOF. Buffered without bound, so a
    /// consumer that attaches late or reads slowly misses nothing.
    ///
    /// iOS 12 port: a single-pass sequence whose iterator blocks until the
    /// next event arrives (it was an AsyncStream). Read it off the main thread.
    public let events: Events

    init(identifier: UInt64, descriptor: Int32) {
        self.identifier = identifier
        let buffer = EventBuffer()
        events = Events(buffer: buffer)
        // A plain thread: `read(2)` blocks.
        let reader = Thread {
            LineReader.read(descriptor: descriptor) { buffer.append(InstallerOutput.decode($0)) }
            buffer.finish()
            close(descriptor)
        }
        reader.name = "wiki.qaq.irisin.job.\(identifier)"
        reader.start()
    }

    /// Reads to the end, handing every event but the last to `onEvent`, and
    /// returns the status the helper announced. Nil means the stream ended
    /// without one: the helper died, which is a failure the caller reports
    /// as such. Blocks; never call on the main thread.
    public func collect(onEvent: @escaping @Sendable (InstallerEvent) -> Void) -> Int32? {
        var status: Int32?
        for event in events {
            if case let .exit(announced) = event {
                status = announced
            } else {
                onEvent(event)
            }
        }
        return status
    }

    public struct Events: Sequence {
        let buffer: EventBuffer

        public func makeIterator() -> Iterator {
            Iterator(buffer: buffer)
        }

        public struct Iterator: IteratorProtocol {
            let buffer: EventBuffer

            public mutating func next() -> InstallerEvent? {
                buffer.next()
            }
        }
    }

    /// Events from the reader thread to one consumer, in order.
    final class EventBuffer: @unchecked Sendable {
        private let condition = NSCondition()
        private var pending: [InstallerEvent] = []
        private var head = 0
        private var finished = false

        func append(_ event: InstallerEvent) {
            condition.lock()
            pending.append(event)
            condition.signal()
            condition.unlock()
        }

        func finish() {
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func next() -> InstallerEvent? {
            condition.lock()
            defer { condition.unlock() }
            while head >= pending.count, !finished {
                condition.wait()
            }
            guard head < pending.count else { return nil }
            let event = pending[head]
            head += 1
            if head > 1024, head * 2 > pending.count {
                pending.removeFirst(head)
                head = 0
            }
            return event
        }
    }
}
