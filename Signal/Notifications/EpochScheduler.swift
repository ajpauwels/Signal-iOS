//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// Main-app side of the epoch participation experiment; see
/// `EpochParticipation` for the overall idea.
///
/// Every execution opportunity in the main app should call
/// `handleOpportunity`. It records a send for the current epoch if needed,
/// then schedules the `MessageFetchBGRefreshTask` for the start of the next
/// epoch, plus the `EpochSendBGProcessingTaskRunner` when that epoch is at
/// night. Each decides for itself, so both are always asked. The log records
/// which entry point actually covered each epoch.
enum EpochScheduler {

    static func handleOpportunity(
        executionId: UUID,
        entryPoint: String,
        target: String,
        appReadiness: AppReadiness,
    ) {
        EpochParticipation.sendIfNeeded(executionId: executionId, entryPoint: entryPoint, target: target)
        scheduleNextTask(appReadiness: appReadiness)
    }

    static func scheduleNextTask(appReadiness: AppReadiness) {
        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            MessageFetchBGRefreshTask.getShared(appReadiness: appReadiness)?.scheduleTask()
            Task {
                await EpochSendBGProcessingTaskRunner().scheduleBGProcessingTaskIfNeeded()
            }
        }
    }
}

/// BGProcessingTask for night epoch sends, reserved for when the phone is
/// idle. It does no work of its own: the shared launch handler in
/// `BGProcessingTaskRunner` records the epoch send and schedules the tasks
/// for the next epoch.
struct EpochSendBGProcessingTaskRunner: BGProcessingTaskRunner {
    static let taskIdentifier = "EpochSendBGProcessingTask"
    static let logPrefix: String? = nil
    static let requiresNetworkConnectivity = true
    static let requiresExternalPower = false

    func startCondition() -> BGProcessingTaskStartCondition {
        let nextEpoch = EpochParticipation.nextEpochStart(after: Date())
        return EpochParticipation.isNightEpoch(nextEpoch) ? .after(nextEpoch) : .never
    }

    func run() async throws {
        Logger.info("Ran.")
    }
}
