import Foundation

public struct UserProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let username: String
    public let email: String?

    public init(id: String, username: String, email: String? = nil) {
        self.id = id
        self.username = username
        self.email = email
    }
}

public struct AccountInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let username: String
    public let email: String?
    public let emailVerified: Bool
    public let hasPassword: Bool
    public let googleLinked: Bool
    public let emailBindingAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case email
        case emailVerified = "email_verified"
        case hasPassword = "has_password"
        case googleLinked = "google_linked"
        case emailBindingAvailable = "email_binding_available"
    }

    public init(
        id: String,
        username: String,
        email: String? = nil,
        emailVerified: Bool = false,
        hasPassword: Bool = true,
        googleLinked: Bool = false,
        emailBindingAvailable: Bool = false
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.emailVerified = emailVerified
        self.hasPassword = hasPassword
        self.googleLinked = googleLinked
        self.emailBindingAvailable = emailBindingAvailable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? true
        googleLinked = try c.decodeIfPresent(Bool.self, forKey: .googleLinked) ?? false
        emailBindingAvailable = try c.decodeIfPresent(Bool.self, forKey: .emailBindingAvailable) ?? false
    }
}

public struct AuthProviderInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let enabled: Bool

    public init(id: String, name: String, kind: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
    }
}

public struct AuthPublicConfig: Codable, Sendable, Equatable {
    public let registrationMode: String
    public let passwordLoginEnabled: Bool
    public let emailVerificationRequired: Bool
    public let emailPasswordResetEnabled: Bool
    public let providers: [AuthProviderInfo]

    enum CodingKeys: String, CodingKey {
        case registrationMode = "registration_mode"
        case passwordLoginEnabled = "password_login_enabled"
        case emailVerificationRequired = "email_verification_required"
        case emailPasswordResetEnabled = "email_password_reset_enabled"
        case providers
    }

    public init(
        registrationMode: String = "open",
        passwordLoginEnabled: Bool = true,
        emailVerificationRequired: Bool = false,
        emailPasswordResetEnabled: Bool = false,
        providers: [AuthProviderInfo] = []
    ) {
        self.registrationMode = registrationMode
        self.passwordLoginEnabled = passwordLoginEnabled
        self.emailVerificationRequired = emailVerificationRequired
        self.emailPasswordResetEnabled = emailPasswordResetEnabled
        self.providers = providers
    }

    public var registrationAllowed: Bool { registrationMode != "closed" }
    public var inviteCodeRequired: Bool { registrationMode == "invite_only" }
    public var googleEnabled: Bool { providers.contains { $0.id == "google" && $0.enabled } }
}

public struct DeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let userId: String
    public let name: String
    public let platform: String
    public let irohNodeId: String?
    public let irohRelayUrl: String?
    public let directAddrs: [String]
    public let online: Bool
    public let replicaItems: Set<String>

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case platform
        case irohNodeId = "iroh_node_id"
        case irohRelayUrl = "iroh_relay_url"
        case directAddrs = "direct_addrs"
        case online
        case replicaItems = "replica_items"
    }

    public init(
        id: String,
        userId: String,
        name: String,
        platform: String,
        irohNodeId: String? = nil,
        irohRelayUrl: String? = nil,
        directAddrs: [String] = [],
        online: Bool = false,
        replicaItems: Set<String> = []
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.platform = platform
        self.irohNodeId = irohNodeId
        self.irohRelayUrl = irohRelayUrl
        self.directAddrs = directAddrs
        self.online = online
        self.replicaItems = replicaItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decode(String.self, forKey: .name)
        platform = try c.decode(String.self, forKey: .platform)
        irohNodeId = try c.decodeIfPresent(String.self, forKey: .irohNodeId)
        irohRelayUrl = try c.decodeIfPresent(String.self, forKey: .irohRelayUrl)
        directAddrs = try c.decodeIfPresent([String].self, forKey: .directAddrs) ?? []
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        replicaItems = Set(try c.decodeIfPresent([String].self, forKey: .replicaItems) ?? [])
    }

    public var displayName: String {
        if name.lowercased().hasSuffix(".local") {
            return String(name.dropLast(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct DrawerItem: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let userId: String
    public let ownerDeviceId: String
    public var ownerDeviceName: String?
    public var ownerOnline: Bool
    public var ownerIrohNodeId: String?
    public var ownerIrohRelayUrl: String?
    public var ownerDirectAddrs: [String]
    public let kind: String // "file" | "text"
    public let name: String
    public let size: Int64
    public let mimeType: String?
    public let blake3Hash: String?
    public let textContent: String?
    public let thumbnailBase64: String?
    public let transferMode: String // "p2p_only" | "cloud_cached" | "hybrid"
    public let storageBackendId: String?
    public let storageBackendName: String?
    public let cloudReady: Bool
    public let expiresAt: Date?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case ownerDeviceId = "owner_device_id"
        case ownerDeviceName = "owner_device_name"
        case ownerOnline = "owner_online"
        case ownerIrohNodeId = "owner_iroh_node_id"
        case ownerIrohRelayUrl = "owner_iroh_relay_url"
        case ownerDirectAddrs = "owner_direct_addrs"
        case kind
        case name
        case size
        case mimeType = "mime_type"
        case blake3Hash = "blake3_hash"
        case textContent = "text_content"
        case thumbnailBase64 = "thumbnail_base64"
        case transferMode = "transfer_mode"
        case storageBackendId = "storage_backend_id"
        case storageBackendName = "storage_backend_name"
        case cloudReady = "cloud_ready"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        userId: String,
        ownerDeviceId: String,
        ownerDeviceName: String? = nil,
        ownerOnline: Bool = false,
        ownerIrohNodeId: String? = nil,
        ownerIrohRelayUrl: String? = nil,
        ownerDirectAddrs: [String] = [],
        kind: String = "file",
        name: String,
        size: Int64 = 0,
        mimeType: String? = nil,
        blake3Hash: String? = nil,
        textContent: String? = nil,
        thumbnailBase64: String? = nil,
        transferMode: String = "p2p_only",
        storageBackendId: String? = nil,
        storageBackendName: String? = nil,
        cloudReady: Bool = false,
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.ownerDeviceId = ownerDeviceId
        self.ownerDeviceName = ownerDeviceName
        self.ownerOnline = ownerOnline
        self.ownerIrohNodeId = ownerIrohNodeId
        self.ownerIrohRelayUrl = ownerIrohRelayUrl
        self.ownerDirectAddrs = ownerDirectAddrs
        self.kind = kind
        self.name = name
        self.size = size
        self.mimeType = mimeType
        self.blake3Hash = blake3Hash
        self.textContent = textContent
        self.thumbnailBase64 = thumbnailBase64
        self.transferMode = transferMode
        self.storageBackendId = storageBackendId
        self.storageBackendName = storageBackendName
        self.cloudReady = cloudReady
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        ownerDeviceId = try c.decode(String.self, forKey: .ownerDeviceId)
        ownerDeviceName = try c.decodeIfPresent(String.self, forKey: .ownerDeviceName)
        ownerOnline = try c.decodeIfPresent(Bool.self, forKey: .ownerOnline) ?? false
        ownerIrohNodeId = try c.decodeIfPresent(String.self, forKey: .ownerIrohNodeId)
        ownerIrohRelayUrl = try c.decodeIfPresent(String.self, forKey: .ownerIrohRelayUrl)
        ownerDirectAddrs = try c.decodeIfPresent([String].self, forKey: .ownerDirectAddrs) ?? []
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "file"
        name = try c.decode(String.self, forKey: .name)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        blake3Hash = try c.decodeIfPresent(String.self, forKey: .blake3Hash)
        textContent = try c.decodeIfPresent(String.self, forKey: .textContent)
        thumbnailBase64 = try c.decodeIfPresent(String.self, forKey: .thumbnailBase64)
        transferMode = try c.decodeIfPresent(String.self, forKey: .transferMode) ?? "p2p_only"
        storageBackendId = try c.decodeIfPresent(String.self, forKey: .storageBackendId)
        storageBackendName = try c.decodeIfPresent(String.self, forKey: .storageBackendName)
        cloudReady = try c.decodeIfPresent(Bool.self, forKey: .cloudReady) ?? false
        expiresAt = DateParsing.parse(try c.decodeIfPresent(String.self, forKey: .expiresAt))
        createdAt = DateParsing.parse(try c.decodeIfPresent(String.self, forKey: .createdAt)) ?? Date()
    }

    public var isText: Bool { kind == "text" }

    public var isImage: Bool {
        guard kind == "file" else { return false }
        if let mime = mimeType?.lowercased(), mime.hasPrefix("image/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "heic", "gif"].contains(ext)
    }

    public var isVideo: Bool {
        guard kind == "file" else { return false }
        if let mime = mimeType?.lowercased(), mime.hasPrefix("video/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "mkv", "webm"].contains(ext)
    }

    public var canSaveToPhotos: Bool { isImage || isVideo }

    public var canP2P: Bool {
        transferMode != "cloud_cached"
            && ownerOnline
            && (ownerIrohNodeId?.isEmpty == false)
    }

    public var cleanOwnerDeviceName: String? {
        guard let raw = ownerDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if raw.lowercased().hasSuffix(".local") {
            return String(raw.dropLast(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }
}

public struct StorageBackendSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let isDefault: Bool
    public let displayTarget: String

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case isDefault = "is_default"
        case displayTarget = "display_target"
    }

    public init(id: String, name: String, kind: String, isDefault: Bool, displayTarget: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
        self.displayTarget = displayTarget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        displayTarget = try c.decodeIfPresent(String.self, forKey: .displayTarget) ?? ""
    }

    public var kindDisplayName: String {
        switch kind {
        case "google_drive": "Google Drive"
        case "quark": String(localized: "夸克网盘", bundle: Bundle.module)
        case "baidu_netdisk": String(localized: "百度网盘", bundle: Bundle.module)
        case "s3": "S3 / R2"
        case "web_dav": "WebDAV"
        case "local": String(localized: "服务器本地盘", bundle: Bundle.module)
        default: kind
        }
    }
}

public struct P2PSourceInfo: Codable, Sendable, Equatable {
    public let deviceId: String
    public let irohNodeId: String
    public let irohRelayUrl: String?
    public let directAddrs: [String]
    public let transferToken: String
    public let replicaHash: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case irohNodeId = "iroh_node_id"
        case irohRelayUrl = "iroh_relay_url"
        case directAddrs = "direct_addrs"
        case transferToken = "transfer_token"
        case replicaHash = "replica_hash"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        irohNodeId = try c.decode(String.self, forKey: .irohNodeId)
        irohRelayUrl = try c.decodeIfPresent(String.self, forKey: .irohRelayUrl)
        directAddrs = try c.decodeIfPresent([String].self, forKey: .directAddrs) ?? []
        transferToken = try c.decode(String.self, forKey: .transferToken)
        replicaHash = try c.decodeIfPresent(String.self, forKey: .replicaHash)
    }
}

public struct CloudDownloadInfo: Codable, Sendable, Equatable {
    public let url: String
    public let isDirectUrl: Bool
    public let backendName: String

    enum CodingKeys: String, CodingKey {
        case url
        case isDirectUrl = "is_direct_url"
        case backendName = "backend_name"
    }

    public init(url: String, isDirectUrl: Bool, backendName: String) {
        self.url = url
        self.isDirectUrl = isDirectUrl
        self.backendName = backendName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        isDirectUrl = try c.decodeIfPresent(Bool.self, forKey: .isDirectUrl) ?? false
        backendName = try c.decodeIfPresent(String.self, forKey: .backendName) ?? "Cloud"
    }
}

public struct DownloadPlan: Codable, Sendable, Equatable {
    public let itemId: String
    public let p2p: P2PSourceInfo?
    public let cloud: CloudDownloadInfo?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case p2p
        case cloud
    }
}

public struct ShareLinkInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public let code: String
    public let itemId: String
    public let itemName: String
    public let itemKind: String
    public let itemSize: Int64
    public let itemCount: Int
    public let hasPasscode: Bool
    public let maxDownloads: Int?
    public let downloadCount: Int
    public let expiresAt: Date?
    public let createdAt: Date
    public let sharePath: String

    enum CodingKeys: String, CodingKey {
        case code
        case itemId = "item_id"
        case itemName = "item_name"
        case itemKind = "item_kind"
        case itemSize = "item_size"
        case itemCount = "item_count"
        case hasPasscode = "has_passcode"
        case maxDownloads = "max_downloads"
        case downloadCount = "download_count"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case sharePath = "share_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        itemId = try c.decode(String.self, forKey: .itemId)
        itemName = try c.decode(String.self, forKey: .itemName)
        itemKind = try c.decodeIfPresent(String.self, forKey: .itemKind) ?? "file"
        itemSize = try c.decodeIfPresent(Int64.self, forKey: .itemSize) ?? 0
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount) ?? 1
        hasPasscode = try c.decodeIfPresent(Bool.self, forKey: .hasPasscode) ?? false
        maxDownloads = try c.decodeIfPresent(Int.self, forKey: .maxDownloads)
        downloadCount = try c.decodeIfPresent(Int.self, forKey: .downloadCount) ?? 0
        expiresAt = DateParsing.parse(try c.decodeIfPresent(String.self, forKey: .expiresAt))
        createdAt = DateParsing.parse(try c.decodeIfPresent(String.self, forKey: .createdAt)) ?? Date()
        sharePath = try c.decode(String.self, forKey: .sharePath)
    }

    public var isExpired: Bool {
        if let expiresAt { return expiresAt < Date() }
        return false
    }

    public var isExhausted: Bool {
        if let maxDownloads { return downloadCount >= maxDownloads }
        return false
    }
}

public struct TransferProgress: Sendable, Equatable {
    public let itemId: String
    public let transferred: Int64
    public let total: Int64
    public let speedBps: Int64
    public let channel: String
    public let finished: Bool
    public let awaitingUploadConfirmation: Bool
    public let savedPath: String?
    public let sendingTo: String?
    public let error: String?

    public init(
        itemId: String,
        transferred: Int64,
        total: Int64,
        speedBps: Int64,
        channel: String,
        finished: Bool,
        awaitingUploadConfirmation: Bool = false,
        savedPath: String? = nil,
        sendingTo: String? = nil,
        error: String? = nil
    ) {
        self.itemId = itemId
        self.transferred = transferred
        self.total = total
        self.speedBps = speedBps
        self.channel = channel
        self.finished = finished
        self.awaitingUploadConfirmation = awaitingUploadConfirmation
        self.savedPath = savedPath
        self.sendingTo = sendingTo
        self.error = error
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(transferred) / Double(total), 0), 1)
    }

    public var indicatorValue: Double? {
        awaitingUploadConfirmation || fraction == 0 ? nil : fraction
    }

    public var channelLabel: String {
        switch channel {
        case "preparing": String(localized: "准备中", bundle: Bundle.module)
        case "p2p_connecting": String(localized: "P2P 连接中", bundle: Bundle.module)
        case "p2p_replica": String(localized: "局域网副本", bundle: Bundle.module)
        case "p2p_direct": String(localized: "P2P 直连", bundle: Bundle.module)
        case "p2p_relay": String(localized: "P2P 加密中继", bundle: Bundle.module)
        case "cloud": String(localized: "云端下载", bundle: Bundle.module)
        case "upload": awaitingUploadConfirmation ? String(localized: "等待存储确认…", bundle: Bundle.module) : String(localized: "正在发送文件", bundle: Bundle.module)
        case "cancelling": String(localized: "正在取消…", bundle: Bundle.module)
        default: channel
        }
    }
}

public struct PendingDrop: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

public enum DropPolicy: String, CaseIterable, Sendable, Identifiable {
    case smart = "smart"
    case p2pOnly = "p2p_only"
    case cloudCached = "cloud_cached"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smart: String(localized: "智能", bundle: Bundle.module)
        case .p2pOnly: String(localized: "纯 P2P", bundle: Bundle.module)
        case .cloudCached: String(localized: "存云盘", bundle: Bundle.module)
        }
    }
}

public enum ItemFilterKind: String, CaseIterable, Sendable, Identifiable {
    case all = "all"
    case file = "file"
    case text = "text"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: String(localized: "全部", bundle: Bundle.module)
        case .file: String(localized: "文件", bundle: Bundle.module)
        case .text: String(localized: "文本", bundle: Bundle.module)
        }
    }
}

public struct LocalNodeInfo: Codable, Sendable, Equatable {
    public let nodeId: String
    public let relayUrl: String?
    public let directAddrs: [String]
    public let readyFiles: [String: String]

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case relayUrl = "relay_url"
        case directAddrs = "direct_addrs"
        case readyFiles = "ready_files"
    }

    public init(
        nodeId: String,
        relayUrl: String? = nil,
        directAddrs: [String] = [],
        readyFiles: [String: String] = [:]
    ) {
        self.nodeId = nodeId
        self.relayUrl = relayUrl
        self.directAddrs = directAddrs
        self.readyFiles = readyFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        relayUrl = try c.decodeIfPresent(String.self, forKey: .relayUrl)
        directAddrs = try c.decodeIfPresent([String].self, forKey: .directAddrs) ?? []
        readyFiles = try c.decodeIfPresent([String: String].self, forKey: .readyFiles) ?? [:]
    }
}

public struct RegisteredP2PFile: Codable, Sendable, Equatable {
    public let itemId: String
    public let path: String
    public let size: Int64
    public let blake3Hash: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case path
        case size
        case blake3Hash = "blake3_hash"
    }
}

public enum DateParsing {
    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: value) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    public static func formatRelative(_ date: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 60 { return String(localized: "刚刚", bundle: Bundle.module) }
        if diff < 3600 { return String(localized: "\(Int(diff / 60)) 分钟前", bundle: Bundle.module, locale: AppLanguage.locale) }
        if diff < 86400 { return String(localized: "\(Int(diff / 3600)) 小时前", bundle: Bundle.module, locale: AppLanguage.locale) }
        let cal = Calendar.current
        if cal.isDateInYesterday(date) { return String(localized: "昨天", bundle: Bundle.module) }
        let fmt = DateFormatter()
        fmt.locale = AppLanguage.locale
        fmt.setLocalizedDateFormatFromTemplate(
            cal.component(.year, from: date) == cal.component(.year, from: now) ? "MMMd" : "yMMMd"
        )
        return fmt.string(from: date)
    }

    /// Date and time in the app language ("Mar 5, 2026 at 2:03 PM" / "2026年3月5日 14:03").
    public static func formatDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = AppLanguage.locale
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

public enum JSONValue: Encodable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    public var foundationValue: Any {
        switch self {
        case .string(let v): v
        case .bool(let v): v
        case .int(let v): v
        case .null: NSNull()
        }
    }
}

public func formatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    if bytes < 1024 * 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
    return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
}

// MARK: - Server policy (admin console)

/// Effective server switches for the signed-in account (`GET /api/client/config`).
/// Missing fields default to the permissive value so older servers keep working.
public struct ClientFeatures: Codable, Sendable, Equatable {
    public var shareCreateEnabled: Bool
    public var cloudUploadEnabled: Bool
    public var shareRequiresPasscode: Bool
    public var maxShareExpiresHours: Int?
    public var maxShareDownloads: Int?
    public var maxItemTtlHours: Int?
    /// Storage kinds (`"web_dav"`, `"s3"`, ...) the administrator disabled.
    public var disabledStorageKinds: [String]

    enum CodingKeys: String, CodingKey {
        case shareCreateEnabled = "share_create_enabled"
        case cloudUploadEnabled = "cloud_upload_enabled"
        case shareRequiresPasscode = "share_requires_passcode"
        case maxShareExpiresHours = "max_share_expires_hours"
        case maxShareDownloads = "max_share_downloads"
        case maxItemTtlHours = "max_item_ttl_hours"
        case disabledStorageKinds = "disabled_storage_kinds"
    }

    public init(
        shareCreateEnabled: Bool = true,
        cloudUploadEnabled: Bool = true,
        shareRequiresPasscode: Bool = false,
        maxShareExpiresHours: Int? = nil,
        maxShareDownloads: Int? = nil,
        maxItemTtlHours: Int? = nil,
        disabledStorageKinds: [String] = []
    ) {
        self.shareCreateEnabled = shareCreateEnabled
        self.cloudUploadEnabled = cloudUploadEnabled
        self.shareRequiresPasscode = shareRequiresPasscode
        self.maxShareExpiresHours = maxShareExpiresHours
        self.maxShareDownloads = maxShareDownloads
        self.maxItemTtlHours = maxItemTtlHours
        self.disabledStorageKinds = disabledStorageKinds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shareCreateEnabled = try c.decodeIfPresent(Bool.self, forKey: .shareCreateEnabled) ?? true
        cloudUploadEnabled = try c.decodeIfPresent(Bool.self, forKey: .cloudUploadEnabled) ?? true
        shareRequiresPasscode = try c.decodeIfPresent(Bool.self, forKey: .shareRequiresPasscode) ?? false
        maxShareExpiresHours = try c.decodeIfPresent(Int.self, forKey: .maxShareExpiresHours)
        maxShareDownloads = try c.decodeIfPresent(Int.self, forKey: .maxShareDownloads)
        maxItemTtlHours = try c.decodeIfPresent(Int.self, forKey: .maxItemTtlHours)
        disabledStorageKinds = try c.decodeIfPresent([String].self, forKey: .disabledStorageKinds) ?? []
    }
}

/// Server-wide announcement banner. `id` changes whenever the admin edits it.
public struct ClientAnnouncement: Codable, Sendable, Equatable {
    public let id: String
    /// `"info"` | `"warning"` | `"critical"`
    public let level: String
    public let title: String
    public let message: String

    public init(id: String, level: String = "info", title: String = "", message: String = "") {
        self.id = id
        self.level = level
        self.title = title
        self.message = message
    }
}

public struct ClientConfig: Codable, Sendable, Equatable {
    public var serverVersion: String
    public var features: ClientFeatures
    public var announcement: ClientAnnouncement?
    public var minClientVersion: String?

    enum CodingKeys: String, CodingKey {
        case serverVersion = "server_version"
        case features
        case announcement
        case minClientVersion = "min_client_version"
    }

    public init(
        serverVersion: String = "",
        features: ClientFeatures = ClientFeatures(),
        announcement: ClientAnnouncement? = nil,
        minClientVersion: String? = nil
    ) {
        self.serverVersion = serverVersion
        self.features = features
        self.announcement = announcement
        self.minClientVersion = minClientVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        features = try c.decodeIfPresent(ClientFeatures.self, forKey: .features) ?? ClientFeatures()
        announcement = try c.decodeIfPresent(ClientAnnouncement.self, forKey: .announcement)
        minClientVersion = try c.decodeIfPresent(String.self, forKey: .minClientVersion)
    }
}
