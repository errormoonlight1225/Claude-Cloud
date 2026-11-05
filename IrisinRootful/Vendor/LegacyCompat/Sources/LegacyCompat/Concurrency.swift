//
//  Concurrency.swift
//  LegacyCompat
//
//  Swift concurrency (async/await, actors, Task) needs the iOS 13 runtime.
//  The port replaces it with the pre-2021 model:
//
//  * an `async` function becomes a synchronous one that may block, and must
//    not be called on the main thread;
//  * an actor becomes a class whose state is guarded by a `LegacyLock`;
//  * `Task { ... }` becomes `LegacyTask.detached { ... }` (a global queue),
//    and UI updates hop back with `LegacyMain.async { ... }`;
//  * cancellation is a `LegacyCancellation` flag checked where the original
//    checked `Task.isCancelled`.
//

import Dispatch
import Foundation

/// A recursive mutex, so a former actor's methods may call one another.
public final class LegacyLock: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    public init() {}

    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A value guarded by a lock.
public final class LegacyProtected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ value: Value) {
        storage = value
    }

    public var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    @discardableResult
    public func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

/// Raised where the original threw `CancellationError`.
public struct LegacyCancellationError: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "The operation was cancelled." }
}

/// A cancellation flag shared by a piece of background work and its owner.
public final class LegacyCancellation: @unchecked Sendable {
    private let flag = LegacyProtected(false)
    private let handlers = LegacyProtected<[() -> Void]>([])

    public init() {}

    public var isCancelled: Bool { flag.value }

    public func cancel() {
        let first = flag.withValue { cancelled -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        guard first else { return }
        let run = handlers.withValue { list -> [() -> Void] in
            defer { list.removeAll() }
            return list
        }
        run.forEach { $0() }
    }

    /// Runs `handler` on cancellation, or now when already cancelled.
    public func onCancel(_ handler: @escaping () -> Void) {
        let runNow = handlers.withValue { list -> Bool in
            if isCancelled { return true }
            list.append(handler)
            return false
        }
        if runNow { handler() }
    }

    public func checkCancellation() throws {
        if isCancelled { throw LegacyCancellationError() }
    }
}

/// Work started off the main thread, with a handle to cancel it.
public final class LegacyTask: @unchecked Sendable {
    public let cancellation = LegacyCancellation()
    private let group = DispatchGroup()

    /// The cancellation of the task running on this thread, if any: what
    /// `Task.isCancelled` read inside the original task body.
    public static var current: LegacyCancellation? {
        Thread.current.threadDictionary[currentKey] as? LegacyCancellation
    }

    public static var isCancelled: Bool { current?.isCancelled ?? false }

    public static func checkCancellation() throws {
        try current?.checkCancellation()
    }

    private static let currentKey = "LegacyCompat.LegacyTask.current"

    private init() {}

    /// Runs `body` on a global queue at `qos`. The body is `@Sendable`, so
    /// the compiler checks it as code off the main actor: main-actor state
    /// it touches must be reached through `DispatchQueue.main.sync`/`async`.
    @discardableResult
    public static func detached(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ body: @escaping @Sendable () -> Void
    ) -> LegacyTask {
        let task = LegacyTask()
        task.group.enter()
        DispatchQueue.global(qos: qos).async {
            let thread = Thread.current
            let previous = thread.threadDictionary[currentKey]
            thread.threadDictionary[currentKey] = task.cancellation
            defer {
                thread.threadDictionary[currentKey] = previous
                task.group.leave()
            }
            body()
        }
        return task
    }

    public var isCancelled: Bool { cancellation.isCancelled }

    public func cancel() { cancellation.cancel() }

    /// Blocks until the body returns. Never call on the main thread.
    public func wait() { group.wait() }

    /// Runs `handler` on the main queue once the body returns.
    public func notifyOnMain(_ handler: @escaping () -> Void) {
        group.notify(queue: .main, execute: handler)
    }

    /// Blocks the calling (background) thread for `seconds`, returning early
    /// with a throw when this task is cancelled.
    public static func sleep(seconds: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try checkCancellation()
            Thread.sleep(forTimeInterval: min(0.05, max(0, deadline.timeIntervalSinceNow)))
        }
        try checkCancellation()
    }
}

public enum LegacyMain {
    /// Runs `body` on the main queue, asynchronously.
    public static func async(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    /// Runs `body` on the main thread and returns its result: directly when
    /// already there, otherwise by waiting for the main queue.
    public static func sync<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    /// Runs `body` now when on the main thread, otherwise on the main queue.
    public static func run(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

/// Turns a callback API into a blocking call: what `withCheckedContinuation`
/// did for an `async` caller. Never call on the main thread when the
/// callback is delivered there.
public func legacyAwait<T>(_ start: (@escaping (T) -> Void) -> Void) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LegacyProtected<T?>(nil)
    start { value in
        box.value = value
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

/// The throwing form, for `withCheckedThrowingContinuation`.
public func legacyAwait<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    let result: Result<T, Error> = legacyAwait(start)
    return try result.get()
}

/// Runs `body` for every element concurrently and returns the results in
/// order: what a `withTaskGroup` that collected one result per element did.
public func legacyConcurrentMap<Element, Result>(
    _ elements: [Element],
    maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
    _ body: (Element) -> Result
) -> [Result] {
    guard !elements.isEmpty else { return [] }
    let results = LegacyProtected<[Result?]>(Array(repeating: nil, count: elements.count))
    let semaphore = DispatchSemaphore(value: max(1, maxConcurrency))
    withoutActuallyEscaping(body) { body in
        DispatchQueue.concurrentPerform(iterations: elements.count) { index in
            semaphore.wait()
            defer { semaphore.signal() }
            let value = body(elements[index])
            results.withValue { $0[index] = value }
        }
    }
    return results.value.map { $0! }
}
