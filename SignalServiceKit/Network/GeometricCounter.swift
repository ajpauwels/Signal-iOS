//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public class GeometricCounter {

    public static let shared = GeometricCounter()

    /// When `true`, `asyncRequest` decrements the geometric counter and may
    /// attach the payload header. Defaults to `false` (fail-closed).
    ///
    /// Set to `true` at business-level entry points (client-triggered flows:
    /// user actions or app schedules) so that all requests within that scope
    /// are counted automatically. Set back to `false` by retry mechanisms
    /// (e.g. `Retry.performRepeatedly` on non-first attempts) and by
    /// server-triggered recovery paths (409/410/428 handlers) so that only
    /// the original request is counted.
    ///
    /// Usage:
    /// ```swift
    /// await GeometricCounter.$isCountable.withValue(true) {
    ///     // All asyncRequest() calls within this scope are countable
    /// }
    /// ```
    @TaskLocal public static var isCountable: Bool = false

    static let geometricP: Double = 0.1

    private var counter: Int
    private let lock = NSLock()

    private static func sampleGeometric() -> Int {
        return Int(floor(log(Double.random(in: 0..<1)) / log(1 - geometricP)))
    }

    private init() {
        counter = Self.sampleGeometric()
    }

    public func checkAndDecrement() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if counter == 0 {
            counter = Self.sampleGeometric()
            return true
        }
        counter -= 1
        return false
    }
}
