//
//  URLSession.swift
//  LegacyCompat
//
//  `data(for:)`, `data(from:)` and `download(for:)` are iOS 15 async calls.
//  These block the calling (background) thread on the completion-handler
//  API instead, and cancel the task when the current LegacyTask is.
//

import Foundation

extension URLSession {
    private func blocking<T>(
        _ make: (@escaping (T?, URLResponse?, Error?) -> Void) -> URLSessionTask
    ) throws -> (T, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LegacyProtected<(T?, URLResponse?, Error?)>((nil, nil, nil))
        let task = make { value, response, error in
            box.value = (value, response, error)
            semaphore.signal()
        }
        let cancellation = LegacyTask.current
        cancellation?.onCancel { task.cancel() }
        task.resume()
        semaphore.wait()
        let (value, response, error) = box.value
        if let error {
            if cancellation?.isCancelled == true { throw LegacyCancellationError() }
            throw error
        }
        guard let value, let response else { throw URLError(.badServerResponse) }
        return (value, response)
    }

    /// `data(for:)`. Never call on the main thread.
    public func compatData(for request: URLRequest) throws -> (Data, URLResponse) {
        try blocking { dataTask(with: request, completionHandler: $0) }
    }

    /// `data(from:)`. Never call on the main thread.
    public func compatData(from url: URL) throws -> (Data, URLResponse) {
        try blocking { dataTask(with: url, completionHandler: $0) }
    }

    /// `download(for:)`: the file is moved out of the temporary location
    /// before the completion handler returns, as the system deletes it then.
    public func compatDownload(for request: URLRequest) throws -> (URL, URLResponse) {
        try blocking { (finish: @escaping (URL?, URLResponse?, Error?) -> Void) in
            downloadTask(with: request) { location, response, error in
                var kept: URL?
                if let location {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("LegacyCompat-\(UUID().uuidString)")
                    if (try? FileManager.default.moveItem(at: location, to: destination)) != nil {
                        kept = destination
                    }
                }
                finish(kept, response, error ?? (location != nil && kept == nil ? URLError(.cannotMoveFile) : nil))
            }
        }
    }
}

/// What `URLSession.bytes(for:)` (iOS 15) was used for: a body read as it
/// arrives, so a caller hears of a slow server that is still sending. The
/// response comes back first; a status `accept` refuses ends the request
/// without its body.
public final class LegacyStreamingFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Result {
        public let response: URLResponse
        /// nil when `accept` refused the response's status
        public let data: Data?
    }

    private let accept: (Int) -> Bool
    private let activity: () -> Void
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: URLResponse?
    private var body = Data()
    private var refused = false
    private var failure: Error?
    private var lastReport = Date.distantPast

    private init(accept: @escaping (Int) -> Bool, activity: @escaping () -> Void) {
        self.accept = accept
        self.activity = activity
    }

    /// Blocks until the request ends. Never call on the main thread.
    /// `activity` is called on a background queue when the response
    /// arrives and then at most once a second while bytes do.
    public static func fetch(
        _ request: URLRequest,
        accept: @escaping (Int) -> Bool = { $0 == 200 },
        activity: @escaping () -> Void
    ) throws -> Result {
        let fetch = LegacyStreamingFetch(accept: accept, activity: activity)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: fetch, delegateQueue: queue)
        let task = session.dataTask(with: request)
        let cancellation = LegacyTask.current
        cancellation?.onCancel { task.cancel() }
        task.resume()
        fetch.semaphore.wait()
        session.finishTasksAndInvalidate()
        fetch.lock.lock()
        defer { fetch.lock.unlock() }
        if let response = fetch.response, fetch.refused {
            return Result(response: response, data: nil)
        }
        if let failure = fetch.failure {
            if cancellation?.isCancelled == true { throw LegacyCancellationError() }
            throw failure
        }
        guard let response = fetch.response else { throw URLError(.badServerResponse) }
        return Result(response: response, data: fetch.body)
    }

    public func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        self.response = response
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(min(response.expectedContentLength, 64 << 20)))
        }
        let refuse = !accept(status)
        refused = refuse
        lastReport = Date()
        lock.unlock()
        activity()
        completionHandler(refuse ? .cancel : .allow)
    }

    public func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        body.append(data)
        let now = Date()
        let report = now.timeIntervalSince(lastReport) >= 1
        if report { lastReport = now }
        lock.unlock()
        if report { activity() }
    }

    public func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if !refused { failure = error }
        lock.unlock()
        semaphore.signal()
    }
}
