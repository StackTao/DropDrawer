import AuthenticationServices
import DropDrawerCore
import Photos
import SwiftUI
import UIKit

enum MediaExportHelper {
    static func saveToPhotos(fileURL: URL) async -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "m4v", "mkv", "webm"].contains(ext)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
            } completionHandler: { success, _ in
                cont.resume(returning: success)
            }
        }
    }

    @MainActor
    static func pasteFromClipboard(into store: DropDrawerStore) async {
        let pb = UIPasteboard.general
        if let image = pb.image, let data = image.pngData() {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipboard_\(Int(Date().timeIntervalSince1970 * 1000)).png")
            do {
                try data.write(to: temp)
                await store.addFiles([temp])
                try? FileManager.default.removeItem(at: temp)
                return
            } catch {
                store.showToast("读取剪贴板图片失败")
                return
            }
        }
        if let text = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            await store.addText(text)
            return
        }
        store.showToast("剪贴板为空")
    }
}

/// Presents an in-app Safari authentication sheet for Google Sign-In.
@MainActor
final class WebAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String = "dropdrawer") {
        let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { _, _ in }
        auth.presentationContextProvider = self
        auth.prefersEphemeralWebBrowserSession = false
        self.session = auth
        auth.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.windows.first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}

/// Reusable item icon / thumbnail matching Apple Files style.
struct ItemThumbnailView: View {
    let store: DropDrawerStore
    let item: DrawerItem
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(.secondarySystemFill))
            if let img = resolvedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(symbolTint)
            }
        }
        .frame(width: size, height: size)
    }

    private var resolvedImage: UIImage? {
        if let data = store.thumbnailData(for: item), let img = UIImage(data: data) {
            return img
        }
        if item.isImage, let local = store.localFileURL(for: item.id),
           let img = UIImage(contentsOfFile: local.path) {
            return img
        }
        return nil
    }

    private var symbolName: String {
        if item.isText { return "text.quote" }
        if item.isImage { return "photo" }
        if item.isVideo { return "film" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3", "wav", "m4a", "flac", "aac": return "music.note"
        case "zip", "tar", "gz", "rar", "7z": return "archivebox"
        case "pdf", "doc", "docx", "md": return "doc.text"
        default: return "doc"
        }
    }

    private var symbolTint: Color {
        if item.isText { return .indigo }
        if item.isImage { return .blue }
        if item.isVideo { return .purple }
        return .secondary
    }
}
