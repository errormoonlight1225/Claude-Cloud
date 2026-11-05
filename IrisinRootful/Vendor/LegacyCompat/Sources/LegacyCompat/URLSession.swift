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
