import Foundation

public struct UserProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let username: String

    public init(id: String, username: String) {
        self.id = id
        self.username = username
    }
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
        case "quark": "夸克网盘"
        case "baidu_netdisk": "百度网盘"
        case "s3": "S3 / R2"
        case "web_dav": "WebDAV"
        case "local": "服务器本地盘"
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
        self.savedPath = savedPath
        self.sendingTo = sendingTo
        self.error = error
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(transferred) / Double(total), 0), 1)
    }

    public var channelLabel: String {
        switch channel {
        case "preparing": "准备中"
        case "p2p_connecting": "P2P 连接中"
        case "p2p_replica": "局域网副本"
        case "p2p_direct": "P2P 直连"
        case "p2p_relay": "P2P 加密中继"
        case "cloud": "云端下载"
        case "upload": "上传云盘"
        case "cancelling": "正在取消…"
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
        case .smart: "智能"
        case .p2pOnly: "纯 P2P"
        case .cloudCached: "存云盘"
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
        case .all: "全部"
        case .file: "文件"
        case .text: "文本"
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
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        let cal = Calendar.current
        if cal.isDateInYesterday(date) { return "昨天" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: now)
            ? "M月d日"
            : "yyyy年M月d日"
        return fmt.string(from: date)
    }

    public static func formatDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
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
