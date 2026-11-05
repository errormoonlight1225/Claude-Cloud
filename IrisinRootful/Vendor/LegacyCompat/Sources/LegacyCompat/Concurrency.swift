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
        @_implicitSelfCapture _ body: @escaping @Sendable () -> Void
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

    /// Blocks until the body returns or `seconds` pass; true when it returned.
    @discardableResult
    public func wait(timeout seconds: TimeInterval) -> Bool {
        group.wait(timeout: .now() + seconds) == .success
    }

    /// Whether the body has returned, without waiting.
    public var isFinished: Bool { group.wait(timeout: .now()) == .success }

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
    /// The body's own cancellation, following the starting task's.
    public let cancellation: LegacyCancellation

    public init(qos: DispatchQoS.QoSClass = .userInitiated, @_implicitSelfCapture _ body: @escaping @Sendable () -> Value) {
        let cancellation = (LegacyTask.current ?? LegacyCancellation()).child()
        self.cancellation = cancellation
        group.enter()
        DispatchQueue.global(qos: qos).async {
            let value = LegacyTask.withCurrent(cancellation, body)
            self.result = value
            self.group.leave()
        }
    }

    /// `Task<Value, Never>` started detached: what `Task.detached { }` with
    /// a value was.
    public static func detached(qos: DispatchQoS.QoSClass = .userInitiated, _ body: @escaping @Sendable () -> Value) -> LegacyFuture {
        LegacyTask.withCurrent(nil) { LegacyFuture(qos: qos, body) }
    }

    public func cancel() { cancellation.cancel() }
    public var isCancelled: Bool { cancellation.isCancelled }

    /// The value, or nil when `seconds` pass first.
    public func value(timeout seconds: TimeInterval) -> Value? {
        group.wait(timeout: .now() + seconds) == .success ? result : nil
    }

    /// Runs `handler` on the main queue with the value once it is there.
    public func notifyOnMain(_ handler: @escaping (Value) -> Void) {
        group.notify(queue: .main) { handler(self.result!) }
    }

    /// Blocks until the body has returned. Never call on the main thread.
    public var value: Value {
        group.wait()
        return result!
    }
}

/// Work on the main queue after a delay, or once a condition holds,
/// cancellable: what a main-actor Task that slept between checks was.
public final class LegacyMainDelay {
    private var item: DispatchWorkItem?
    public private(set) var isCancelled = false

    private init() {}

    /// Runs `body` on the main queue after `seconds`.
    @discardableResult
    public static func after(_ seconds: TimeInterval, _ body: @escaping () -> Void) -> LegacyMainDelay {
        let delay = LegacyMainDelay()
        delay.schedule(after: seconds, body)
        return delay
    }

    /// Waits `initialDelay`, then checks `condition` every `interval` on the
    /// main queue, and runs `body` once it holds.
    @discardableResult
    public static func poll(
        initialDelay: TimeInterval = 0,
        every interval: TimeInterval,
        until condition: @escaping () -> Bool,
        then body: @escaping () -> Void
    ) -> LegacyMainDelay {
        let delay = LegacyMainDelay()
        func check() {
            guard !delay.isCancelled else { return }
            if condition() {
                body()
            } else {
                delay.schedule(after: interval, check)
            }
        }
        delay.schedule(after: initialDelay, check)
        return delay
    }

    private func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            body()
        }
        self.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
    }

    public func cancel() {
        isCancelled = true
        item?.cancel()
    }
}

/// `AsyncThrowingStream` for blocking code: a producer yields from any
/// thread, one consumer reads with `next()`, which blocks until an element,
/// the end or an error arrives. Buffered without bound. The consumer going
/// away (`cancel()`, or the stream being released) runs `onTermination`, as
/// dropping an async stream's iterator did.
public final class LegacyThrowingStream<Element>: @unchecked Sendable {
    public final class Continuation: @unchecked Sendable {
        fileprivate weak var stream: LegacyThrowingStream?
        private let lock = NSLock()
        private var handler: (() -> Void)?

        public var onTermination: (() -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return handler }
            set {
                lock.lock()
                handler = newValue
                let alreadyOver = stream?.isTerminated ?? true
                lock.unlock()
                if alreadyOver { fireTermination() }
            }
        }

        public func yield(_ element: Element) {
            stream?.push(.element(element))
        }

        public func finish(throwing error: Error? = nil) {
            stream?.push(error.map { .failure($0) } ?? .end)
        }

        fileprivate func fireTermination() {
            lock.lock()
            let run = handler
            handler = nil
            lock.unlock()
            run?()
        }
    }

    private enum Item {
        case element(Element)
        case failure(Error)
        case end
    }

    private let condition = NSCondition()
    private var buffer: [Item] = []
    private var head = 0
    private var over = false
    private var terminated = false
    private let continuation = Continuation()

    fileprivate var isTerminated: Bool {
        condition.lock()
        defer { condition.unlock() }
        return terminated
    }

    public init(_ build: (Continuation) -> Void) {
        continuation.stream = self
        build(continuation)
    }

    private func push(_ item: Item) {
        condition.lock()
        guard !over else {
            condition.unlock()
            return
        }
        buffer.append(item)
        if case .element = item {} else { over = true }
        condition.broadcast()
        condition.unlock()
        if case .element = item {} else { terminate() }
    }

    private func terminate() {
        condition.lock()
        let first = !terminated
        terminated = true
        condition.unlock()
        if first { continuation.fireTermination() }
    }

    /// The next element; nil at the end. Throws what the producer finished
    /// with. Blocks; never call on the main thread.
    public func next() throws -> Element? {
        condition.lock()
        while head >= buffer.count {
            if terminated, over || buffer.isEmpty { break }
            condition.wait()
        }
        guard head < buffer.count else {
            condition.unlock()
            return nil
        }
        let item = buffer[head]
        head += 1
        condition.unlock()
        switch item {
        case let .element(element): return element
        case let .failure(error): throw error
        case .end: return nil
        }
    }

    /// The consumer is done: the producer's `onTermination` runs.
    public func cancel() {
        condition.lock()
        over = true
        condition.broadcast()
        condition.unlock()
        terminate()
    }

    deinit {
        if !terminated { continuation.fireTermination() }
    }
}

// MARK: - Main-thread tasks

/// `Task { }` started from the main actor: the body runs on the main thread,
/// and each former `await` of work off the main actor is `awaitBackground`,
/// which runs that work on a global queue while the main run loop keeps
/// turning. The interface stays responsive and other main-thread work runs
/// in the meantime, as it did at an `await`.
///
/// The body is scheduled with CFRunLoopPerformBlock, not the main dispatch
/// queue: a run loop turned from inside a main-queue block does not drain
/// the main queue, and work off the main thread that waits for it
/// (`DispatchQueue.main.sync`) would never finish.
public final class LegacyMainTask: @unchecked Sendable {
    public let cancellation = LegacyCancellation()
    private var finished = false
    private var completions: [() -> Void] = []

    @discardableResult
    public init(@_implicitSelfCapture _ body: @escaping () -> Void) {
        let cancellation = cancellation
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [self] in
            LegacyTask.withCurrent(cancellation, body)
            finished = true
            let run = completions
            completions.removeAll()
            run.forEach { $0() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    public var isCancelled: Bool { cancellation.isCancelled }
    public func cancel() { cancellation.cancel() }

    /// Waits for the body on the main thread, turning the run loop.
    public func wait() {
        if Thread.isMainThread {
            while !finished { LegacyRunLoop.turn() }
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { self.whenFinished { semaphore.signal() } }
            semaphore.wait()
        }
    }

    /// Runs `handler` on the main thread once the body has returned.
    public func whenFinished(_ handler: @escaping () -> Void) {
        if finished { handler() } else { completions.append(handler) }
    }
}

public enum LegacyRunLoop {
    /// One short turn of the main run loop in its default mode.
    public static func turn() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

/// A former `await` in main-thread code: `body` runs on a global queue,
/// under the current task's cancellation, while the main run loop turns
/// until it returns. Off the main thread the body simply runs. `body` is
/// @Sendable, so the compiler reports main-thread state it touches: such a
/// call belongs outside `awaitBackground`.
public func awaitBackground<T>(@_implicitSelfCapture _ body: @escaping @Sendable () -> T) -> T {
    guard Thread.isMainThread else { return body() }
    let box = LegacyProtected<T?>(nil)
    let done = LegacyProtected(false)
    let cancellation = LegacyTask.current
    DispatchQueue.global(qos: .userInitiated).async {
        let value = LegacyTask.withCurrent(cancellation, body)
        box.value = value
        done.value = true
        DispatchQueue.main.async {}
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    while !done.value { LegacyRunLoop.turn() }
    return box.value!
}

/// The throwing form.
public func awaitBackground<T>(@_implicitSelfCapture _ body: @escaping @Sendable () throws -> T) throws -> T {
    let result: Result<T, Error> = awaitBackground { Result { try body() } }
    return try result.get()
}

/// `CheckedContinuation` for main-thread waits: resumed once, from anywhere.
public final class LegacyContinuation<T>: @unchecked Sendable {
    fileprivate let result = LegacyProtected<Result<T, Error>?>(nil)

    public func resume(returning value: T) { set(.success(value)) }
    public func resume(throwing error: Error) { set(.failure(error)) }
    public func resume(with result: Result<T, Error>) { set(result) }

    private func set(_ value: Result<T, Error>) {
        result.withValue { if $0 == nil { $0 = value } }
        DispatchQueue.main.async {}
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

extension LegacyContinuation where T == Void {
    public func resume() { resume(returning: ()) }
}

/// A former `await withCheckedContinuation` on the main thread: `start`
/// runs now, and the main run loop turns until it resumes the continuation
/// (an alert's button, a dismissal's completion). Off the main thread the
/// caller blocks instead.
public func legacyWaitOnMain<T>(_ start: (LegacyContinuation<T>) -> Void) -> T {
    let continuation = LegacyContinuation<T>()
    start(continuation)
    if Thread.isMainThread {
        while continuation.result.value == nil { LegacyRunLoop.turn() }
    } else {
        while continuation.result.value == nil { Thread.sleep(forTimeInterval: 0.01) }
    }
    // only the throwing form is ever resumed with an error
    return try! continuation.result.value!.get()
}

/// `await withCheckedThrowingContinuation` on the main thread.
public func legacyWaitOnMainThrowing<T>(_ start: (LegacyContinuation<T>) -> Void) throws -> T {
    let continuation = LegacyContinuation<T>()
    start(continuation)
    if Thread.isMainThread {
        while continuation.result.value == nil { LegacyRunLoop.turn() }
    } else {
        while continuation.result.value == nil { Thread.sleep(forTimeInterval: 0.01) }
    }
    return try continuation.result.value!.get()
}
