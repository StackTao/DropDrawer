import AuthenticationServices
import DropDrawerCore
import ImageIO
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

/// Bounded decoded `UIImage` cache with off-main-thread `CGImageSource` downsampling
/// so list scrolling never decodes full-resolution photos on the main thread.
final class ThumbnailImageCache: @unchecked Sendable {
    static let shared = ThumbnailImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
    }

    func clear() {
        cache.removeAllObjects()
    }

    func loadDownsampled(
        key: String,
        thumbnailData: Data?,
        localFileURL: URL?,
        maxPixelSize: Int
    ) async -> UIImage? {
        if let hit = image(forKey: key) {
            return hit
        }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            if let data = thumbnailData,
               let img = Self.downsample(data: data, maxPixelSize: maxPixelSize) {
                return img
            }
            if let url = localFileURL,
               let img = Self.downsample(url: url, maxPixelSize: maxPixelSize) {
                return img
            }
            return nil
        }.value
        if let decoded {
            store(decoded, forKey: key)
        }
        return decoded
    }

    private static func downsample(data: Data, maxPixelSize: Int) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return makeThumbnail(from: src, maxPixelSize: maxPixelSize) ?? UIImage(data: data)
    }

    private static func downsample(url: URL, maxPixelSize: Int) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            return nil
        }
        return makeThumbnail(from: src, maxPixelSize: maxPixelSize)
    }

    private static func makeThumbnail(from source: CGImageSource, maxPixelSize: Int) -> UIImage? {
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 32),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}

/// Reusable item icon / thumbnail matching Apple Files style.
struct ItemThumbnailView: View {
    let store: DropDrawerStore
    let item: DrawerItem
    var size: CGFloat = 44

    @State private var loadedImage: UIImage?

    private var cacheKey: String {
        let localPath = item.isImage ? (store.localFilePaths[item.id] ?? "") : ""
        let hasThumb = (item.thumbnailBase64?.isEmpty == false) ? "1" : "0"
        return "\(item.id)_\(Int(size))_\(hasThumb)_\(localPath)"
    }

    var body: some View {
        let displayImage = loadedImage ?? ThumbnailImageCache.shared.image(forKey: cacheKey)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(.secondarySystemFill))
            if let img = displayImage {
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
        .task(id: cacheKey) {
            let key = cacheKey
            if let cached = ThumbnailImageCache.shared.image(forKey: key) {
                loadedImage = cached
                return
            }
            let data = store.thumbnailData(for: item)
            let localURL = item.isImage ? store.localFileURL(for: item.id) : nil
            guard data != nil || localURL != nil else {
                loadedImage = nil
                return
            }
            let decoded = await ThumbnailImageCache.shared.loadDownsampled(
                key: key,
                thumbnailData: data,
                localFileURL: localURL,
                maxPixelSize: Int(size * 3)
            )
            if !Task.isCancelled {
                loadedImage = decoded
            }
        }
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
