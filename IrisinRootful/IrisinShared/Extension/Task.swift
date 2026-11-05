//
//  Task.swift
//  Irisin
//

import Foundation
import LegacyCompat

// iOS 12 port: the app's Task helpers, on LegacyTask (Swift concurrency is
// iOS 13). Every sleep here blocks its background thread.

extension LegacyTask {
    /// Sleeps for `seconds` on a clock that counts while the device sleeps:
    /// LegacyTask.sleep waits on the wall clock, which does.
    nonisolated static func sleep(continuousSeconds seconds: Double) throws {
        try sleep(seconds: max(0, seconds))
    }
}

/// A moment on the clock that counts while the device sleeps, as
/// `ContinuousClock` does: `CLOCK_MONOTONIC_RAW` is the clock it reads on
/// Darwin, and it is there on iOS 12 too.
struct ContinuousDeadline: Sendable, Comparable {
    private let nanoseconds: UInt64

    nonisolated static var now: ContinuousDeadline {
        ContinuousDeadline(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }

    static func + (deadline: ContinuousDeadline, seconds: TimeInterval) -> ContinuousDeadline {
        ContinuousDeadline(nanoseconds: deadline.nanoseconds + UInt64(max(0, seconds) * 1_000_000_000))
    }

    static func < (lhs: ContinuousDeadline, rhs: ContinuousDeadline) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Sleeps until the deadline, at once when it has passed.
    nonisolated func sleep() throws {
        let now = ContinuousDeadline.now.nanoseconds
        guard nanoseconds > now else { return }
        try LegacyTask.sleep(continuousSeconds: Double(nanoseconds - now) / 1_000_000_000)
    }
}

extension LegacyTask {
    /// Waits for the task to finish, but no longer than `budget`; the task
    /// runs on either way. A page's first load gets about twelve frames this
    /// way before the page is pushed, so a quick one lands with it and only
    /// a slow one animates in after.
    func wait(upTo budget: TimeInterval) {
        wait(timeout: budget)
    }
}

extension LegacyFuture {
    func wait(upTo budget: TimeInterval) {
        _ = value(timeout: budget)
    }
}
