//
// Copyright 2016 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

struct RegisterDeviceTokenBody: Codable {
    var token: String
}

struct RegisterDeviceTokenResponse: Codable {}

class SyncPushTokensJob: NSObject {
    enum Mode {
        case normal
        case forceRotation
        case rotateIfEligible
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    private static let hasUploadedTokensOnce = AtomicBool(false, lock: .sharedGlobal)

    func run() async throws {
        switch mode {
        case .normal:
            // Don't rotate.
            return try await run(shouldRotateAPNSToken: false)
        case .forceRotation:
            // Always rotate
            return try await run(shouldRotateAPNSToken: true)
        case .rotateIfEligible:
            let shouldRotate = SSKEnvironment.shared.databaseStorageRef.read { tx -> Bool in
                return APNSRotationStore.canRotateAPNSToken(transaction: tx)
            }
            guard shouldRotate else {
                // If we aren't rotating, no-op.
                return
            }
            return try await run(shouldRotateAPNSToken: true)
        }
    }

    typealias ApnRegistrationId = RegistrationRequestFactory.ApnRegistrationId

    private func run(shouldRotateAPNSToken: Bool) async throws {
        let regResult = try await AppEnvironment.shared.pushRegistrationManagerRef.requestPushTokens(forceRotation: shouldRotateAPNSToken)

        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            if shouldRotateAPNSToken {
                APNSRotationStore.didRotateAPNSToken(transaction: tx)
            }
        }

        let pushToken = regResult.apnsToken

        let reason: String

        if SSKEnvironment.shared.preferencesRef.pushToken != pushToken {
            reason = "changed"
        } else if !Self.hasUploadedTokensOnce.get() {
            reason = "launched"
        } else {
            return
        }

        Logger.info("uploading push token; reason: \(reason), pushToken: \(redact(pushToken))")
        try await self.updatePushTokens(pushToken: pushToken)

        await recordPushTokensLocally(pushToken: pushToken)

        Self.hasUploadedTokensOnce.set(true)
    }

    class func run(mode: Mode = .normal) {
        Task {
            do {
                try await SyncPushTokensJob(mode: mode).run()
            } catch {
                Logger.error("Error: \(error).")
            }
        }
    }

    private func recordPushTokensLocally(pushToken: String) async {
        assert(!Thread.isMainThread)

        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            if pushToken != SSKEnvironment.shared.preferencesRef.getPushToken(tx: tx) {
                Logger.info("saved new push token: \(redact(pushToken))")
                SSKEnvironment.shared.preferencesRef.setPushToken(pushToken, tx: tx)
            }
        }
    }

    // MARK: - Requests

    private func updatePushTokens(pushToken: String) async throws {
        // sn17: send push token to our own server
        let registerDeviceTokenURL = "https://signal.pauwelslabs.com/v1/accounts/apn"
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager
        if let url = URL(string: registerDeviceTokenURL),
           let username = tsAccountManager.storedServerUsernameWithMaybeTransaction,
           let password = tsAccountManager.storedServerAuthTokenWithMaybeTransaction,
           let bodyJSON = try? JSONEncoder().encode(RegisterDeviceTokenBody(token: pushToken)) {
            let b64EncodedAuth = Data("\(username):\(password)".utf8).base64EncodedString()
            let authHeader = "Basic \(b64EncodedAuth)"
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(authHeader, forHTTPHeaderField: "authorization")
            request.httpMethod = "post"
            request.httpBody = bodyJSON

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    Logger.info("[sn17] successfully sent push token to sn17 server")
                } else {
                    Logger.error("[sn17] failed to send push token to sn17 server: \(httpResponse.statusCode)")
                }
            } else {
                Logger.error("[sn17] sent push token to sn17 server but could not decode response")
            }
        }
        return try await Retry.performWithBackoff(maxAttempts: 3) {
            try await DependenciesBridge.shared.chatConnectionManager.withAuthService(.devices) {
                try await $0.setPushToken(apns: pushToken)
            }
        }
    }
}

private func redact(_ string: String?) -> String {
    guard let string else { return "nil" }
#if DEBUG
    return string
#else
    return "\(string.prefix(2))…\(string.suffix(2))"
#endif
}
