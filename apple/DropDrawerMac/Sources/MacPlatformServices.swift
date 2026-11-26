import AppKit
import DropDrawerCore
import Foundation
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

public enum MacClipboardPayload: Sendable {
    case files([URL])
    case image(URL)
    case text(String)
    case empty
}

@MainActor
public enum MacPlatformServices {
    private static func appSupportSubdir(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DropDrawerMac/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func readClipboard() -> MacClipboardPayload {
        let pb = NSPasteboard.general

        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            let existing = urls
                .map(\.standardizedFileURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                return .files(existing)
            }
        }

        var pngData: Data? = pb.data(forType: .png)
        if pngData == nil,
           let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff) {
            pngData = bitmap.representation(using: .png, properties: [:])
        }
        if let data = pngData, !data.isEmpty, let saved = saveClipboardImage(data: data) {
            return .image(saved)
        }

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }

        return .empty
    }

    private static func saveClipboardImage(data: Data) -> URL? {
        let dir = appSupportSubdir("clipboard_images")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let fileURL = dir.appendingPathComponent("clip_\(fmt.string(from: Date())).png")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Removes old clipboard screenshots (> 24h) while strictly excluding any path currently referenced by the drawer (`AGENTS.md` #12).
    public static func pruneClipboardFiles(excluding activePaths: Set<String>) {
        let dir = appSupportSubdir("clipboard_images")
        let normalizedProtected = Set(activePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for url in entries {
            let stdPath = url.standardizedFileURL.path
            if normalizedProtected.contains(stdPath) { continue }
            if let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mod < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Packs any directories into UTF-8 macOS ZIP archives before handing URLs to `DropDrawerStore.addFiles`.
    public static func prepareDropURLs(_ urls: [URL]) async -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for raw in urls {
            let url = raw.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let zipped = await zipDirectory(url) {
                    result.append(zipped)
                }
            } else {
                result.append(url)
            }
        }
        return result
    }

    private static func zipDirectory(_ dirURL: URL) async -> URL? {
        let archivesDir = appSupportSubdir("archives")
        let baseName = dirURL.lastPathComponent.isEmpty ? "folder" : dirURL.lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = archivesDir.appendingPathComponent("\(baseName)_\(stamp).zip")

        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dirURL.path, dest.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0 ? dest : nil
            } catch {
                return nil
            }
        }.value
    }

    @discardableResult
    public static func copyFilesToClipboard(_ urls: [URL]) -> Bool {
        let valid = urls.compactMap { url -> NSURL? in
            FileManager.default.fileExists(atPath: url.path) ? (url as NSURL) : nil
        }
        guard !valid.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects(valid)
    }

    public static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public static func pickFiles(modalGuard: (Bool) -> Void) async -> [URL] {
        modalGuard(true)
        defer { modalGuard(false) }

        return await withCheckedContinuation { cont in
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = "选择要放入抽屉的文件或文件夹"
            panel.prompt = "放入抽屉"
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.resolvesAliases = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            panel.begin { response in
                if response == .OK {
                    cont.resume(returning: panel.urls.map(\.standardizedFileURL))
                } else {
                    cont.resume(returning: [])
                }
            }
        }
    }

    public static func pickDirectory(modalGuard: (Bool) -> Void) async -> String? {
        modalGuard(true)
        defer { modalGuard(false) }

        return await withCheckedContinuation { cont in
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = "选择默认下载保存目录"
            panel.prompt = "选择此目录"
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.resolvesAliases = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    cont.resume(returning: url.standardizedFileURL.path)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Launch at Login (LaunchAgent plist)

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.dropdrawer.mac.plist")
    }

    public static var isLaunchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @discardableResult
    public static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        let url = launchAgentURL
        do {
            if enabled {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let plist: [String: Any] = [
                    "Label": "com.dropdrawer.mac",
                    "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                    "RunAtLoad": true,
                    "KeepAlive": false,
                ]
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist,
                    format: .xml,
                    options: 0
                )
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Formatting & Icons

    public static func formatBytes(_ bytes: Int64) -> String {
        DropDrawerCore.formatBytes(max(0, bytes))
    }

    public static func formatSpeed(_ bps: Int64) -> String {
        guard bps > 0 else { return "" }
        return "\(formatBytes(bps))/s"
    }

    public static func relativeTime(_ date: Date) -> String {
        let sec = Int(Date().timeIntervalSince(date))
        if sec < 45 { return "刚刚" }
        if sec < 3600 { return "\(sec / 60) 分钟前" }
        if sec < 86400 { return "\(sec / 3600) 小时前" }
        if sec < 86400 * 7 { return "\(sec / 86400) 天前" }
        let df = DateFormatter()
        df.dateFormat = "MM/dd HH:mm"
        return df.string(from: date)
    }

    public static func symbolForItem(_ item: DrawerItem) -> (name: String, color: Color) {
        if item.isText {
            return ("doc.plaintext", .indigo)
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg", "tiff":
            return ("photo", .blue)
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return ("film", .purple)
        case "mp3", "wav", "flac", "aac", "m4a", "ogg":
            return ("waveform", .pink)
        case "pdf":
            return ("doc.richtext", .red)
        case "zip", "tar", "gz", "7z", "rar", "dmg", "pkg", "iso":
            return ("doc.zipper", .orange)
        case "swift", "rs", "dart", "ts", "tsx", "js", "py", "go", "json", "yaml", "yml", "md", "sh":
            return ("chevron.left.forwardslash.chevron.right", .teal)
        case "doc", "docx", "pages", "rtf", "txt":
            return ("doc.text", .blue)
        case "xls", "xlsx", "numbers", "csv":
            return ("tablecells", .green)
        case "ppt", "pptx", "key":
            return ("rectangle.on.rectangle.angled", .orange)
        default:
            return ("doc", .secondary)
        }
    }

    public static func platformSymbol(_ platform: String) -> String {
        switch platform.lowercased() {
        case "macos": return "laptopcomputer"
        case "ios": return "iphone"
        case "android": return "smartphone"
        case "windows": return "desktopcomputer"
        case "linux": return "terminal"
        default: return "display"
        }
    }

    // MARK: - Memory-Efficient Decoded Thumbnail Cache

    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 128
        return c
    }()

    public static func cachedThumbnail(for item: DrawerItem, localURL: URL?, store: DropDrawerStore) -> NSImage? {
        if let b64 = item.thumbnailBase64, !b64.isEmpty {
            let key = "\(item.id):b64:\(b64.count)" as NSString
            if let hit = thumbCache.object(forKey: key) { return hit }
            if let data = store.thumbnailData(for: item), let img = NSImage(data: data) {
                thumbCache.setObject(img, forKey: key)
                return img
            }
        }
        if item.isImage, let localURL {
            let key = "\(item.id):file:\(localURL.path)" as NSString
            if let hit = thumbCache.object(forKey: key) { return hit }
            if let src = CGImageSourceCreateWithURL(localURL as CFURL, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    thumbCache.setObject(img, forKey: key)
                    return img
                }
            }
        }
        return nil
    }
}

// MARK: - Native QuickLook Preview Panel

@MainActor
public final class MacQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = MacQuickLookController()
    private var previewURLs: [URL] = []

    public func preview(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        previewURLs = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        if panel.isVisible {
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated {
            guard previewURLs.indices.contains(index) else { return nil }
            return previewURLs[index]
        }
        return url as NSURL?
    }
}
