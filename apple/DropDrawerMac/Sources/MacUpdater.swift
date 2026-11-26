import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

public enum MacUpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available
    case downloading
    case installing
    case failed
}

public struct MacSemVer: Comparable, Sendable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public var description: String {
        if let prerelease, !prerelease.isEmpty {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func parse(_ raw: String) -> MacSemVer? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let noV = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let noBuild = noV.split(separator: "+", maxSplits: 1).first.map(String.init) ?? noV
        let dashParts = noBuild.split(separator: "-", maxSplits: 1)
        let nums = dashParts[0].split(separator: ".").compactMap { Int($0) }
        guard nums.count == 3 else { return nil }
        let pre = dashParts.count > 1 ? String(dashParts[1]) : nil
        return MacSemVer(major: nums[0], minor: nums[1], patch: nums[2], prerelease: pre)
    }

    public static func < (lhs: MacSemVer, rhs: MacSemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return false
        case (.some, nil): return true
        case (.some(let a), .some(let b)):
            return a.compare(b, options: .numeric) == .orderedAscending
        }
    }
}

public struct MacReleaseUpdate: Sendable, Equatable {
    public let version: MacSemVer
    public let releasePage: URL
    public let assetName: String
    public let downloadURL: URL
    public let size: Int64
    public let sha256Hex: String
}

/// Native macOS in-app updater mirroring `AppUpdateService` + `UpdateInstaller` (`AGENTS.md` #19).
/// Only builds tagged with `DropDrawerReleaseTag` matching `CFBundleShortVersionString` check for updates.
@Observable
@MainActor
public final class MacUpdateController {
    private static let autoCheckKey = "dd.mac.updates.autoCheck"
    private static let lastCheckKey = "dd.mac.updates.lastCheck"
    private static let releasesAPI = URL(string: "https://api.github.com/repos/StackTao/DropDrawer/releases?per_page=20")!
    public static let releasesPage = URL(string: "https://github.com/StackTao/DropDrawer/releases")!
    private static let allowedHosts: Set<String> = [
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
    ]
    private static let assetNames = ["DropDrawer-macOS-arm64.dmg", "DropDrawer-macOS.dmg"]

    public let installedVersion: MacSemVer?
    public let isReleaseBuild: Bool

    public var autoCheck: Bool
    public var phase: MacUpdatePhase = .idle
    public var update: MacReleaseUpdate?
    public var hasNewerForOtherPlatforms: Bool = false
    public var progress: Double?
    public var message: String?
    public var manualPackageURL: URL?
    public var dismissedBanner: Bool = false

    public var canUpdate: Bool { isReleaseBuild }
    public var busy: Bool { phase == .checking || phase == .downloading || phase == .installing }
    public var showBanner: Bool { !dismissedBanner && update != nil && canUpdate }

    public init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let baseRaw = info["CFBundleShortVersionString"] as? String ?? "0.1.1"
        let tagRaw = (info["DropDrawerReleaseTag"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = MacSemVer.parse(baseRaw)
        let tagged = MacSemVer.parse(tagRaw)
        if let base, let tagged,
           (tagged.major, tagged.minor, tagged.patch) == (base.major, base.minor, base.patch) {
            self.installedVersion = tagged
            self.isReleaseBuild = true
        } else {
            self.installedVersion = base
            self.isReleaseBuild = false
        }

        let ud = UserDefaults.standard
        if ud.object(forKey: Self.autoCheckKey) != nil {
            self.autoCheck = ud.bool(forKey: Self.autoCheckKey)
        } else {
            self.autoCheck = true
        }
    }

    public func setAutoCheck(_ enabled: Bool) {
        autoCheck = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoCheckKey)
    }

    public func dismissBanner() {
        dismissedBanner = true
    }

    public func checkIfDue() {
        guard canUpdate, autoCheck, !busy else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if last > 0 && Date().timeIntervalSince1970 - last < 86400 { return }
        Task { await check(silent: true) }
    }

    public func check(silent: Bool = false) async {
        guard canUpdate, let current = installedVersion, !busy else { return }
        phase = .checking
        message = nil
        progress = nil
        do {
            var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("DropDrawer/\(current)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw NSError(domain: "Update", code: -1)
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                phase = silent ? .idle : .failed
                message = "检查过于频繁，请稍后再试。"
                return
            }
            guard (200..<300).contains(http.statusCode),
                  let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                phase = silent ? .idle : .failed
                message = "无法获取更新信息。"
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

            var best: MacReleaseUpdate?
            var newerAny = false

            for rel in arr {
                if (rel["draft"] as? Bool) == true { continue }
                guard let tag = rel["tag_name"] as? String,
                      let ver = MacSemVer.parse(tag),
                      ver > current else { continue }
                newerAny = true
                guard let htmlStr = rel["html_url"] as? String,
                      let htmlURL = URL(string: htmlStr),
                      let assets = rel["assets"] as? [[String: Any]] else { continue }
                for wanted in Self.assetNames {
                    if let asset = assets.first(where: { ($0["name"] as? String) == wanted }),
                       let dlStr = asset["browser_download_url"] as? String,
                       let dlURL = URL(string: dlStr),
                       dlURL.scheme == "https",
                       let host = dlURL.host?.lowercased(),
                       Self.allowedHosts.contains(host),
                       let digest = asset["digest"] as? String,
                       digest.hasPrefix("sha256:"),
                       digest.count == 71 {
                        let hex = String(digest.dropFirst(7)).lowercased()
                        let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
                        let cand = MacReleaseUpdate(
                            version: ver,
                            releasePage: htmlURL,
                            assetName: wanted,
                            downloadURL: dlURL,
                            size: size,
                            sha256Hex: hex
                        )
                        if best == nil || cand.version > best!.version {
                            best = cand
                        }
                        break
                    }
                }
            }

            hasNewerForOtherPlatforms = newerAny && best == nil
            if let best {
                update = best
                dismissedBanner = false
                phase = .available
            } else {
                update = nil
                phase = .upToDate
            }
        } catch {
            phase = silent ? .idle : .failed
            message = "检查更新失败，请检查网络连接。"
        }
    }

    public func installUpdate() async {
        guard let target = update, !busy else { return }
        phase = .downloading
        progress = 0
        message = nil
        manualPackageURL = nil

        do {
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dropdrawer-updates", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let dmgURL = cacheDir.appendingPathComponent("\(target.version)-\(target.assetName)")

            let (bytes, resp) = try await URLSession.shared.bytes(from: target.downloadURL)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                phase = .failed
                message = "安装包下载失败，请重试。"
                return
            }
            let total = target.size > 0 ? target.size : resp.expectedContentLength
            let partURL = dmgURL.appendingPathExtension("part")
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partURL)
            var hasher = SHA256()
            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(65536)

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65536 {
                    try handle.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 { progress = min(Double(received) / Double(total), 1.0) }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                received += Int64(buffer.count)
            }
            try handle.close()

            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == target.sha256Hex else {
                try? FileManager.default.removeItem(at: partURL)
                phase = .failed
                message = "安装包校验失败，请重试。"
                return
            }
            try? FileManager.default.removeItem(at: dmgURL)
            try FileManager.default.moveItem(at: partURL, to: dmgURL)

            phase = .installing
            progress = nil
            let status = await Task.detached(priority: .userInitiated) {
                MacDMGInstaller.prepare(diskImage: dmgURL)
            }.value

            switch status {
            case "installing":
                NSApp.terminate(nil)
            case "not_writable":
                manualPackageURL = dmgURL
                phase = .failed
                message = "当前目录不可写，请手动打开安装包替换应用。"
            case "signature_mismatch":
                phase = .failed
                message = "安装包签名校验未通过，已中止安装。"
            default:
                manualPackageURL = dmgURL
                phase = .failed
                message = "自动安装失败，可手动打开安装包更新。"
            }
        } catch {
            phase = .failed
            message = "下载更新失败：\(error.localizedDescription)"
        }
    }

    public func openManualPackage() {
        if let url = manualPackageURL {
            MacPlatformServices.openFile(url)
        }
    }

    public func openReleasePage() {
        MacPlatformServices.openURL(update?.releasePage ?? Self.releasesPage)
    }

    public var statusDescription: String {
        if installedVersion == nil { return "正在读取版本…" }
        if !isReleaseBuild {
            return "开发版本（构建时未指定发布标签），不检查更新。"
        }
        switch phase {
        case .idle:
            return autoCheck ? "每天自动检查一次新版本。" : "已关闭自动检查。"
        case .checking:
            return "正在检查更新…"
        case .upToDate:
            return hasNewerForOtherPlatforms ? "已有新版本发布，但还没有这个平台的安装包。" : "已是最新版本。"
        case .available:
            return "新版本 \(update?.version.description ?? "") 可以更新。"
        case .downloading:
            let pct = Int(((progress ?? 0) * 100).rounded())
            return "正在下载并校验 \(pct)%…"
        case .installing:
            return "正在安装，DropDrawer 将自动重启。"
        case .failed:
            return message ?? "更新失败，请重试。"
        }
    }
}

// MARK: - Signed DMG Self-Updater (mirrors MainFlutterWindow UpdateInstaller)

private enum MacDMGInstaller {
    static func prepare(diskImage: URL) -> String {
        guard diskImage.pathExtension == "dmg",
              FileManager.default.fileExists(atPath: diskImage.path) else {
            return "unavailable"
        }
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: current.path) else {
            return "not_writable"
        }

        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropdrawer-update-mount-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            return "unavailable"
        }
        guard run("/usr/bin/hdiutil", ["attach", diskImage.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path]) else {
            try? FileManager.default.removeItem(at: mountPoint)
            return "unavailable"
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            return "unavailable"
        }
        guard satisfiesOwnRequirement(newApp) else { return "signature_mismatch" }

        let staged = parent.appendingPathComponent(".DropDrawer-update-\(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) else {
            try? FileManager.default.removeItem(at: staged)
            return "unavailable"
        }
        guard satisfiesOwnRequirement(staged), launchSwap(staged: staged, target: current) else {
            try? FileManager.default.removeItem(at: staged)
            return "unavailable"
        }
        return "installing"
    }

    private static func satisfiesOwnRequirement(_ app: URL) -> Bool {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess,
              let candidate else {
            return false
        }
        return SecStaticCodeCheckValidity(candidate, [], requirement) == errSecSuccess
    }

    private static func launchSwap(staged: URL, target: URL) -> Bool {
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(".DropDrawer-previous-\(UUID().uuidString).app")
        let script = """
          while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
          if /bin/mv "$3" "$4"; then
            if /bin/mv "$2" "$3"; then
              /bin/rm -rf "$4"
            else
              /bin/mv "$4" "$3"
              /bin/rm -rf "$2"
            fi
          else
            /bin/rm -rf "$2"
          fi
          /usr/bin/open "$3"
          """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "dropdrawer-update",
                            String(ProcessInfo.processInfo.processIdentifier),
                            staged.path, target.path, backup.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            return true
        } catch {
            return false
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - Slim In-Drawer Update Banner

struct MacUpdateBanner: View {
    @Bindable var updater: MacUpdateController

    var body: some View {
        if updater.showBanner, let update = updater.update {
            let actionable = updater.phase == .available || updater.phase == .failed
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: updater.phase == .failed ? "exclamationmark.circle" : "arrow.down.circle")
                        .font(.system(size: 13.5))
                        .foregroundStyle(updater.phase == .failed ? MacTheme.red : MacTheme.accent)

                    Text(bannerText(update))
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacTheme.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if updater.manualPackageURL != nil {
                        actionButton("打开安装包", strong: true) { updater.openManualPackage() }
                    } else if actionable {
                        actionButton(updater.phase == .failed ? "重试" : "更新", strong: true) {
                            Task { await updater.installUpdate() }
                        }
                    }
                    if actionable {
                        actionButton("稍后", strong: false) { updater.dismissBanner() }
                    }
                }

                if updater.phase == .downloading || updater.phase == .installing {
                    ProgressView(value: updater.phase == .downloading ? (updater.progress ?? 0) : nil)
                        .progressViewStyle(.linear)
                        .tint(MacTheme.accent)
                        .controlSize(.mini)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(MacTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(MacTheme.accent.opacity(0.35), lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private func bannerText(_ update: MacReleaseUpdate) -> String {
        switch updater.phase {
        case .downloading:
            return "正在下载 \(update.version) · \(Int(((updater.progress ?? 0) * 100).rounded()))%"
        case .installing:
            return "正在安装 \(update.version)，DropDrawer 将自动重启"
        case .failed:
            return updater.message ?? "更新失败"
        default:
            return "新版本 \(update.version) 可用"
        }
    }

    private func actionButton(_ label: String, strong: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: strong ? .semibold : .regular))
                .foregroundStyle(strong ? MacTheme.accent : MacTheme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 24)
        }
        .buttonStyle(.plain)
    }
}
