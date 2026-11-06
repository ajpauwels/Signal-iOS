//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Experiment: the app tries to "send" one message per hourly epoch
/// (00:00–00:59, 01:00–01:59, ... in local time) using whatever execution
/// opportunity it is given: foregrounding, NSE, share extension, background
/// tasks, etc.
///
/// The send is simulated; it is just an `epochSend` line in the
/// `ExecutionLogger` carrying the UUID of the execution opportunity that
/// performed it.
///
/// "Has this epoch been sent" is shared between the main app and the
/// extensions through a file in the shared container, guarded by a
/// cross-process `flock`. Scheduling the background tasks that cover the next
/// epoch is main-app only (see `EpochScheduler`), since `BGTaskScheduler` is
/// unavailable to extensions.
public enum EpochParticipation {

    /// The BGProcessingTask is only requested for night epochs (00:00–06:59
    /// local), to reserve it for when the phone is idle. The BGAppRefreshTask
    /// is requested for every epoch.
    private static let lastNightHour = 6

    public static func epochStart(containing date: Date) -> Date {
        return Calendar.current.dateInterval(of: .hour, for: date)!.start
    }

    public static func nextEpochStart(after date: Date) -> Date {
        return Calendar.current.date(byAdding: .hour, value: 1, to: epochStart(containing: date))!
    }

    public static func isNightEpoch(_ epochStart: Date) -> Bool {
        return Calendar.current.component(.hour, from: epochStart) <= lastNightHour
    }

    /// Records a send for the current epoch unless one has already been
    /// recorded. Returns true if a send was recorded.
    ///
    /// The main app, NSE and share extension can all call this at the same
    /// instant, so the read-compare-write runs under an exclusive `flock` on
    /// a file in the shared container. The file's contents are the last-sent
    /// epoch, as a Unix timestamp of its start.
    @discardableResult
    public static func sendIfNeeded(executionId: UUID, entryPoint: String, target: String) -> Bool {
        let currentEpoch = Int(epochStart(containing: Date()).timeIntervalSince1970)
        let path = OWSFileSystem.appSharedDataDirectoryPath().appendingPathComponent("epoch-send.lock")
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            Logger.error("Couldn't open epoch send file (errno \(errno)).")
            return false
        }
        defer { close(fd) }

        do {
            // The lock is only held for the few microseconds of the
            // read-compare-write below, so contention is rare and brief. We
            // still never wait indefinitely: iOS suspends (rather than kills)
            // backgrounded processes, so the main app could in principle be
            // frozen while holding the lock, and a blocking wait in the NSE
            // would then hang until its deadline killed it. The kernel releases
            // the lock if the holder dies, but not while it is merely suspended.
            // After a bounded wait we proceed without the lock; the worst case
            // is a duplicate epochSend line, which is harmless, whereas a
            // missed epoch is not.
            var didLock = false
            for _ in 0..<10 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    didLock = true
                    break
                }
                usleep(10_000)
            }
            if !didLock {
                Logger.warn("Proceeding without the epoch send lock.")
            }
            defer {
                if didLock {
                    flock(fd, LOCK_UN)
                }
            }

            var buffer = [UInt8](repeating: 0, count: 32)
            let count = pread(fd, &buffer, buffer.count, 0)
            if count > 0, Int(String(decoding: buffer[0..<count], as: UTF8.self)) == currentEpoch {
                return false
            }
            let bytes = Array(String(currentEpoch).utf8)
            ftruncate(fd, 0)
            pwrite(fd, bytes, bytes.count, 0)
        }

        ExecutionLogger.shared.logEpochSend(id: executionId, entryPoint: entryPoint, target: target)
        return true
    }
}
