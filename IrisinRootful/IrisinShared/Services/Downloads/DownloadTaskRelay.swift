//
//  DownloadTaskRelay.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation
import LegacyCompat

/// One data task's delegate callbacks as a stream: the response, then
/// every chunk of the body as it arrives.
///
/// iOS 12 port: a `LegacyThrowingStream` where it was an AsyncThrowingStream,
/// and a session of its own per task (a task's own delegate is iOS 15), made
/// from the shared session's configuration. The session keeps this relay
/// until the task ends; the consumer going away cancels the task.
final class DownloadTaskRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Chunk: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    private let continuation: LegacyThrowingStream<Chunk>.Continuation
    private var task: URLSessionDataTask?

    static func stream(for request: URLRequest, in session: URLSession) -> LegacyThrowingStream<Chunk> {
        LegacyThrowingStream { continuation in
            _ = DownloadTaskRelay(request: request, configuration: session.configuration, continuation: continuation)
        }
    }

    private init(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        continuation: LegacyThrowingStream<Chunk>.Continuation
    ) {
        self.continuation = continuation
        super.init()

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.task = task
        continuation.onTermination = { [weak task] in task?.cancel() }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: DownloadError.malformedResponse)
            completionHandler(.cancel)
            return
        }
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }
}
