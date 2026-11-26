import Flutter
import Photos
import QuickLook
import UIKit

final class QuickLookSource: NSObject, QLPreviewControllerDataSource {
  let url: URL

  init(url: URL) {
    self.url = url
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    url as NSURL
  }
}

final class DropDrawerMobileBridge {
  static let shared = DropDrawerMobileBridge()
  static let appGroupId = "group.com.dropdrawer.shared"

  private var channel: FlutterMethodChannel?
  private var pendingFiles: [String] = []
  private var pendingTexts: [String] = []
  // QLPreviewController holds its data source weakly.
  private var quickLookSource: QuickLookSource?

  private init() {}

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "com.dropdrawer/mobile", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    self.channel = ch
    collectSharedInboxAndGroup()
  }

  func handleIncomingURL(_ url: URL) {
    if url.isFileURL {
      if let copied = copyIncomingFile(url) {
        enqueue(files: [copied], texts: [])
      }
      return
    }
    if url.scheme?.lowercased() == "dropdrawer" {
      collectSharedInboxAndGroup()
      flushIfAttached()
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "consumePendingShares":
      collectSharedInboxAndGroup()
      let payload: [String: Any] = [
        "files": pendingFiles,
        "texts": pendingTexts,
      ]
      pendingFiles.removeAll()
      pendingTexts.removeAll()
      result(payload)

    case "shareFiles":
      let paths = (args["paths"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
      guard !paths.isEmpty else {
        result(false)
        return
      }
      let urls = paths.map { URL(fileURLWithPath: $0) }
      presentShareSheet(items: urls, result: result)

    case "shareText":
      let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        result(false)
        return
      }
      presentShareSheet(items: [text], result: result)

    case "openFile":
      let path = args["path"] as? String ?? ""
      openFile(path: path, result: result)

    case "saveToGallery":
      let path = args["path"] as? String ?? ""
      saveToGallery(path: path, result: result)

    case "openExternalUrl":
      let raw = args["url"] as? String ?? ""
      guard (raw.hasPrefix("https://") || raw.hasPrefix("http://")),
            let url = URL(string: raw) else {
        result(false)
        return
      }
      DispatchQueue.main.async {
        UIApplication.shared.open(url, options: [:]) { ok in
          result(ok)
        }
      }

    case "readClipboard":
      let imagePath = args["imagePath"] as? String ?? ""
      result(readClipboard(imagePath: imagePath))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func enqueue(files: [String], texts: [String]) {
    guard !files.isEmpty || !texts.isEmpty else { return }
    pendingFiles.append(contentsOf: files)
    pendingTexts.append(contentsOf: texts)
    flushIfAttached()
  }

  private func flushIfAttached() {
    guard let ch = channel, (!pendingFiles.isEmpty || !pendingTexts.isEmpty) else { return }
    let payload: [String: Any] = [
      "files": pendingFiles,
      "texts": pendingTexts,
    ]
    pendingFiles.removeAll()
    pendingTexts.removeAll()
    DispatchQueue.main.async {
      ch.invokeMethod("onSharedPayload", arguments: payload)
    }
  }

  private func collectSharedInboxAndGroup() {
    let fm = FileManager.default
    // 1. Check Documents/Inbox (files opened via iOS "Open in DropDrawer")
    if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
      let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
      if let items = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) {
        for url in items {
          if let copied = copyIncomingFile(url) {
            pendingFiles.append(copied)
            try? fm.removeItem(at: url)
          }
        }
      }
    }

    // 2. Check optional App Group container (used when an iOS Share Extension is configured)
    if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
      let queueDir = groupURL.appendingPathComponent("pending_shares", isDirectory: true)
      if let items = try? fm.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil) {
        for url in items {
          if url.pathExtension.lowercased() == "ddtext",
             let text = try? String(contentsOf: url, encoding: .utf8),
             !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingTexts.append(text)
            try? fm.removeItem(at: url)
          } else if let copied = copyIncomingFile(url) {
            pendingFiles.append(copied)
            try? fm.removeItem(at: url)
          }
        }
      }
    }
  }

  private func copyIncomingFile(_ sourceURL: URL) -> String? {
    let fm = FileManager.default
    let accessing = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessing { sourceURL.stopAccessingSecurityScopedResource() }
    }
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = caches.appendingPathComponent("shared_incoming", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

    let rawName = sourceURL.lastPathComponent.isEmpty
      ? "shared_\(Int(Date().timeIntervalSince1970 * 1000))"
      : sourceURL.lastPathComponent
    var dest = dir.appendingPathComponent(rawName)
    if fm.fileExists(atPath: dest.path) {
      let stem = dest.deletingPathExtension().lastPathComponent
      let ext = dest.pathExtension
      let suffix = Int(Date().timeIntervalSince1970 * 1000)
      let name = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
      dest = dir.appendingPathComponent(name)
    }
    do {
      try fm.copyItem(at: sourceURL, to: dest)
      return dest.path
    } catch {
      return nil
    }
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let root = scenes.first(where: { $0.activationState == .foregroundActive })?
      .windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scenes.first?.windows.first?.rootViewController
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }

  private func presentShareSheet(items: [Any], result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let presenter = self.topViewController() else {
        result(false)
        return
      }
      let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
      if let popover = activity.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: presenter.view.bounds.midX,
          y: presenter.view.bounds.midY,
          width: 1,
          height: 1
        )
        popover.permittedArrowDirections = []
      }
      presenter.present(activity, animated: true) {
        result(true)
      }
    }
  }

  /// Shows a file with Quick Look (PDF, Office, images, video, audio, text...).
  /// Returns false when Quick Look cannot show the type, so Dart can offer the
  /// share sheet instead.
  private func openFile(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path),
          QLPreviewController.canPreview(url as NSURL) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      guard let presenter = self.topViewController() else {
        result(false)
        return
      }
      let source = QuickLookSource(url: url)
      self.quickLookSource = source
      let preview = QLPreviewController()
      preview.dataSource = source
      presenter.present(preview, animated: true) {
        result(true)
      }
    }
  }

  private func saveToGallery(path: String, result: @escaping FlutterResult) {
    guard FileManager.default.fileExists(atPath: path) else {
      result(false)
      return
    }
    let fileURL = URL(fileURLWithPath: path)
    let ext = fileURL.pathExtension.lowercased()
    let isVideo = ["mp4", "mov", "m4v", "mkv", "webm"].contains(ext)

    let performSave = {
      PHPhotoLibrary.shared().performChanges({
        if isVideo {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        } else {
          PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        }
      }) { success, _ in
        DispatchQueue.main.async {
          result(success)
        }
      }
    }

    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        if status == .authorized || status == .limited {
          performSave()
        } else {
          DispatchQueue.main.async { result(false) }
        }
      }
    } else {
      PHPhotoLibrary.requestAuthorization { status in
        if status == .authorized {
          performSave()
        } else {
          DispatchQueue.main.async { result(false) }
        }
      }
    }
  }

  private func readClipboard(imagePath: String) -> [String: Any] {
    let pb = UIPasteboard.general
    if let image = pb.image, !imagePath.isEmpty, let png = image.pngData() {
      let dest = URL(fileURLWithPath: imagePath)
      try? FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if (try? png.write(to: dest)) != nil {
        return ["kind": "image", "paths": [dest.path]]
      }
    }
    if let text = pb.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ["kind": "text", "text": text]
    }
    return ["kind": "empty"]
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    DropDrawerMobileBridge.shared.attach(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
