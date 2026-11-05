import Darwin
import Foundation
import IrisinProtocol
import LegacyCompat
#if canImport(XPC)
    import XPC
#endif

/// The XPC side of the link: every operation as one message with an
/// asynchronous reply, never the synchronous variant, which wedges its queue
/// forever when a reply does not come. (iOS 12 port: the calls block their
/// caller until that reply; callers stay off the main thread.)
///
/// Looking the Mach service up is what starts the daemon; there is nothing to
/// install or launch by hand.
final class DaemonTransport: @unchecked Sendable {
    var onLinkLost: (@Sendable () -> Void)?

    #if targetEnvironment(simulator)
        /// No Mach service to look up: `SimulatorDaemon` is the daemon and the
        /// helper, in this process.
        func hello() throws -> DaemonLink.Backend {
            .daemon(installRoot: SimulatorDaemon.installRoot)
        }

        func run(_ job: InstallerJob) throws -> JobTranscript {
            try SimulatorDaemon.run(job)
        }

        func invalidate() {}
    #elseif canImport(XPC)
        private let queue = DispatchQueue(label: "wiki.qaq.irisin.client", qos: .userInitiated)
        private let stateLock = NSLock()
        private var connection: xpc_connection_t?

        func hello() throws -> DaemonLink.Backend {
            let reply = try send(.hello) { request in
                xpc_dictionary_set_uint64(request, IrisinWire.Key.version, IrisinWire.version)
            }
            guard let root = xpc_dictionary_get_string(reply, IrisinWire.Key.installRoot) else {
                throw IrisinFailure(code: .operationFailed)
            }
            return .daemon(installRoot: String(cString: root))
        }

        func run(_ job: InstallerJob) throws -> JobTranscript {
            let reply = try send(.run) { request in
                try job.encode(into: request)
            }
            let descriptor = xpc_dictionary_dup_fd(reply, IrisinWire.Key.descriptor)
            let identifier = xpc_dictionary_get_uint64(reply, IrisinWire.Key.jobIdentifier)
            guard descriptor >= 0, identifier != 0 else {
                if descriptor >= 0 {
                    close(descriptor)
                }
                throw IrisinFailure(code: .operationFailed)
            }
            return JobTranscript(identifier: identifier, descriptor: descriptor)
        }

        func invalidate() {
            stateLock.lock()
            let existing = connection
            connection = nil
            stateLock.unlock()
            guard let existing else { return }
            xpc_connection_cancel(existing)
        }

        private func send(
            _ operation: IrisinOperation,
            fill: (xpc_object_t) throws -> Void
        ) throws -> xpc_object_t {
            let request = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(request, IrisinWire.Key.version, IrisinWire.version)
            xpc_dictionary_set_uint64(request, IrisinWire.Key.operation, operation.rawValue)
            try fill(request)

            let connection = try activeConnection()
            // iOS 12 port: the caller blocks (off the main thread) until the
            // reply arrives on `queue`, where the continuation used to resume.
            let reply: xpc_object_t = try legacyAwait { (finish: @escaping (Result<xpc_object_t, Error>) -> Void) in
                xpc_connection_send_message_with_reply(connection, request, queue) { reply in
                    if xpc_get_type(reply) == IrisinXPC.typeDictionary {
                        finish(.success(reply))
                    } else {
                        // Interrupted or invalid. The daemon is on-demand and
                        // exits when idle, so this is a normal thing to see; the
                        // next call reconnects.
                        self.invalidate()
                        finish(.failure(IrisinFailure(code: .operationFailed, systemError: ECONNRESET)))
                    }
                }
            }
            if let failure = IrisinFailure.decode(reply) {
                throw failure
            }
            return reply
        }

        private func activeConnection() throws -> xpc_connection_t {
            stateLock.lock()
            defer { stateLock.unlock() }
            if let connection {
                return connection
            }
            guard let created = IrisinWire.serviceName.withCString({
                irisinCreateMachServiceConnection($0, queue, IrisinXPC.Flag.client)
            }) else {
                throw IrisinFailure(code: .operationFailed, systemError: ENOENT)
            }
            xpc_connection_set_event_handler(created) { [weak self] message in
                guard let self else { return }
                if message === IrisinXPC.errorConnectionInterrupted
                    || message === IrisinXPC.errorConnectionInvalid
                {
                    onLinkLost?()
                }
            }
            xpc_connection_activate(created)
            connection = created
            return created
        }

        deinit {
            if let connection {
                xpc_connection_cancel(connection)
            }
        }
    #else
        func hello() throws -> DaemonLink.Backend {
            throw IrisinFailure(code: .notPermitted)
        }

        func run(_: InstallerJob) throws -> JobTranscript {
            throw IrisinFailure(code: .notPermitted)
        }

        func invalidate() {}
    #endif
}
