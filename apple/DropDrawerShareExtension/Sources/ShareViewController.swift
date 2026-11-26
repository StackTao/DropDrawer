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
                    if Self.copyToQueue(source: url, queueDir: queueDir) { enqueued = true }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if await saveImageAttachment(provider: provider, queueDir: queueDir) {
                        enqueued = true
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
                          let url = await loadFileURL(provider: provider, typeId: UTType.movie.identifier) {
                    if Self.copyToQueue(source: url, queueDir: queueDir) { enqueued = true }
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

        if enqueued, let openURL = URL(string: "dropdrawer://share") {
            openHostApp(openURL)
        }
        finish()
    }

    private nonisolated static func copyToQueue(source: URL, queueDir: URL) -> Bool {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = source.lastPathComponent.isEmpty ? "shared_\(UUID().uuidString)" : source.lastPathComponent
        let dest = queueDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))_\(name)")
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
        await withCheckedContinuation { cont in
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

    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private struct ShareProgressView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在发送到 DropDrawer…")
                .font(.subheadline.weight(.medium))
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
