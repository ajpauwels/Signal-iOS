//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// Experimental BGProcessingTasks that measure how often iOS is willing to
/// launch a processing task that is always eligible to run.
///
/// They do no real work. The shared launch handler in `BGProcessingTaskRunner`
/// writes the start and end lines to the `ExecutionLogger`, and every run
/// reschedules itself with no delay so the OS can run it as often as it likes.
///
/// The two variants differ only in whether they tell iOS they need external
/// power, so the gap between their run frequencies isolates that flag.
class TestSchedulingLimitsOnBatteryRunner: BGProcessingTaskRunner {
    static let taskIdentifier = "TestSchedulingLimitsOnBattery"
    static let logPrefix: String? = nil
    static let requiresNetworkConnectivity = true
    static let requiresExternalPower = false

    func startCondition() -> BGProcessingTaskStartCondition {
        return .asSoonAsPossible
    }

    func run() async throws {
        Logger.info("Ran.")
    }
}

class TestSchedulingLimitsOnExternalPowerRunner: BGProcessingTaskRunner {
    static let taskIdentifier = "TestSchedulingLimitsOnExternalPower"
    static let logPrefix: String? = nil
    static let requiresNetworkConnectivity = true
    static let requiresExternalPower = true

    func startCondition() -> BGProcessingTaskStartCondition {
        return .asSoonAsPossible
    }

    func run() async throws {
        Logger.info("Ran.")
    }
}
