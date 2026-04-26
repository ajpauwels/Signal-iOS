//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public class ExecutionLogger {

    public static let shared = ExecutionLogger()

    private let queue = DispatchQueue(label: "org.signal.execution-logger")

    private let logFileURL: URL

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        let directory = OWSFileSystem.appSharedDataDirectoryPath()
        logFileURL = URL(fileURLWithPath: directory).appendingPathComponent("execution-log.jsonl")
    }

    public var logFileUrl: URL { logFileURL }

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

        queue.async { [logFileURL] in
            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  var line = String(data: data, encoding: .utf8) else {
                return
            }
            line.append("\n")

            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? line.data(using: .utf8)?.write(to: logFileURL, options: .atomic)
            }
        }
    }
}
