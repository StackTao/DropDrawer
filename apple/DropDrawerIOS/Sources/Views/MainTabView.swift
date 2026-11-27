import DropDrawerCore
import SwiftUI

enum MainTab: Hashable {
    case files
    case shares
    case settings
    case search
}

struct MainTabView: View {
    @Bindable var store: DropDrawerStore
    @State private var selectedTab: MainTab = .files

    var body: some View {
        tabContent
            .modifier(MinimizeTabBarOnScroll())
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "文件"), systemImage: "tray.full", value: MainTab.files) {
                HomeView(store: store)
            }

            Tab(String(localized: "外链"), systemImage: "link", value: MainTab.shares) {
                NavigationStack {
                    ShareLinksView(store: store, targetItems: [])
                        .navigationTitle(String(localized: "外链"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }

            Tab(String(localized: "设置"), systemImage: "gearshape", value: MainTab.settings) {
                NavigationStack {
                    PreferencesView(store: store)
                }
            }

            Tab(String(localized: "搜索"), systemImage: "magnifyingglass", value: MainTab.search, role: .search) {
                SearchTabView(store: store)
            }
        }
    }
}

private struct MinimizeTabBarOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
