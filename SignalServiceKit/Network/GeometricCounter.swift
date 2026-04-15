//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public class GeometricCounter {

    public static let shared = GeometricCounter()

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
