import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native iOS Share Extension: copies shared files/images/text into the shared
/// App Group queue and launches DropDrawer (`dropdrawer://share`) to sync them.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private static let appGroupId = "group.com.dropdrawer.shared"

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareProgressView())
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task {
            await processAttachments()
        }
    }

    private func processAttachments() async {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupId
        ) else {
            finish()
            return
        }

        let queueDir = groupURL.appendingPathComponent("pending_shares", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var enqueued = false

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadFileURL(provider: provider, typeId: UTType.fileURL.identifier) {
                    if await Self.copyToQueueInBackground(source: url, queueDir: queueDir) { enqueued = true }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if await saveImageAttachment(provider: provider, queueDir: queueDir) {
                        enqueued = true
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
                          let url = await loadFileURL(provider: provider, typeId: UTType.movie.identifier) {
                    if await Self.copyToQueueInBackground(source: url, queueDir: queueDir) { enqueued = true }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = await loadString(provider: provider, typeId: UTType.plainText.identifier) {
                    let dest = queueDir.appendingPathComponent("text_\(UUID().uuidString).ddtext")
                    if (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil {
                        enqueued = true
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = await loadURL(provider: provider) {
                    let dest = queueDir.appendingPathComponent("url_\(UUID().uuidString).ddtext")
                    if (try? url.absoluteString.write(to: dest, atomically: true, encoding: .utf8)) != nil {
                        enqueued = true
                    }
                }
            }
        }

        // Finish only after the open request went out; completing the request
        // first tears the extension down before the host app is asked to open.
        if enqueued, let openURL = URL(string: "dropdrawer://share") {
            openHostApp(openURL) { [weak self] in self?.finish() }
        } else {
            finish()
        }
    }

    /// Large videos take a while to copy; keep that off the main thread.
    private nonisolated static func copyToQueueInBackground(source: URL, queueDir: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            ShareViewController.copyToQueue(source: source, queueDir: queueDir)
        }.value
    }

    private nonisolated static func copyToQueue(source: URL, queueDir: URL) -> Bool {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = source.lastPathComponent.isEmpty ? "shared_\(UUID().uuidString)" : source.lastPathComponent
        // "<digits>_<name>": the app strips the prefix again (queuedOriginalName);
        // the random tail keeps two same-named files from one share apart.
        let stamp = "\(Int(Date().timeIntervalSince1970 * 1000))\(Int.random(in: 1000...9999))"
        let dest = queueDir.appendingPathComponent("\(stamp)_\(name)")
        return (try? FileManager.default.copyItem(at: source, to: dest)) != nil
    }

    private func loadFileURL(provider: NSItemProvider, typeId: String) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadURL(provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }

    private func loadString(provider: NSItemProvider, typeId: String) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                cont.resume(returning: item as? String)
            }
        }
    }

    private func saveImageAttachment(provider: NSItemProvider, queueDir: URL) async -> Bool {
        // Ask for the encoded file first: decoding a 48 MP photo into a UIImage
        // and re-encoding it would exceed the extension's memory limit.
        if await saveImageFile(provider: provider, queueDir: queueDir) {
            return true
        }
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: Self.copyToQueue(source: url, queueDir: queueDir))
                } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                    let dest = queueDir.appendingPathComponent("image_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                    cont.resume(returning: (try? data.write(to: dest)) != nil)
                } else if let data = item as? Data {
                    let dest = queueDir.appendingPathComponent("image_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                    cont.resume(returning: (try? data.write(to: dest)) != nil)
                } else {
                    cont.resume(returning: false)
                }
            }
        }
    }

    private func saveImageFile(provider: NSItemProvider, queueDir: URL) async -> Bool {
        await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                // The file is only valid inside this handler, which runs off the main thread.
                guard let url else {
                    cont.resume(returning: false)
                    return
                }
                cont.resume(returning: Self.copyToQueue(source: url, queueDir: queueDir))
            }
        }
    }

    /// Opens the host app if the system lets the extension do so; the shared
    /// items stay queued either way and sync the next time DropDrawer opens.
    private func openHostApp(_ url: URL, completion: @escaping @MainActor @Sendable () -> Void) {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url, options: [:]) { _ in
                    Task { @MainActor in completion() }
                }
                return
            }
            responder = current.next
        }
        completion()
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private struct ShareProgressView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "正在发送到 DropDrawer…"))
                .font(.subheadline.weight(.medium))
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
