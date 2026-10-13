//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

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

    private func log(id: UUID, entryPoint: String, event: String, target: String) {
        let entry: [String: Any] = [
            "id": id.uuidString,
            "entryPoint": entryPoint,
            "event": event,
            "target": target,
            "timestamp": Self.formatter.string(from: Date()),
        ]

        writer.append(entry)
    }
}
