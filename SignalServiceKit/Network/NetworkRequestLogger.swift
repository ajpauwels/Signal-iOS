//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public class NetworkRequestLogger {

    public static let shared = NetworkRequestLogger()

    private let queue = DispatchQueue(label: "org.signal.network-request-logger")

    private let logFileURL: URL

    private init() {
        let directory = OWSFileSystem.appSharedDataDirectoryPath()
        logFileURL = URL(fileURLWithPath: directory).appendingPathComponent("network-request-log.jsonl")
    }

    public var logFileUrl: URL { logFileURL }

    public func resolveTrigger() -> String {
        if CurrentAppContext().isNSE {
            return "push"
        } else if CurrentAppContext().isInBackground() {
            return "background"
        } else {
            return "user"
        }
    }

    public func log(
        protocol proto: String,
        direction: String,
        method: String? = nil,
        path: String? = nil,
        bodySize: Int? = nil,
        trigger: String? = nil
    ) {
        let resolvedTrigger: String
        if let trigger {
            resolvedTrigger = trigger
        } else {
            resolvedTrigger = resolveTrigger()
        }

        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "protocol": proto,
            "direction": direction,
            "trigger": resolvedTrigger,
        ]
        if let method {
            entry["method"] = method
        }
        if let path {
            entry["path"] = path
        }
        if let bodySize {
            entry["bodySize"] = bodySize
        }

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
