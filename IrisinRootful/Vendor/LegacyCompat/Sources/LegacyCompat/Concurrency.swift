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

    /// Runs `body` with `cancellation` as this thread's current one: how
    /// work fanned out to other threads stays cancellable with its task.
    public static func withCurrent<T>(_ cancellation: LegacyCancellation?, _ body: () throws -> T) rethrows -> T {
        let thread = Thread.current
        let previous = thread.threadDictionary[currentKey]
        thread.threadDictionary[currentKey] = cancellation
        defer { thread.threadDictionary[currentKey] = previous }
        return try body()
    }

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
    let parent = LegacyTask.current
    withoutActuallyEscaping(body) { body in
        DispatchQueue.concurrentPerform(iterations: elements.count) { index in
            semaphore.wait()
            defer { semaphore.signal() }
            let value = LegacyTask.withCurrent(parent) { body(elements[index]) }
            results.withValue { $0[index] = value }
        }
    }
    return results.value.map { $0! }
}

extension LegacyCancellation {
    /// A cancellation that follows this one and can also be cancelled on
    /// its own: what a task group's child tasks had.
    public func child() -> LegacyCancellation {
        let child = LegacyCancellation()
        onCancel { child.cancel() }
        return child
    }
}

/// A value sent once and waited for: what an AsyncStream that yields once
/// was used for.
public final class LegacySignal<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?
    private var closed = false

    public init() {}

    /// The first value sent wins; later ones are dropped.
    public func send(_ newValue: Value) {
        condition.lock()
        if value == nil, !closed {
            value = newValue
        }
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Ends the signal without a value.
    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The value, nil when closed without one or when `deadline` passes.
    public func wait(until deadline: Date = .distantFuture) -> Value? {
        condition.lock()
        defer { condition.unlock() }
        while !closed {
            if !condition.wait(until: deadline) { break }
        }
        return value
    }
}

/// Runs every job at once and returns the first non-nil answer to arrive,
/// cancelling the rest: a task group read until its first result.
public func legacyFirstResult<T>(
    qos: DispatchQoS.QoSClass = .utility,
    _ jobs: [@Sendable () -> T?]
) -> T? {
    guard !jobs.isEmpty else { return nil }
    let cancellation = (LegacyTask.current ?? LegacyCancellation()).child()
    let condition = NSCondition()
    var result: T?
    var remaining = jobs.count
    for job in jobs {
        DispatchQueue.global(qos: qos).async {
            let value = LegacyTask.withCurrent(cancellation) { cancellation.isCancelled ? nil : job() }
            condition.lock()
            remaining -= 1
            if result == nil, let value { result = value }
            condition.broadcast()
            condition.unlock()
        }
    }
    condition.lock()
    while result == nil, remaining > 0 {
        condition.wait()
    }
    let answer = result
    condition.unlock()
    cancellation.cancel()
    return answer
}

/// Runs every job at once and returns the answer of the earliest job that
/// has one, as soon as every job before it has answered nil: which answer
/// wins depends on the order, never on which job was quicker.
public func legacyFirstInOrder<T>(
    qos: DispatchQoS.QoSClass = .utility,
    _ jobs: [@Sendable () -> T?]
) -> T? {
    guard !jobs.isEmpty else { return nil }
    let cancellation = (LegacyTask.current ?? LegacyCancellation()).child()
    let condition = NSCondition()
    var answers = [Int: T?]()
    for (position, job) in jobs.enumerated() {
        DispatchQueue.global(qos: qos).async {
            let value = LegacyTask.withCurrent(cancellation) { cancellation.isCancelled ? nil : job() }
            condition.lock()
            answers[position] = value
            condition.broadcast()
            condition.unlock()
        }
    }
    condition.lock()
    defer {
        condition.unlock()
        cancellation.cancel()
    }
    while true {
        for position in jobs.indices {
            guard let answer = answers[position] else { break }
            if let answer { return answer }
            if position == jobs.count - 1 { return nil }
        }
        condition.wait()
    }
}

/// `async let`: the body starts now on a global queue and `value` waits for
/// it. It runs under the starting task's cancellation.
public final class LegacyFuture<Value>: @unchecked Sendable {
    private let group = DispatchGroup()
    private var result: Value?

    public init(qos: DispatchQoS.QoSClass = .userInitiated, _ body: @escaping @Sendable () -> Value) {
        let parent = LegacyTask.current
        group.enter()
        DispatchQueue.global(qos: qos).async {
            let value = LegacyTask.withCurrent(parent, body)
            self.result = value
            self.group.leave()
        }
    }

    /// Blocks until the body has returned. Never call on the main thread.
    public var value: Value {
        group.wait()
        return result!
    }
}
