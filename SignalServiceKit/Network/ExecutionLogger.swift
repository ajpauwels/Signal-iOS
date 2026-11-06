//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

public class ExecutionLogger {

    public static let shared = ExecutionLogger()

    private let writer: JSONLineLogWriter

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        let directory = OWSFileSystem.appSharedDataDirectoryPath()
        let url = URL(fileURLWithPath: directory).appendingPathComponent("execution-log.jsonl")
        writer = JSONLineLogWriter(fileURL: url, queueLabel: "org.signal.execution-logger")
    }

    public var logFileUrl: URL { writer.fileURL }

    @discardableResult
    public func logStart(entryPoint: String, target: String) -> UUID {
        let id = UUID()
        log(id: id, entryPoint: entryPoint, event: "start", target: target)
        return id
    }

    public func logEnd(id: UUID, entryPoint: String, target: String) {
        log(id: id, entryPoint: entryPoint, event: "end", target: target)
    }

    /// See `EpochParticipation`. `id` is the UUID of the execution
    /// opportunity that performed the send.
    public func logEpochSend(id: UUID, entryPoint: String, target: String) {
        log(id: id, entryPoint: entryPoint, event: "epochSend", target: target)
    }

    private func log(id: UUID, entryPoint: String, event: String, target: String) {
        let entry: [String: Any] = [
            "id": id.uuidString,
            "entryPoint": entryPoint,
            "event": event,
            "target": target,
            "timestamp": Self.formatter.string(from: Date()),
            "onExternalPower": Self.isOnExternalPower(),
        ]

        writer.append(entry)
    }

    private static func isOnExternalPower() -> Bool {
        // Battery state is only reported while monitoring is enabled, and
        // leaving it on has a cost. Restore the previous value rather than
        // forcing it off, since DeviceBatteryLevelManager may have it on.
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        switch device.batteryState {
        case .charging, .full:
            return true
        case .unplugged, .unknown:
            return false
        @unknown default:
            return false
        }
    }
}
