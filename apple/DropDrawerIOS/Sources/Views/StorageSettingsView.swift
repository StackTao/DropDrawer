import DropDrawerCore
import SwiftUI

private enum StorageKindOption: String, CaseIterable, Identifiable {
    case googleDrive = "google_drive"
    case quark = "quark"
    case baiduNetdisk = "baidu_netdisk"
    case s3 = "s3"
    case webDav = "web_dav"
    case local = "local"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .quark: "夸克网盘"
        case .baiduNetdisk: "百度网盘"
        case .s3: "S3 / R2"
        case .webDav: "WebDAV"
        case .local: "服务器本地盘"
        }
    }

    var defaultName: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .quark: "夸克网盘"
        case .baiduNetdisk: "百度网盘"
        case .s3: "S3 / Cloudflare R2"
        case .webDav: "WebDAV 网盘"
        case .local: "服务器本地盘"
        }
    }
}

struct StorageSettingsView: View {
    @Bindable var store: DropDrawerStore
    @Environment(\.openURL) private var openURL

    @State private var tab: Int = 0
    @State private var kind: StorageKindOption = .googleDrive
    @State private var name: String = "Google Drive"
    @State private var clientId: String = ""
    @State private var clientSecret: String = ""
    @State private var refreshToken: String = ""
    @State private var accessToken: String = ""
    @State private var cookie: String = ""
    @State private var endpointUrl: String = ""
    @State private var pathOrFolder: String = "root"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var region: String = "auto"
    @State private var bucket: String = "dropdrawer"
    @State private var isDefault: Bool = true

    @State private var saving: Bool = false
    @State private var switchingDefault = false
    @State private var feedback: (ok: Bool, text: String)?
    @State private var selectedBackend: StorageBackendSummary?
    @State private var editingBackend: StorageBackendSummary?

    var body: some View {
        List {
            Section {
                Picker("模式", selection: $tab) {
                    Text("已配置").tag(0)
                    Text("添加云盘").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if let feedback {
                Section {
                    Label(feedback.text, systemImage: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(feedback.ok ? Color.green : Color.red)
                }
            }

            if tab == 0 {
                configuredSection
            } else {
                addFormSections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("云盘与存储")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.refreshStorageBackends() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新存储列表")
            }
        }
        .refreshable {
            await store.refreshStorageBackends()
        }
        .task {
            await store.refreshStorageBackends()
        }
        .sheet(item: $editingBackend) { backend in
            StorageEditSheet(store: store, backend: backend)
        }
        .confirmationDialog(
            selectedBackend?.name ?? "存储策略",
            isPresented: Binding(
                get: { selectedBackend != nil },
                set: { if !$0 { selectedBackend = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let backend = selectedBackend {
                if !backend.isDefault {
                    Button("设为默认") {
                        Task { await setDefaultBackend(backend.id) }
                    }
                    .disabled(switchingDefault)
                }
                Button("编辑") {
                    editingBackend = backend
                }
                .disabled(switchingDefault)
                Button("测试连通性") {
                    Task { await testBackend(backend) }
                }
                Button("删除", role: .destructive) {
                    Task { await store.removeStorageBackend(id: backend.id) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var configuredSection: some View {
        Section {
            if store.storageBackends.isEmpty {
                Text("暂无云盘")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.storageBackends) { backend in
                    Button {
                        selectedBackend = backend
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "cloud.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backend.name)
                                    .foregroundStyle(.primary)
                                Text("\(backend.kindDisplayName) · \(backend.displayTarget)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if backend.isDefault {
                                Text("默认")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            Text(store.storageBackends.isEmpty
                 ? "还没有存储策略，切换到「添加云盘」直连配置。"
                 : "轻点存储项可编辑或设为默认。新上传至云端的文件会使用默认存储。")
        }
    }

    /// Kinds the server still allows adding (admin console storage policy).
    private var allowedKinds: [StorageKindOption] {
        StorageKindOption.allCases.filter { store.isStorageKindAllowed($0.rawValue) }
    }

    @ViewBuilder
    private var addFormSections: some View {
        if allowedKinds.isEmpty {
            Section {
                Text("服务器管理员已停用所有可添加的存储类型，暂时无法添加新的云盘。")
                    .foregroundStyle(.secondary)
            }
        } else {
            kindAndFieldSections
        }
    }

    @ViewBuilder
    private var kindAndFieldSections: some View {
        Section {
            Picker("类型", selection: $kind) {
                ForEach(allowedKinds) { option in
                    Text(option.label).tag(option)
                }
            }
            .onChange(of: kind) { _, newKind in
                applyDefaults(for: newKind)
            }
            .task(id: allowedKinds.map(\.rawValue)) {
                // Move off a kind the administrator has just disabled.
                if !allowedKinds.contains(kind), let first = allowedKinds.first {
                    kind = first
                }
            }
        }

        Section {
            formRow("名称", text: $name)
            switch kind {
            case .googleDrive:
                formRow("Client ID", text: $clientId, placeholder: "xxx.apps.googleusercontent.com")
                secureRow("Secret", text: $clientSecret, placeholder: "GOCSPX-...")
                formRow("Refresh", text: $refreshToken, placeholder: "可留空，用下方一键授权")
                formRow("目录 ID", text: $pathOrFolder, placeholder: "root")
            case .quark:
                formRow("Cookie", text: $cookie, placeholder: "pan.quark.cn 完整 Cookie")
                formRow("目录 fid", text: $pathOrFolder, placeholder: "0 表示根目录")
            case .baiduNetdisk:
                formRow("Token", text: $accessToken, placeholder: "Access Token")
                formRow("App Key", text: $clientId, placeholder: "可选")
                secureRow("Secret", text: $clientSecret)
                formRow("Refresh", text: $refreshToken, placeholder: "可选")
                formRow("路径", text: $pathOrFolder, placeholder: "/apps/dropdrawer")
            case .webDav:
                formRow("地址", text: $endpointUrl, placeholder: "https://dav.example.com/dropdrawer")
                formRow("用户名", text: $username)
                secureRow("密码", text: $password)
            case .s3:
                formRow("Endpoint", text: $endpointUrl, placeholder: "https://<account>.r2.cloudflarestorage.com")
                formRow("Bucket", text: $bucket)
                formRow("Region", text: $region)
                formRow("AccessKey", text: $username)
                secureRow("SecretKey", text: $password)
            case .local:
                EmptyView()
            }
            Toggle("设为默认存储", isOn: $isDefault)
        } footer: {
            if kind == .local {
                Text("文件保存在服务器数据目录中属于当前账号的独立文件夹。")
            }
        }

        Section {
            if kind == .googleDrive {
                Button {
                    Task { await launchGoogleOAuth() }
                } label: {
                    HStack {
                        Spacer()
                        Label("浏览器一键授权 Google Drive", systemImage: "safari")
                        Spacer()
                    }
                }
                .disabled(saving)
            }

            Button {
                Task { await saveBackend() }
            } label: {
                HStack {
                    Spacer()
                    if saving {
                        ProgressView()
                    } else {
                        Text("保存配置")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func formRow(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }

    private func secureRow(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        LabeledContent(label) {
            SecureField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func applyDefaults(for option: StorageKindOption) {
        feedback = nil
        name = option.defaultName
        switch option {
        case .googleDrive: pathOrFolder = "root"
        case .quark: pathOrFolder = "0"
        case .baiduNetdisk: pathOrFolder = "/apps/dropdrawer"
        case .s3:
            endpointUrl = "https://<account>.r2.cloudflarestorage.com"
            pathOrFolder = "dropdrawer"
        case .webDav:
            endpointUrl = "https://dav.example.com/dropdrawer"
        case .local:
            break
        }
    }

    private func testBackend(_ backend: StorageBackendSummary) async {
        do {
            let (ok, msg) = try await store.testStorageBackend(id: backend.id)
            feedback = (ok, ok ? "连通正常：\(msg)" : "连通失败：\(msg)")
        } catch {
            feedback = (false, "测试失败：\(error.localizedDescription)")
        }
    }

    private func setDefaultBackend(_ id: String) async {
        guard !switchingDefault else { return }
        switchingDefault = true
        feedback = nil
        defer { switchingDefault = false }
        do {
            try await store.setDefaultStorageBackend(id: id)
            feedback = (true, "已更新默认存储")
        } catch {
            feedback = (false, "切换默认存储失败：\(error.localizedDescription)")
        }
    }

    private func launchGoogleOAuth() async {
        guard !clientId.trimmingCharacters(in: .whitespaces).isEmpty,
              !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty else {
            feedback = (false, "请先填写 Google OAuth Client ID 和 Client Secret")
            return
        }
        saving = true
        defer { saving = false }
        do {
            let url = try await store.startGoogleDriveOAuth(
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Google Drive" : name.trimmingCharacters(in: .whitespaces),
                clientId: clientId.trimmingCharacters(in: .whitespaces),
                clientSecret: clientSecret.trimmingCharacters(in: .whitespaces),
                folderId: pathOrFolder.trimmingCharacters(in: .whitespaces).isEmpty ? "root" : pathOrFolder.trimmingCharacters(in: .whitespaces),
                isDefault: isDefault
            )
            openURL(url)
            feedback = (true, "已打开浏览器授权 Google Drive，同意后下拉刷新即可")
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
            switch kind {
            case .googleDrive:
                guard !refreshToken.trimmingCharacters(in: .whitespaces).isEmpty else {
                    feedback = (false, "请填写 Refresh Token，或点击上方「浏览器一键授权 Google Drive」")
                    return
                }
                cfg = [
                    "kind": .string("google_drive"),
                    "client_id": .string(clientId.trimmingCharacters(in: .whitespaces)),
                    "client_secret": .string(clientSecret.trimmingCharacters(in: .whitespaces)),
                    "refresh_token": .string(refreshToken.trimmingCharacters(in: .whitespaces)),
                    "folder_id": .string(pathOrFolder.trimmingCharacters(in: .whitespaces).isEmpty ? "root" : pathOrFolder.trimmingCharacters(in: .whitespaces)),
                ]
            case .quark:
                guard !cookie.trimmingCharacters(in: .whitespaces).isEmpty else {
                    feedback = (false, "请粘贴 pan.quark.cn 的 Cookie")
                    return
                }
                cfg = [
                    "kind": .string("quark"),
                    "cookie": .string(cookie.trimmingCharacters(in: .whitespaces)),
                    "root_folder_id": .string(pathOrFolder.trimmingCharacters(in: .whitespaces).isEmpty ? "0" : pathOrFolder.trimmingCharacters(in: .whitespaces)),
                ]
            case .baiduNetdisk:
                cfg = [
                    "kind": .string("baidu_netdisk"),
                    "client_id": .string(clientId.trimmingCharacters(in: .whitespaces)),
                    "client_secret": .string(clientSecret.trimmingCharacters(in: .whitespaces)),
                    "refresh_token": .string(refreshToken.trimmingCharacters(in: .whitespaces)),
                    "access_token": .string(accessToken.trimmingCharacters(in: .whitespaces)),
                    "root_path": .string(pathOrFolder.trimmingCharacters(in: .whitespaces).isEmpty ? "/apps/dropdrawer" : pathOrFolder.trimmingCharacters(in: .whitespaces)),
                ]
            case .webDav:
                cfg = [
                    "kind": .string("web_dav"),
                    "base_url": .string(endpointUrl.trimmingCharacters(in: .whitespaces)),
                    "username": .string(username.trimmingCharacters(in: .whitespaces)),
                    "password": .string(password),
                ]
            case .s3:
                cfg = [
                    "kind": .string("s3"),
                    "endpoint": .string(endpointUrl.trimmingCharacters(in: .whitespaces)),
                    "region": .string(region.trimmingCharacters(in: .whitespaces)),
                    "bucket": .string(bucket.trimmingCharacters(in: .whitespaces)),
                    "access_key_id": .string(username.trimmingCharacters(in: .whitespaces)),
                    "secret_access_key": .string(password),
                    "prefix": .string(pathOrFolder.trimmingCharacters(in: .whitespaces)),
                    "force_path_style": .bool(true),
                ]
            case .local:
                cfg = ["kind": .string("local"), "root_dir": .string("")]
            }
            try await store.addStorageBackend(
                name: name.trimmingCharacters(in: .whitespaces),
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


private struct StorageEditSheet: View {
    let store: DropDrawerStore
    let backend: StorageBackendSummary

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var capacity = ""
    @State private var initialCapacity: Int?
    @State private var credentials: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?

    private var isLocal: Bool { backend.kind == "local" }

    private var credentialFields: [(key: String, label: String)] {
        switch backend.kind {
        case "google_drive":
            [("client_secret", "Client Secret"), ("refresh_token", "Refresh Token")]
        case "quark":
            [("cookie", "Cookie")]
        case "baidu_netdisk":
            [("client_secret", "App Secret"), ("refresh_token", "Refresh Token"), ("access_token", "Access Token")]
        case "web_dav":
            [("password", "密码")]
        case "s3":
            [("access_key_id", "Access Key"), ("secret_access_key", "Secret Key")]
        default:
            []
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("存储位置", value: backend.displayTarget)
                    TextField("名称", text: $name)
                    if isLocal {
                        TextField("容量上限（字节）", text: $capacity)
                            .keyboardType(.numberPad)
                    }
                    ForEach(credentialFields, id: \.key) { field in
                        SecureField(field.label, text: Binding(
                            get: { credentials[field.key, default: ""] },
                            set: { credentials[field.key] = $0 }
                        ))
                    }
                } footer: {
                    Text(isLocal
                         ? "容量上限留空表示不限。"
                         : "留空保留现有凭据。更换存储位置可使用「添加云盘」。")
                }
                .disabled(loading || saving)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("编辑存储")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(loading || saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .task {
                name = backend.name
                do {
                    if isLocal, let maxBytes = try await store.getStorageCapacity(id: backend.id) {
                        initialCapacity = maxBytes
                        capacity = String(maxBytes)
                    }
                    loading = false
                } catch {
                    errorMessage = "无法读取存储配置：\(error.localizedDescription)"
                }
            }
        }
    }

    private func save() async {
        guard !saving else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "存储名称不能为空"
            return
        }
        var config: [String: JSONValue] = [:]
        for (key, value) in credentials {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                config[key] = .string(key == "password" ? value : trimmed)
            }
        }
        if isLocal {
            let value = capacity.trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = Int(value)
            if !value.isEmpty && (bytes ?? 0) <= 0 {
                errorMessage = "容量上限必须为正整数"
                return
            }
            if bytes != initialCapacity {
                config["max_bytes"] = bytes.map(JSONValue.int) ?? .null
            }
        }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try await store.updateStorageBackend(id: backend.id, name: trimmedName, config: config)
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
