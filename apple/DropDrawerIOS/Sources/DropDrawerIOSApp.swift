import DropDrawerCore
import SwiftUI

@main
struct DropDrawerIOSApp: App {
    @State private var store = DropDrawerStore(
        storage: SessionStorage(suiteName: SessionStorage.appGroupId)
    )
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .task {
                    await store.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { await store.handleScenePhaseChanged(active: newPhase == .active) }
                }
                .onOpenURL { url in
                    Task { await handleIncomingURL(url) }
                }
        }
    }

    private func handleIncomingURL(_ url: URL) async {
        if url.isFileURL {
            guard store.isLoggedIn else {
                store.showToast("请先登录以同步分享的文件")
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
