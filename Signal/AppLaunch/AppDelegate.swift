//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Receives app-wide lifecycle events from UIKit, and forwards them to
/// ``AppLifecycleManager``.
///
/// Events tied to the app's UI arrive in ``SceneDelegate`` instead.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private let lifecycleManager = AppLifecycleManager.shared

    // MARK: - Execution Logging

    private var foregroundSessionId: UUID?

    // MARK: - Lifecycle

    func applicationWillEnterForeground(_ application: UIApplication) {
        Logger.info("")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AssertIsOnMainThread()
        if CurrentAppContext().isRunningTests {
            return
        }

        if foregroundSessionId == nil {
            foregroundSessionId = ExecutionLogger.shared.logStart(entryPoint: "foregroundSession", target: "mainApp")
        }

        Logger.warn("")

        if didAppLaunchFail {
            return
        }

        appReadiness.runNowOrWhenAppDidBecomeReadySync { self.handleActivation() }

        // Clear all notifications whenever we become active.
        // When opening the app from a notification,
        // AppDelegate.didReceiveLocalNotification will always
        // be called _before_ we become active.
        clearAppropriateNotificationsAndRestoreBadgeCount()

        // On every activation, clear old temp directories.
        OWSFileSystem.clearOldTemporaryDirectories()

        // Ensure that all windows have the correct frame.
        AppEnvironment.shared.windowManagerRef.updateWindowFrames()
    }

    private let flushQueue = DispatchQueue(label: "org.signal.flush", qos: .utility)

    func applicationWillResignActive(_ application: UIApplication) {
        AssertIsOnMainThread()

        Logger.warn("")

        if didAppLaunchFail {
            return
        }

        appReadiness.runNowOrWhenAppDidBecomeReadySync {
            self.refreshConnection(isAppActive: false)
        }

        clearAppropriateNotificationsAndRestoreBadgeCount()

        let backgroundTask = OWSBackgroundTask(label: #function)
        flushQueue.async {
            defer { backgroundTask.end() }
            Logger.flush()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        if let sessionId = foregroundSessionId {
            ExecutionLogger.shared.logEnd(id: sessionId, entryPoint: "foregroundSession", target: "mainApp")
            foregroundSessionId = nil
        }

        Logger.info("")

        if shouldKillAppWhenBackgrounded {
            owsFail("")
        }
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Logger.info("")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // If we reach this point, the app has launched & terminated successfully,
        // which means this flag can be cleared.
        CurrentAppContext().appUserDefaults().removeObject(forKey: Constants.appLaunchesAttemptedKey)
        Logger.info("")
        Logger.flush()
    }

    // MARK: - App Launch

    private lazy var appReadiness = AppReadinessImpl()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        return lifecycleManager.didFinishLaunching(launchOptions: launchOptions)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        lifecycleManager.didReceiveMemoryWarning()
    }

    /// UIKit generally prefers `SceneDelegate.sceneDidDisconnect(_:)` for
    /// scene-based apps, which also calls through to the manager.
    func applicationWillTerminate(_ application: UIApplication) {
        lifecycleManager.willTerminate()
    }

    // MARK: - Orientation

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?,
    ) -> UIInterfaceOrientationMask {
        return lifecycleManager.supportedInterfaceOrientations(for: window)
    }

    // MARK: - Notifications

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        lifecycleManager.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        lifecycleManager.didFailToRegisterForRemoteNotifications(error: error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void,
    ) {
        lifecycleManager.didReceiveRemoteNotification(userInfo, completionHandler: completionHandler)
        AssertIsOnMainThread()

        if DebugFlags.verboseNotificationLogging {
            Logger.info("")
        }

        let executionId = ExecutionLogger.shared.logStart(entryPoint: "silentPush", target: "mainApp")
        Task {
            defer {
                ExecutionLogger.shared.logEnd(id: executionId, entryPoint: "silentPush", target: "mainApp")
                // TODO: Report the actual outcome.
                completionHandler(.newData)
            }
            do {
                try await withCooperativeTimeout(seconds: 27) {
                    try await self.appReadiness.waitForAppReady()

                    // Mark down that the APNS token is working because we got a push.
                    let databaseStorage = SSKEnvironment.shared.databaseStorageRef
                    async let _ = databaseStorage.awaitableWrite { tx in
                        APNSRotationStore.didReceiveAPNSPush(transaction: tx)
                    }

                    try await self.processRemoteNotification(userInfo)
                }
            } catch {
                Logger.error("Failed to process remote notification: \(error)")
            }
        }
    }

    private enum HandleSilentPushContentResult {
        case handled
        case notHandled
    }

    // TODO: NSE Lifecycle, is this invoked when the NSE wakes the main app?
    @concurrent
    private func processRemoteNotification(_ remoteNotification: [AnyHashable: Any]) async throws {
        try await self.appReadiness.waitForAppReady()
        switch try await self.handleSilentPushContent(remoteNotification) {
        case .handled:
            break
        case .notHandled:
            let tsAccountManager = DependenciesBridge.shared.tsAccountManager
            _ = try tsAccountManager.registeredStateWithMaybeSneakyTransaction()
            let backgroundMessageFetcher = DependenciesBridge.shared.backgroundMessageFetcherFactory.buildFetcher()
            await backgroundMessageFetcher.start()

            // If we get canceled, we want to ignore the contact sync in this method
            // and return control to the caller.
            let syncContacts = CancellableContinuation<Void>()
            Task {
                // If the main app gets woken to process messages in the background, check
                // for any pending NSE requests to fulfill.
                let result = await Result(catching: {
                    try await SSKEnvironment.shared.syncManagerRef.syncAllContactsIfFullSyncRequested()
                })
                syncContacts.resume(with: result)
            }

            let result = await Result(catching: {
                // If the contact sync fails, ignore it. In this method, we care about the
                // result of fetching messages, not sending opportunistic contact syncs.
                try? await syncContacts.wait()
                try await backgroundMessageFetcher.waitForFetchingProcessingAndSideEffects()
            })
            await backgroundMessageFetcher.stopAndWaitBeforeSuspending()
            try result.get()
        }
    }

    @concurrent
    private func handleSilentPushContent(_ remoteNotification: [AnyHashable: Any]) async throws -> HandleSilentPushContentResult {
        if let spamChallengeToken = remoteNotification["rateLimitChallenge"] as? String {
            SSKEnvironment.shared.spamChallengeResolverRef.handleIncomingPushChallengeToken(spamChallengeToken)
            // TODO: Wait only until the token has been submitted.
            try await Task.sleep(nanoseconds: 20.clampedNanoseconds)
            return .handled
        }

        if let preAuthChallengeToken = remoteNotification["challenge"] as? String {
            AppEnvironment.shared.pushRegistrationManagerRef.didReceiveVanillaPreAuthChallengeToken(preAuthChallengeToken)
            // TODO: Wait only until the token has been submitted.
            try await Task.sleep(nanoseconds: 20.clampedNanoseconds)
            return .handled
        }

        return .notHandled
    }

    private func clearAppropriateNotificationsAndRestoreBadgeCount() {
        AssertIsOnMainThread()

        appReadiness.runNowOrWhenAppDidBecomeReadySync {
            let oldBadgeValue = UIApplication.shared.applicationIconBadgeNumber
            SSKEnvironment.shared.notificationPresenterRef.clearNotificationsForAppActivate()
            UIApplication.shared.applicationIconBadgeNumber = oldBadgeValue
        }
    }

    // MARK: - Handoff

    /// Among other things, this is used by "call back" CallKit dialog and calling from the Contacts app.
    ///
    /// We always return true if we are going to try to handle the user activity
    /// since we never want iOS to contact us again using a URL.
    ///
    /// From https://developer.apple.com/documentation/uikit/uiapplicationdelegate/1623072-application?language=objc:
    ///
    /// If you do not implement this method or if your implementation returns
    /// false, iOS tries to create a document for your app to open using a URL.
    @available(iOS, deprecated: 13.0) // hack to mute deprecation warnings; this is not deprecated
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void,
    ) -> Bool {
        AssertIsOnMainThread()

        if didAppLaunchFail {
            return false
        }

        Logger.info("\(userActivity.activityType)")

        switch userActivity.activityType {
        case "INSendMessageIntent":
            let intent = userActivity.interaction?.intent
            guard let intent = intent as? INSendMessageIntent else {
                owsFailDebug("Wrong type for intent: \(type(of: intent))")
                return false
            }
            guard let threadUniqueId = intent.conversationIdentifier else {
                owsFailDebug("Missing threadUniqueId for intent")
                return false
            }
            appReadiness.runNowOrWhenAppDidBecomeReadySync {
                let tsAccountManager = DependenciesBridge.shared.tsAccountManager
                guard tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
                    Logger.warn("Ignoring user activity; not registered.")
                    return
                }
                SignalApp.shared.presentConversationAndScrollToFirstUnreadMessage(
                    threadUniqueId: threadUniqueId,
                    animated: false,
                )
            }
            return true
        case "INStartVideoCallIntent":
            return handleStartCallIntent(
                INStartVideoCallIntent.self,
                userActivity: userActivity,
                contacts: \.contacts,
                isVideoCall: { _ in true },
            )
        case "INStartAudioCallIntent":
            return handleStartCallIntent(
                INStartAudioCallIntent.self,
                userActivity: userActivity,
                contacts: \.contacts,
                isVideoCall: { _ in false },
            )
        case "INStartCallIntent":
            return handleStartCallIntent(
                INStartCallIntent.self,
                userActivity: userActivity,
                contacts: \.contacts,
                isVideoCall: { $0.callCapability == .videoCall },
            )
        case NSUserActivityTypeBrowsingWeb:
            guard let webpageUrl = userActivity.webpageURL else {
                owsFailDebug("Missing webpageUrl.")
                return false
            }
            return handleOpenUrl(webpageUrl)
        default:
            return false
        }
    }

    private func handleStartCallIntent<T: INIntent>(
        _ intentType: T.Type,
        userActivity: NSUserActivity,
        contacts: KeyPath<T, [INPerson]?>,
        isVideoCall: (T) -> Bool,
    ) -> Bool {
        let intent = userActivity.interaction?.intent
        guard let intent = intent as? T else {
            owsFailDebug("Wrong type for intent: \(type(of: intent))")
            return false
        }
        guard let handle = intent[keyPath: contacts]?.first?.personHandle?.value else {
            owsFailDebug("Missing handle for intent")
            return false
        }
        let isVideo = isVideoCall(intent)

        Task { @MainActor [appReadiness] in
            do {
                try await appReadiness.waitForAppReady()
            } catch {
                return
            }

            let callService = AppEnvironment.shared.callService!
            let screenLockUI = AppEnvironment.shared.screenLockUI
            let tsAccountManager = DependenciesBridge.shared.tsAccountManager

            do {
                try await screenLockUI.waitForScreenUnlockThrowingPrevious()
            } catch {
                return
            }

            guard tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
                Logger.warn("Ignoring user activity; not registered.")
                return
            }
            guard let callTarget = CallKitCallManager.callTargetForHandleWithSneakyTransaction(handle) else {
                Logger.warn("Ignoring user activity; unknown user.")
                return
            }
            // This intent can be received from more than one user interaction.
            //
            // * It can be received if the user taps the "video" button in the CallKit
            // UI for an an ongoing call. If so, the correct response is to try to
            // activate the local video for that call.
            //
            // * It can be received if the user taps the "video" button for a contact
            // in the contacts app. If so, the correct response is to try to initiate a
            // new call to that user - unless there is another call in progress.
            if let currentCall = callService.callServiceState.currentCall {
                if isVideo, case .individual = currentCall.mode, currentCall.mode.matches(callTarget) {
                    Logger.info("Upgrading existing call to video")
                    callService.updateIsLocalVideoMuted(isLocalVideoMuted: false)
                } else {
                    Logger.warn("Ignoring user activity; already on another call")
                }
                return
            }
            callService.initiateCall(to: callTarget, isVideo: isVideo)
        }

        return true
    }

    // MARK: - Events

    @objc
    private func registrationStateDidChange() {
        AssertIsOnMainThread()

        Logger.info("")

        scheduleBgAppRefresh()

        let attachmentDownloadManager = DependenciesBridge.shared.attachmentDownloadManager
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager

        let registeredState = try? tsAccountManager.registeredStateWithMaybeSneakyTransaction()
        if let registeredState {
            Logger.info("localAci: \(registeredState.localIdentifiers.aci)")

            attachmentDownloadManager.beginDownloadingIfNecessary()

            // Schedule a Cron run if we're in the foreground.
            if !self.activeConnectionTokens.isEmpty {
                self.startCronTask()
            }
        }

        Self.updateApplicationShortcutItems(isRegistered: registeredState != nil)
    }

    // MARK: - Shortcut Items

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void,
    ) {
        AssertIsOnMainThread()

        if didAppLaunchFail {
            completionHandler(false)
            return
        }

        appReadiness.runNowOrWhenUIDidBecomeReadySync {
            let tsAccountManager = DependenciesBridge.shared.tsAccountManager
            guard tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
                let controller = ActionSheetController(
                    title: OWSLocalizedString("REGISTER_CONTACTS_WELCOME", comment: ""),
                    message: OWSLocalizedString("REGISTRATION_RESTRICTED_MESSAGE", comment: ""),
                )
                controller.addAction(ActionSheetAction(title: CommonStrings.okButton))
                UIApplication.shared.frontmostViewController?.present(controller, animated: true, completion: {
                    completionHandler(false)
                })
                return
            }
            SignalApp.shared.showNewConversationView()
            completionHandler(true)
        }
    }

    static func updateApplicationShortcutItems(isRegistered: Bool) {
        guard CurrentAppContext().isMainApp else { return }
        UIApplication.shared.shortcutItems = applicationShortcutItems(isRegistered: isRegistered)
    }

    static func applicationShortcutItems(isRegistered: Bool) -> [UIApplicationShortcutItem] {
        guard isRegistered else { return [] }
        return [.init(
            type: "\(Bundle.main.bundleIdPrefix).quickCompose",
            localizedTitle: OWSLocalizedString(
                "APPLICATION_SHORTCUT_NEW_MESSAGE",
                comment: "On the iOS home screen, if you tap and hold the Signal icon, this shortcut will appear. Tapping it will let users send a new message. You may want to refer to similar behavior in other iOS apps, such as Messages, for equivalent strings.",
            ),
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(type: .compose),
        )]
    }

    // MARK: - URL Handling

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        AssertIsOnMainThread()
        return handleOpenUrl(url)
    }

    private func handleOpenUrl(_ url: URL) -> Bool {
        AssertIsOnMainThread()

        if didAppLaunchFail {
            return false
        }

        guard let parsedUrl = UrlOpener.parseUrl(url) else {
            return false
        }
        self.appReadiness.runNowOrWhenUIDidBecomeReadySync {
            let urlOpener = UrlOpener(
                databaseStorage: SSKEnvironment.shared.databaseStorageRef,
                donationSubscriptionManager: DependenciesBridge.shared.donationSubscriptionManager,
                idealStore: DependenciesBridge.shared.pendingIDEALDonationStore,
                profileBadgeManager: DependenciesBridge.shared.profileBadgeManager,
                tsAccountManager: DependenciesBridge.shared.tsAccountManager,
            )

            urlOpener.openUrl(parsedUrl, in: self.window!)
        }
        return true
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    // The method will be called on the delegate when the user responded to the notification by opening the application,
    // dismissing the notification or choosing a UNNotificationAction. The delegate must be set before the application
    // returns from application:didFinishLaunchingWithOptions:.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        let executionId = ExecutionLogger.shared.logStart(entryPoint: "notificationResponse", target: "mainApp")
        let startDate = MonotonicDate()
        Task { @MainActor [appReadiness] () -> Void in
            defer {
                ExecutionLogger.shared.logEnd(id: executionId, entryPoint: "notificationResponse", target: "mainApp")
                completionHandler()
            }

            do {
                try await self.appReadiness.waitForAppReady()
            } catch {
                return
            }

            let screenLockUI = AppEnvironment.shared.screenLockUI
            let backgroundMessageFetcherFactory = DependenciesBridge.shared.backgroundMessageFetcherFactory

            let backgroundMessageFetcher = backgroundMessageFetcherFactory.buildFetcher()
            // So that we open up a connection for replies.
            await backgroundMessageFetcher.start()

            do {
                let elapsedDuration = (MonotonicDate() - startDate).seconds
                try await withCooperativeTimeout(seconds: 27 - elapsedDuration) {
                    // Do the actual thing we care about.
                    try await NotificationActionHandler.handleNotificationResponse(
                        response,
                        appReadiness: appReadiness,
                        screenLockUI: screenLockUI,
                    )

                    // Then wait for any enqueued messages (e.g., read receipts) to be sent.
                    try await backgroundMessageFetcher.waitForFetchingProcessingAndSideEffects()
                }
            } catch {
                Logger.warn("\(error)")
            }

            // So that we tear down gracefully.
            await backgroundMessageFetcher.stopAndWaitBeforeSuspending()
        }
    }
}
