//
//  Throttler.swift
//  AptRepository
//

import OpenCombine
import OpenCombineDispatch
import Foundation

/// Coalesces bursts of work on the main actor. The first job runs straight
/// away; while calls keep arriving inside `minimumDelay` only the most recent
/// one survives to run at the end of the window.
public final class Throttler {
    private let subject = PassthroughSubject<() -> Void, Never>()
    private var cancellable: AnyCancellable?

    public init(minimumDelay: TimeInterval) {
        cancellable = subject
            .throttle(for: .seconds(minimumDelay), scheduler: DispatchQueue.main.ocombine, latest: true)
            .sink { job in job() }
    }

    public func throttle(_ job: @escaping () -> Void) {
        subject.send(job)
    }
}
