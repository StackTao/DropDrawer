import AppKit
import DropDrawerCore
import SwiftUI
import UniformTypeIdentifiers

public struct MacRootView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController
    @State private var isDropTargeted = false

    public var body: some View {
        Group {
            if controller.isEdgeMode && controller.mode == .collapsed {
                CollapsedHandleView(controller: controller)
            } else if controller.isEdgeMode && controller.mode == .dragPill {
                DragGuidePillView(controller: controller)
                    .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                    }
            } else {
                expandedContainer
                    .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                    }
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(MacTheme.textPrimary)
    }

    private var expandedContainer: some View {
        let radius: CGFloat = controller.isEdgeMode ? 16 : 0
        return ZStack(alignment: .top) {
            MacTheme.surfaceTint
                .ignoresSafeArea()

            Group {
                if !store.isLoggedIn {
                    MacLoginView(store: store, controller: controller)
                } else {
                    switch controller.route {
                    case .home:
                        MacDrawerHomeView(store: store, controller: controller, isDragHovering: isDropTargeted)
                    case .detail(let itemId):
                        if let item = store.items.first(where: { $0.id == itemId }) {
                            MacItemDetailView(store: store, controller: controller, item: item)
                        } else {
                            MacDrawerHomeView(store: store, controller: controller, isDragHovering: isDropTargeted)
                                .onAppear { controller.route = .home }
                        }
                    case .shares(let itemIds):
                        let targets = itemIds.compactMap { id in store.items.first(where: { $0.id == id }) }
                        MacShareLinksView(store: store, controller: controller, targetItems: targets)
                    case .storage:
                        MacStorageSettingsView(store: store, controller: controller)
                    case .devices:
                        MacDevicesView(store: store, controller: controller)
                    case .preferences:
                        MacPreferencesView(store: store, controller: controller)
                    }
                }
            }

            if controller.isEdgeMode {
                EdgeDragGrip(controller: controller)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if controller.isEdgeMode {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isDropTargeted && store.isLoggedIn ? MacTheme.accent : MacTheme.hairline,
                        lineWidth: 1.0
                    )
                    .allowsHitTesting(false)
            } else if isDropTargeted && store.isLoggedIn {
                Rectangle()
                    .strokeBorder(MacTheme.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.14), value: isDropTargeted)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard store.isLoggedIn, !providers.isEmpty else { return false }

        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            Task { @MainActor in
                var urls: [URL] = []
                for provider in fileProviders {
                    if let url = await loadFileURL(from: provider) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty {
                    await controller.handleDroppedURLs(urls)
                }
            }
            return true
        }

        let textProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        if let first = textProviders.first {
            Task { @MainActor in
                if let text = await loadPlainText(from: first),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await store.addText(text)
                }
            }
            return true
        }

        return false
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let str = item as? String, let url = URL(string: str) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadPlainText(from provider: NSItemProvider) async -> String? {
        let typeId = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
            ? UTType.utf8PlainText.identifier
            : UTType.plainText.identifier
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                if let str = item as? String {
                    cont.resume(returning: str)
                } else if let data = item as? Data, let str = String(data: data, encoding: .utf8) {
                    cont.resume(returning: str)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Top Center Tiny Drag Grip (Edge Mode)

private struct EdgeDragGrip: View {
    @Bindable var controller: EdgeDrawerController
    @State private var isDragging = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(MacTheme.textTertiary)
                .frame(width: 22, height: 2)
        }
        .frame(width: 64, height: 10)
        .contentShape(Rectangle())
        .help("拖动抽屉")
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    if !isDragging {
                        isDragging = true
                        controller.beginHeaderDrag()
                    }
                    controller.updateHeaderDrag()
                }
                .onEnded { _ in
                    isDragging = false
                    controller.endHeaderDrag()
                }
        )
    }
}

// MARK: - Collapsed Edge Handle (exact 10×88 dark frosted edge handle)

private struct CollapsedHandleView: View {
    @Bindable var controller: EdgeDrawerController
    @State private var isHovered = false

    var body: some View {
        let isLeft = controller.dockSide == .left
        ZStack {
            Color.black.opacity(isHovered ? 0.65 : 0.42)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.95 : 0.50))
                .frame(width: 3, height: isHovered ? 40 : 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: isLeft ? .trailing : .leading) {
            Rectangle()
                .fill(Color.white.opacity(isHovered ? 0.48 : 0.18))
                .frame(width: 0.7)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Drag Guide Pill (246×46 exact desktop pill with sky-blue icon badge)

private struct DragGuidePillView: View {
    @Bindable var controller: EdgeDrawerController

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255),
                                Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)

            Text("拖到这儿，放入跨端抽屉")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.93))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
        )
    }
}
