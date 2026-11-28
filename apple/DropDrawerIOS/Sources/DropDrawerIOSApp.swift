import DropDrawerCore
import SwiftUI
import UIKit
import UserNotifications

final class DropDrawerIOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app once the store exists, so APNs tokens can be forwarded.
    weak var store: DropDrawerStore?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if targetEnvironment(simulator)
        let sandbox = true
        #else
        let profile: Data?
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            guard let data = try? Data(contentsOf: url) else { return }
            profile = data
        } else {
            profile = nil
        }
        guard let environment = APNsEnvironment.fromProvisioningProfile(profile) else { return }
        let sandbox = environment == .development
        #endif
        Task { await store?.updatePushToken(token, sandbox: sandbox) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulators without push support and unsigned builds end up here; the
        // app keeps working through its WebSocket.
    }

    /// A push sent while the app was in the background can arrive after it resumes.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadCoordinator.shared.handleBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct DropDrawerIOSApp: App {
    @UIApplicationDelegateAdaptor(DropDrawerIOSAppDelegate.self) private var appDelegate
    @State private var store = DropDrawerStore(
        storage: SessionStorage(suiteName: SessionStorage.appGroupId)
    )
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .task {
                    appDelegate.store = store
                    await store.bootstrap()
                }
                .onChange(of: store.wantsPushNotifications, initial: true) { _, wants in
                    guard wants else { return }
                    Task { await registerForPushNotifications() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { await store.handleScenePhaseChanged(newPhase) }
                }
                .onOpenURL { url in
                    Task { await handleIncomingURL(url) }
                }
        }
    }

    /// Asks once for permission (iOS remembers the answer) and registers with
    /// APNs; the token arrives in the app delegate.
    private func registerForPushNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted, store.wantsPushNotifications else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func handleIncomingURL(_ url: URL) async {
        if url.isFileURL {
            guard store.isLoggedIn else {
                store.showToast(String(localized: "请先登录以同步分享的文件"))
                return
            }
            await store.addFiles([url])
        } else if url.scheme?.lowercased() == "dropdrawer" {
            await store.consumeSharedAppGroupQueue()
        }
    }
}

private struct RootView: View {
    @Bindable var store: DropDrawerStore

    var body: some View {
        Group {
            if store.isLoggedIn {
                MainTabView(store: store)
            } else {
                LoginView(store: store)
            }
        }
        .overlay(alignment: .top) {
            if let message = store.toastMessage {
                ToastBanner(message: message)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: store.toastMessage)
    }
}

private struct ToastBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 20)
    }
}
