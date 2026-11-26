import DropDrawerCore
import SwiftUI

private enum StorageProviderKind: String, CaseIterable, Identifiable {
    case googleDrive = "google_drive"
    case quark = "quark"
    case baidu = "baidu_netdisk"
    case s3 = "s3"
    case webdav = "web_dav"
    case local = "local"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .quark: return "夸克网盘"
        case .baidu: return "百度网盘"
        case .s3: return "S3 / R2"
        case .webdav: return "WebDAV"
        case .local: return "本地盘"
        }
    }

    var defaultName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .quark: return "夸克网盘"
        case .baidu: return "百度网盘"
        case .s3: return "S3 / Cloudflare R2"
        case .webdav: return "WebDAV 网盘"
        case .local: return "服务器本地盘"
        }
    }
}

/// Full-width in-drawer storage management matching the exact two-tab
/// (`已配置云盘` / `添加原生云盘`) desktop layout — zero modal sheets.
public struct MacStorageSettingsView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController

    @State private var tab = 0
    @State private var provider: StorageProviderKind = .googleDrive
    @State private var name = "Google Drive"
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var refreshToken = ""
    @State private var accessToken = ""
    @State private var cookie = ""
    @State private var endpointUrl = ""
    @State private var pathOrFolder = "root"
    @State private var username = ""
    @State private var password = ""
    @State private var region = "auto"
    @State private var bucket = "dropdrawer"
    @State private var isDefault = true

    @State private var saving = false
    @State private var testingId: String?
    @State private var feedback: (ok: Bool, text: String)?

    public var body: some View {
        VStack(spacing: 0) {
            MacSubpageHeader(
                title: "原生云盘与存储",
                controller: controller,
                trailing: AnyView(
                    MacIconButton(symbol: "arrow.clockwise", size: 12.5, help: "刷新存储列表") {
                        Task { await store.refreshStorageBackends() }
                    }
                )
            )
            MacDivider()

            MacSegmentedControl(
                items: [(0, "已配置云盘"), (1, "添加原生云盘")],
                selected: tab
            ) { tab = $0 }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let feedback {
                Text(feedback.text)
                    .font(.system(size: 11))
                    .foregroundStyle(feedback.ok ? MacTheme.green : MacTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            ScrollView {
                Group {
                    if tab == 0 {
                        configuredList
                    } else {
                        addBackendForm
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
        }
        .task {
            await store.refreshStorageBackends()
        }
    }

    // MARK: - Tab 0: 已配置云盘

    @ViewBuilder
    private var configuredList: some View {
        if store.storageBackends.isEmpty {
            Text("暂无存储策略，点击上方「添加原生云盘」直连配置")
                .font(.system(size: 12))
                .foregroundStyle(MacTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                MacGroupedCard {
                    ForEach(Array(store.storageBackends.enumerated()), id: \.element.id) { idx, backend in
                        if idx > 0 { MacDivider(indent: 12) }
                        backendRow(backend)
                    }
                }
                Text("全部云盘均由服务端原生直连，无需部署 Alist / OpenList 等第三方服务。")
                    .font(.system(size: 11))
                    .foregroundStyle(MacTheme.textTertiary)
                    .lineSpacing(3)
            }
        }
    }

    private func backendRow(_ backend: StorageBackendSummary) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(backend.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                        .lineLimit(1)
                    if backend.isDefault {
                        Text("默认")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(MacTheme.green)
                    }
                }
                Text(backend.displayTarget.isEmpty ? backend.kindDisplayName : "\(backend.kindDisplayName) · \(backend.displayTarget)")
                    .font(.system(size: 11))
                    .foregroundStyle(MacTheme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if testingId == backend.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                MacIconButton(symbol: "waveform.path", size: 13.5, help: "测试连通性") {
                    testingId = backend.id
                    Task {
                        do {
                            let (ok, msg) = try await store.testStorageBackend(id: backend.id)
                            feedback = (ok, ok ? "连通正常：\(msg)" : "连通失败：\(msg)")
                        } catch {
                            feedback = (false, "测试失败：\(error.localizedDescription)")
                        }
                        testingId = nil
                    }
                }
            }

            MacIconButton(symbol: "trash", size: 13, help: "删除") {
                Task { await store.removeStorageBackend(id: backend.id) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Tab 1: 添加原生云盘

    private var addBackendForm: some View {
        let callbackURL = "\(store.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression))/api/oauth/google/callback"

        return VStack(alignment: .leading, spacing: 10) {
            MacFlowLayout(spacing: 6, runSpacing: 6) {
                ForEach(StorageProviderKind.allCases) { option in
                    let selected = provider == option
                    Button {
                        selectProvider(option)
                    } label: {
                        Text(option.label)
                            .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? MacTheme.textPrimary : MacTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected ? MacTheme.fill(0.18) : MacTheme.group(0.24))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(selected ? MacTheme.strongHairline : MacTheme.hairline, lineWidth: 0.7)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            MacGroupedCard(alpha: 0.24) {
                MacFormRow(label: "名称", placeholder: provider.defaultName, text: $name, labelWidth: 58)

                switch provider {
                case .googleDrive:
                    MacDivider(indent: 12)
                    MacFormRow(label: "Client ID", placeholder: "xxx.apps.googleusercontent.com", text: $clientId, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "Secret", placeholder: "GOCSPX-...", text: $clientSecret, secure: true, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "Refresh", placeholder: "可留空，点下方一键授权自动获取", text: $refreshToken, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "目录 ID", placeholder: "root", text: $pathOrFolder, labelWidth: 58)
                case .quark:
                    MacDivider(indent: 12)
                    MacFormRow(label: "Cookie", placeholder: "pan.quark.cn 完整 Cookie", text: $cookie, secure: true, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "目录 fid", placeholder: "0 表示根目录", text: $pathOrFolder, labelWidth: 58)
                case .baidu:
                    MacDivider(indent: 12)
                    MacFormRow(label: "Token", placeholder: "Access Token", text: $accessToken, secure: true, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "App Key", placeholder: "可选", text: $clientId, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "Secret", placeholder: "可选", text: $clientSecret, secure: true, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "Refresh", placeholder: "可选", text: $refreshToken, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "路径", placeholder: "/apps/dropdrawer", text: $pathOrFolder, labelWidth: 58)
                case .s3:
                    MacDivider(indent: 12)
                    MacFormRow(label: "Endpoint", placeholder: "https://<account>.r2.cloudflarestorage.com", text: $endpointUrl, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "Bucket", placeholder: "dropdrawer", text: $bucket, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "Region", placeholder: "auto", text: $region, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "AccessKey", placeholder: "Access Key ID", text: $username, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "SecretKey", placeholder: "Secret Access Key", text: $password, secure: true, labelWidth: 58)
                case .webdav:
                    MacDivider(indent: 12)
                    MacFormRow(label: "地址", placeholder: "https://dav.example.com/dropdrawer", text: $endpointUrl, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "用户名", placeholder: "可选", text: $username, labelWidth: 58)
                    MacDivider(indent: 12)
                    MacFormRow(label: "密码", placeholder: "可选", text: $password, secure: true, labelWidth: 58)
                case .local:
                    MacDivider(indent: 12)
                    Text("文件保存在服务器数据目录中属于当前账号的独立文件夹。")
                        .font(.system(size: 11))
                        .foregroundStyle(MacTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }

            // Switch sits outside the form card with green active tint (1:1 with desktop)
            HStack {
                Text("设为默认中转存储")
                    .font(.system(size: 12))
                    .foregroundStyle(MacTheme.textSecondary)
                Spacer()
                Toggle("", isOn: $isDefault)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(MacTheme.green)
                    .labelsHidden()
            }
            .padding(.top, 2)

            if provider == .googleDrive {
                VStack(alignment: .leading, spacing: 6) {
                    MacPrimaryButton(
                        title: "浏览器一键授权 Google Drive",
                        symbol: "globe",
                        loading: saving,
                        height: 36
                    ) {
                        Task { await launchGoogleOAuth() }
                    }

                    Text("回调地址请填：\(callbackURL)")
                        .font(.system(size: 10))
                        .foregroundStyle(MacTheme.textTertiary)
                        .textSelection(.enabled)

                    MacSecondaryButton(
                        title: "已有 Refresh Token？直接保存",
                        height: 32,
                        disabled: saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        Task { await saveBackend() }
                    }
                    .padding(.top, 2)
                }
            } else {
                MacPrimaryButton(
                    title: "保存原生云盘配置",
                    loading: saving,
                    disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    height: 36
                ) {
                    Task { await saveBackend() }
                }
            }
        }
    }

    private func selectProvider(_ next: StorageProviderKind) {
        provider = next
        feedback = nil
        name = next.defaultName
        switch next {
        case .googleDrive: pathOrFolder = "root"
        case .quark: pathOrFolder = "0"
        case .baidu: pathOrFolder = "/apps/dropdrawer"
        case .s3:
            endpointUrl = "https://<account>.r2.cloudflarestorage.com"
            pathOrFolder = "dropdrawer"
        case .webdav:
            endpointUrl = "https://dav.example.com/dropdrawer"
        case .local:
            break
        }
    }

    private func launchGoogleOAuth() async {
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty, !sec.isEmpty else {
            feedback = (false, "请先填写 Google OAuth Client ID 和 Client Secret")
            return
        }
        saving = true
        defer { saving = false }
        do {
            let url = try await store.startGoogleDriveOAuth(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Google Drive" : name.trimmingCharacters(in: .whitespacesAndNewlines),
                clientId: cid,
                clientSecret: sec,
                folderId: pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines),
                isDefault: isDefault
            )
            MacPlatformServices.openURL(url)
            feedback = (true, "已打开浏览器授权 Google Drive，同意后点右上角「刷新」即可")
            tab = 0
        } catch {
            feedback = (false, "发起授权失败：\(error.localizedDescription)")
        }
    }

    private func saveBackend() async {
        saving = true
        feedback = nil
        defer { saving = false }
        do {
            let cfg: [String: JSONValue]
            switch provider {
            case .googleDrive:
                let rt = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rt.isEmpty else {
                    feedback = (false, "请填写 Refresh Token，或点击上方「浏览器一键授权 Google Drive」")
                    return
                }
                cfg = [
                    "kind": .string("google_drive"),
                    "client_id": .string(clientId.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "client_secret": .string(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "refresh_token": .string(rt),
                    "folder_id": .string(pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines)),
                ]
            case .quark:
                let ck = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ck.isEmpty else {
                    feedback = (false, "请粘贴 pan.quark.cn 的 Cookie")
                    return
                }
                cfg = [
                    "kind": .string("quark"),
                    "cookie": .string(ck),
                    "root_folder_id": .string(pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0" : pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines)),
                ]
            case .baidu:
                cfg = [
                    "kind": .string("baidu_netdisk"),
                    "client_id": .string(clientId.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "client_secret": .string(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "refresh_token": .string(refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "access_token": .string(accessToken.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "root_path": .string(pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/apps/dropdrawer" : pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines)),
                ]
            case .webdav:
                cfg = [
                    "kind": .string("web_dav"),
                    "base_url": .string(endpointUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "username": .string(username.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "password": .string(password),
                ]
            case .s3:
                cfg = [
                    "kind": .string("s3"),
                    "endpoint": .string(endpointUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "region": .string(region.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "bucket": .string(bucket.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "access_key_id": .string(username.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "secret_access_key": .string(password),
                    "prefix": .string(pathOrFolder.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "force_path_style": .bool(true),
                ]
            case .local:
                cfg = ["kind": .string("local"), "root_dir": .string("")]
            }
            try await store.addStorageBackend(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                config: cfg,
                isDefault: isDefault
            )
            feedback = (true, "已保存原生云盘策略")
            tab = 0
        } catch {
            feedback = (false, "保存失败：\(error.localizedDescription)")
        }
    }
}
