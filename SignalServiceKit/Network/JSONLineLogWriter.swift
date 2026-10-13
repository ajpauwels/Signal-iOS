//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Appends newline-delimited JSON ("JSONL") entries to a log file in the
/// app-group shared container.
///
/// The log files live in the shared container and are written from multiple
/// processes (the main app, the NSE, and the share extension), which can run
/// concurrently. A per-process serial queue only orders writes within a single
/// process, so this writer additionally takes an advisory file lock
/// (`flock(LOCK_EX)`) around each append. Combined with `O_APPEND`, that
/// serializes appends across every process sharing the file and prevents
/// interleaved or clobbered lines.
final class JSONLineLogWriter {

    private let logFileURL: URL
    private let queue: DispatchQueue

    init(fileURL: URL, queueLabel: String) {
        self.logFileURL = fileURL
        self.queue = DispatchQueue(label: queueLabel)
    }

    var fileURL: URL { logFileURL }

    func append(_ entry: [String: Any]) {
        queue.async { [logFileURL] in
            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  var line = String(data: data, encoding: .utf8) else {
                return
            }
            line.append("\n")
            guard let lineData = line.data(using: .utf8) else {
                return
            }

            let fd = open(logFileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else {
                return
            }
            defer { close(fd) }

            // Advisory lock held for the duration of the write so that
            // concurrent writes from other processes can't interleave.
            guard flock(fd, LOCK_EX) == 0 else {
                return
            }
            defer { flock(fd, LOCK_UN) }

            lineData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else {
                    return
                }
                let count = buffer.count
                var total = 0
                while total < count {
                    let written = write(fd, base + total, count - total)
                    if written <= 0 {
                        break
                    }
                    total += written
                }
            }
        }
    }
}
