import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
public final class DropDrawerStore {
    // MARK: - Published state

    public var serverUrl: String
    public var user: UserProfile?
    public var deviceId: String?
    public var devices: [DeviceInfo] = []
    public var items: [DrawerItem] = []
    public var pendingDrops: [PendingDrop] = []
    public var shareLinks: [ShareLinkInfo] = []
    public var storageBackends: [StorageBackendSummary] = []
    private var storageRevision = 0

    public var wsConnected: Bool = false
    public var p2pReady: Bool = false
    public var localNodeInfo: LocalNodeInfo?

    public var activeTransfers: [String: TransferProgress] = [:]
    public var outgoingTransfers: [String: TransferProgress] = [:]
    public var localFilePaths: [String: String] = [:]

    public var dropPolicy: DropPolicy
    public var autoCloudThresholdMb: Int
    public var defaultTtlHours: Int

    public var toastMessage: String?
    public var authLoading: Bool = false
    public var authError: String?

    public var isLoggedIn: Bool { user != nil && api?.token != nil }

    // MARK: - Internal state

    private let storage: SessionStorage
    private let p2p: P2PBridge
    private var api: APIClient?

    private var wsTask: URLSessionWebSocketTask?
    private var wsLoopTask: Task<Void, Never>?
    private var wsPingTask: Task<Void, Never>?
    private var nodeAddrTask: Task<Void, Never>?
    private var p2pPollTask: Task<Void, Never>?
    private var toastClearTask: Task<Void, Never>?

    private var publishedFiles: [String: String] = [:]
    private var p2pDownloadIds: [String: String] = [:]
    private var replicaDownloads: Set<String> = []
    private var cancellingSends: Set<String> = []
    private var activeCancelTokens: [String: TransferCancelToken] = [:]
    private var thumbnailCache: [String: Data] = [:]

    public init(
        storage: SessionStorage = SessionStorage(),
        p2p: P2PBridge = P2PBridge()
    ) {
        self.storage = storage
        self.p2p = p2p
        self.serverUrl = storage.serverUrl
        self.user = storage.user
        self.deviceId = storage.deviceId
        self.dropPolicy = storage.dropPolicy
        self.autoCloudThresholdMb = storage.autoCloudThresholdMb
        self.defaultTtlHours = storage.defaultTtlHours
        self.localFilePaths = storage.localFilePaths
    }

    // MARK: - Computed helpers

    public var onlineDeviceCount: Int {
        max(devices.filter(\.online).count, wsConnected ? 1 : 0)
    }

    public var defaultStorageBackendName: String {
        storageBackends.first(where: \.isDefault)?.name
            ?? storageBackends.first?.name
            ?? "云盘"
    }

    public func canDownloadP2P(_ item: DrawerItem) -> Bool {
        if item.canP2P { return true }
        return devices.contains {
            $0.id != deviceId && $0.online && $0.replicaItems.contains(item.id)
        }
    }

    public func localFileURL(for itemId: String) -> URL? {
        guard let path = localFilePaths[itemId],
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    public func buildFullShareURL(_ sharePath: String) -> String {
        let base = (api?.cleanBase ?? serverUrl)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return "\(base)\(sharePath)"
    }

    public func privacyNoticeURL() -> URL? {
        let base = serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return URL(string: "\(base)/privacy")
    }

    public func thumbnailData(for item: DrawerItem) -> Data? {
        if let cached = thumbnailCache[item.id] { return cached }
        guard let b64 = item.thumbnailBase64, !b64.isEmpty,
              let data = Data(base64Encoded: b64)
        else { return nil }
        thumbnailCache[item.id] = data
        return data
    }

    public func showToast(_ message: String) {
        toastMessage = message
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - Lifecycle & Auth

    public func bootstrap() async {
        guard let token = storage.token, !token.isEmpty, storage.user != nil else {
            return
        }
        api = APIClient(baseUrl: serverUrl, token: token)
        await finishSignInSetup()
    }

    public func login(server: String, username: String, password: String, register: Bool) async {
        authLoading = true
        authError = nil
        defer { authLoading = false }
        let cleaned = server.trimmingCharacters(in: .whitespacesAndNewlines)
        serverUrl = cleaned
        storage.serverUrl = cleaned
        let client = APIClient(baseUrl: cleaned)
        do {
            let auth = register
                ? try await client.register(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                : try await client.login(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            applyAuth(client: client, auth: auth)
            await finishSignInSetup()
        } catch {
            authError = error.localizedDescription
        }
    }

    public func startGoogleSignIn(server: String) async throws -> GoogleSignInStart {
        let cleaned = server.trimmingCharacters(in: .whitespacesAndNewlines)
        serverUrl = cleaned
        storage.serverUrl = cleaned
        let client = APIClient(baseUrl: cleaned)
        return try await client.startGoogleSignIn()
    }

    public func completeGoogleSignIn(start: GoogleSignInStart) async {
        authLoading = true
        authError = nil
        defer { authLoading = false }
        let client = APIClient(baseUrl: serverUrl)
        let deadline = Date().addingTimeInterval(TimeInterval(max(30, min(start.expiresIn, 300))))
        while Date() < deadline && !Task.isCancelled {
            do {
                if let auth = try await client.pollGoogleSignIn(state: start.state, pollKey: start.pollKey) {
                    applyAuth(client: client, auth: auth)
                    await finishSignInSetup()
                    return
                }
            } catch {
                authError = error.localizedDescription
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
        if authError == nil && !isLoggedIn {
            authError = "Google 登录已超时，请重试。"
        }
    }

    private func applyAuth(client: APIClient, auth: AuthResult) {
        api = client
        user = auth.user
        storage.token = auth.token
        storage.user = auth.user
    }

    private func finishSignInSetup() async {
        startP2P()
        await registerCurrentDevice()
        await refreshAll()
        connectWebSocket()
        await consumeSharedAppGroupQueue()
    }

    public func logout() {
        stopBackgroundTasks()
        p2p.shutdown()
        p2pReady = false
        localNodeInfo = nil
        api = nil
        user = nil
        deviceId = nil
        devices = []
        items = []
        shareLinks = []
        storageBackends = []
        activeTransfers = [:]
        outgoingTransfers = [:]
        p2pDownloadIds = [:]
        replicaDownloads = []
        cancellingSends = []
        activeCancelTokens = [:]
        localFilePaths = [:]
        wsConnected = false
        storage.clearSession()
    }

    public func handleSceneActive() async {
        guard isLoggedIn else { return }
        if !wsConnected {
            connectWebSocket()
        }
        await refreshAll()
        await consumeSharedAppGroupQueue()
    }

    // MARK: - Settings

    public func setDropPolicy(_ policy: DropPolicy) {
        dropPolicy = policy
        storage.dropPolicy = policy
    }

    public func setAutoCloudThresholdMb(_ mb: Int) {
        autoCloudThresholdMb = mb
        storage.autoCloudThresholdMb = mb
    }

    public func setDefaultTtlHours(_ hours: Int) {
        defaultTtlHours = hours
        storage.defaultTtlHours = hours
    }

    // MARK: - Refresh & Device Registration

    private func currentDeviceNameAndPlatform() -> (String, String) {
        #if os(iOS)
        return (UIDevice.current.name, "ios")
        #elseif os(macOS)
        return (Host.current().localizedName ?? "Mac", "macos")
        #else
        return ("Apple Device", "ios")
        #endif
    }

    private func registerCurrentDevice() async {
        guard let api else { return }
        let (name, platform) = currentDeviceNameAndPlatform()
        do {
            let info = try await api.registerDevice(
                deviceId: deviceId,
                name: name,
                platform: platform,
                irohNodeId: localNodeInfo?.nodeId,
                irohRelayUrl: localNodeInfo?.relayUrl,
                directAddrs: localNodeInfo?.directAddrs ?? []
            )
            deviceId = info.id
            storage.deviceId = info.id
        } catch {
            showToast("设备注册失败：\(error.localizedDescription)")
        }
    }

    public func refreshAll() async {
        guard let api else { return }
        async let fetchedItems = api.listItems()
        async let fetchedDevices = api.listDevices()
        async let refreshedBackends: Void = refreshStorageBackends()
        async let fetchedShares = api.listShareLinks()

        if let list = try? await fetchedItems { items = list }
        if let devs = try? await fetchedDevices { devices = devs }
        await refreshedBackends
        if let links = try? await fetchedShares { shareLinks = links }
        reRegisterLocalFilesForP2P()
    }

    public func refreshShareLinks() async {
        guard let api else { return }
        if let links = try? await api.listShareLinks() {
            shareLinks = links
        }
    }

    public func refreshStorageBackends() async {
        guard let api else { return }
        storageRevision += 1
        let revision = storageRevision
        if let backends = try? await api.listStorageBackends(),
           self.api === api, storageRevision == revision {
            storageBackends = backends
        }
    }

    // MARK: - P2P Lifecycle

    private func p2pDataDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DropDrawerP2P", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func downloadsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("DropDrawer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func startP2P() {
        guard !p2pReady else { return }
        do {
            let info = try p2p.start(dataDir: p2pDataDirectory().path)
            localNodeInfo = info
            p2pReady = true
            startP2PPoller()
        } catch {
            p2pReady = false
        }
    }

    private func reRegisterLocalFilesForP2P() {
        guard p2pReady else { return }
        let visibleIds = Set(items.map(\.id))
        var pruned = localFilePaths
        for (itemId, path) in localFilePaths {
            if !visibleIds.contains(itemId) || !FileManager.default.fileExists(atPath: path) {
                pruned.removeValue(forKey: itemId)
                continue
            }
            _ = try? p2p.registerFile(itemId: itemId, path: path)
        }
        if pruned != localFilePaths {
            localFilePaths = pruned
            storage.localFilePaths = pruned
        }
    }

    private func startP2PPoller() {
        p2pPollTask?.cancel()
        p2pPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, self.p2pReady else { continue }
                self.pollP2PEvents()
            }
        }
    }

    private func pollP2PEvents() {
        guard p2pReady, let events = try? p2p.pollEvents(), !events.isEmpty else { return }
        for ev in events {
            let channel: String = switch ev.pathKind {
            case "direct" where ev.sendingTo == nil && replicaDownloads.contains(ev.itemId):
                "p2p_replica"
            case "direct":
                "p2p_direct"
            case "relay":
                "p2p_relay"
            default:
                "p2p_connecting"
            }
            let progress = TransferProgress(
                itemId: ev.itemId,
                transferred: ev.bytesTransferred,
                total: ev.totalBytes,
                speedBps: ev.speedBps,
                channel: channel,
                finished: ev.finished,
                savedPath: ev.savedPath,
                sendingTo: ev.sendingTo,
                error: ev.error
            )

            if ev.sendingTo != nil {
                if ev.finished {
                    let wasCancelling = cancellingSends.remove(ev.transferId) != nil
                    outgoingTransfers.removeValue(forKey: ev.transferId)
                    if ev.cancelled {
                        showToast("已取消发送")
                    } else if let err = ev.error {
                        showToast("P2P 发送失败：\(err)")
                    } else if wasCancelling {
                        showToast("发送已完成")
                    }
                } else {
                    outgoingTransfers[ev.transferId] = progress
                }
                continue
            }

            // Keep transfer IDs intact until native reports terminal event (`AGENTS.md` #6).
            guard p2pDownloadIds[ev.itemId] == ev.transferId else { continue }
            let token = activeCancelTokens[ev.itemId]
            let wasReplica = ev.finished && replicaDownloads.remove(ev.itemId) != nil
            if ev.finished {
                p2pDownloadIds.removeValue(forKey: ev.itemId)
                activeCancelTokens.removeValue(forKey: ev.itemId)
            }
            if ev.cancelled {
                activeTransfers.removeValue(forKey: ev.itemId)
                showToast("已取消下载")
                continue
            }
            activeTransfers[ev.itemId] = progress
            if let saved = ev.savedPath {
                localFilePaths[ev.itemId] = saved
                storage.localFilePaths = localFilePaths
                _ = try? p2p.registerFile(itemId: ev.itemId, path: saved)
            }
            if ev.finished, ev.error != nil {
                if let item = items.first(where: { $0.id == ev.itemId }), token?.isCancelled != true {
                    if wasReplica {
                        Task { await downloadItem(item, preferReplica: false) }
                    } else if item.cloudReady {
                        Task { await downloadItem(item, cloudOnly: true) }
                    } else {
                        showToast("下载失败：\(ev.error ?? "")")
                    }
                }
            } else if ev.finished, ev.savedPath != nil {
                let transport = switch channel {
                case "p2p_replica": "局域网副本"
                case "p2p_direct": "P2P 直连"
                case "p2p_relay": "P2P 加密中继"
                default: "P2P"
                }
                showToast("已通过\(transport)下载完成")
                activeTransfers.removeValue(forKey: ev.itemId)
            }
        }
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        guard let api, let deviceId, wsTask == nil else { return }
        guard let task = try? api.makeWebSocketTask(deviceId: deviceId) else { return }
        wsTask = task
        task.resume()
        wsConnected = true

        wsPingTask?.cancel()
        wsPingTask = Task { [weak self, weak task] in
            while !Task.isCancelled, let task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { break }
                task.sendPing { [weak self] err in
                    if err != nil {
                        Task { @MainActor in self?.handleWSDisconnect(task) }
                    }
                }
            }
        }

        nodeAddrTask?.cancel()
        nodeAddrTask = Task { [weak self, weak task] in
            if let self, let task { self.publishNodeAddress(task: task, force: true) }
            while !Task.isCancelled, let task {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { break }
                self.publishNodeAddress(task: task, force: false)
            }
        }

        wsLoopTask?.cancel()
        wsLoopTask = Task { [weak self, weak task] in
            while !Task.isCancelled, let task {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self?.handleWSMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self?.handleWSMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    self?.handleWSDisconnect(task)
                    return
                }
            }
        }
    }

    private func handleWSDisconnect(_ task: URLSessionWebSocketTask) {
        guard wsTask === task else { return }
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsPingTask?.cancel()
        nodeAddrTask?.cancel()
        wsConnected = false
        guard isLoggedIn else { return }
        wsLoopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.connectWebSocket()
        }
    }

    private func stopBackgroundTasks() {
        wsLoopTask?.cancel()
        wsPingTask?.cancel()
        nodeAddrTask?.cancel()
        p2pPollTask?.cancel()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
    }

    private func publishNodeAddress(task: URLSessionWebSocketTask, force: Bool) {
        guard p2pReady, wsTask === task, let info = try? p2p.nodeInfo() else { return }
        let visibleIds = Set(items.map(\.id))
        let readyFiles = info.readyFiles.filter { visibleIds.contains($0.key) }
        if force || readyFiles != publishedFiles {
            sendWSJSON(task: task, type: "update_ready_files", payload: ["files": readyFiles])
            publishedFiles = readyFiles
        }
        let unchanged = localNodeInfo?.nodeId == info.nodeId
            && localNodeInfo?.relayUrl == info.relayUrl
            && localNodeInfo?.directAddrs == info.directAddrs
        if !force && unchanged { return }
        sendWSJSON(
            task: task,
            type: "update_node_addr",
            payload: [
                "iroh_node_id": info.nodeId,
                "iroh_relay_url": info.relayUrl ?? NSNull(),
                "direct_addrs": info.directAddrs,
            ]
        )
        localNodeInfo = info
    }

    private func sendWSJSON(task: URLSessionWebSocketTask, type: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { _ in }
    }

    /// Exposed internally for unit testing WebSocket state reduction.
    public func handleWSMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String
        else { return }
        let payload = root["payload"]

        switch type {
        case "snapshot":
            guard let dict = payload as? [String: Any] else { return }
            if let devsObj = dict["devices"],
               let devsData = try? JSONSerialization.data(withJSONObject: devsObj),
               let parsed = try? JSONDecoder().decode([DeviceInfo].self, from: devsData) {
                devices = parsed
            }
            if let itemsObj = dict["items"],
               let itemsData = try? JSONSerialization.data(withJSONObject: itemsObj),
               let parsed = try? JSONDecoder().decode([DrawerItem].self, from: itemsData) {
                items = parsed
            }
        case "device_updated":
            guard let payload,
                  let pData = try? JSONSerialization.data(withJSONObject: payload),
                  let dev = try? JSONDecoder().decode(DeviceInfo.self, from: pData)
            else { return }
            if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
                devices[idx] = dev
            } else {
                devices.insert(dev, at: 0)
            }
            items = items.map { item in
                guard item.ownerDeviceId == dev.id else { return item }
                var copy = item
                copy.ownerDeviceName = dev.name
                copy.ownerOnline = dev.online
                copy.ownerIrohNodeId = dev.irohNodeId
                copy.ownerIrohRelayUrl = dev.irohRelayUrl
                copy.ownerDirectAddrs = dev.directAddrs
                return copy
            }
        case "item_added":
            guard let payload,
                  let pData = try? JSONSerialization.data(withJSONObject: payload),
                  let item = try? JSONDecoder().decode(DrawerItem.self, from: pData)
            else { return }
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
        case "item_updated":
            guard let payload,
                  let pData = try? JSONSerialization.data(withJSONObject: payload),
                  let item = try? JSONDecoder().decode(DrawerItem.self, from: pData)
            else { return }
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = item
            } else {
                items.insert(item, at: 0)
            }
        case "item_deleted":
            guard let dict = payload as? [String: Any],
                  let itemId = dict["item_id"] as? String
            else { return }
            items.removeAll { $0.id == itemId }
            if p2pReady { _ = try? p2p.unregisterFile(itemId: itemId) }
        case "authorize_p2p_token":
            guard p2pReady,
                  let dict = payload as? [String: Any],
                  let itemId = dict["item_id"] as? String,
                  let token = dict["token"] as? String,
                  let expiresAt = dict["expires_at"] as? String
            else { return }
            let requester = dict["requester_node_id"] as? String
            _ = try? p2p.authorizeToken(
                itemId: itemId,
                token: token,
                expiresAtIso: expiresAt,
                requesterNodeId: requester
            )
        default:
            break
        }
    }

    // MARK: - Adding Files & Text

    public func addText(_ text: String) async {
        guard let api, let deviceId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let title = firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
        let size = Int64(trimmed.utf8.count)
        do {
            let created = try await api.createItem(
                deviceId: deviceId,
                kind: "text",
                name: title,
                size: size,
                mimeType: "text/plain",
                textContent: trimmed,
                transferMode: "cloud_cached",
                ttlHours: defaultTtlHours > 0 ? defaultTtlHours : nil
            )
            items.removeAll { $0.id == created.id }
            items.insert(created, at: 0)
            showToast("已同步文本")
        } catch {
            showToast("发送文本失败：\(error.localizedDescription)")
        }
    }

    public func addFiles(_ urls: [URL]) async {
        guard let api, let deviceId else { return }
        for sourceURL in urls {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

            let name = sourceURL.lastPathComponent.isEmpty
                ? "file_\(Int(Date().timeIntervalSince1970))"
                : sourceURL.lastPathComponent
            let pending = PendingDrop(name: name)
            pendingDrops.insert(pending, at: 0)
            defer { pendingDrops.removeAll { $0.id == pending.id } }

            do {
                let localCopy = try copyIntoManagedDocuments(sourceURL: sourceURL, preferredName: name)
                let attrs = try FileManager.default.attributesOfItem(atPath: localCopy.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mime = UTType(filenameExtension: localCopy.pathExtension)?.preferredMIMEType
                let thumb = makeThumbnailBase64(for: localCopy)

                let thresholdBytes = Int64(autoCloudThresholdMb) * 1024 * 1024
                let shouldUploadCloud: Bool
                let transferMode: String
                switch dropPolicy {
                case .p2pOnly:
                    shouldUploadCloud = false
                    transferMode = "p2p_only"
                case .cloudCached:
                    shouldUploadCloud = true
                    transferMode = "cloud_cached"
                case .smart:
                    if size <= thresholdBytes {
                        shouldUploadCloud = true
                        transferMode = "hybrid"
                    } else {
                        shouldUploadCloud = false
                        transferMode = "p2p_only"
                    }
                }

                let created = try await api.createItem(
                    deviceId: deviceId,
                    kind: "file",
                    name: name,
                    size: size,
                    mimeType: mime,
                    thumbnailBase64: thumb,
                    transferMode: transferMode,
                    ttlHours: defaultTtlHours > 0 ? defaultTtlHours : nil
                )
                items.removeAll { $0.id == created.id }
                items.insert(created, at: 0)
                localFilePaths[created.id] = localCopy.path
                storage.localFilePaths = localFilePaths

                if p2pReady {
                    _ = try? p2p.registerFile(itemId: created.id, path: localCopy.path)
                }

                if shouldUploadCloud {
                    await cacheItemToCloud(itemId: created.id, fileURL: localCopy)
                } else {
                    showToast("已加入列表（P2P 直连）")
                }
            } catch {
                showToast("添加失败：\(error.localizedDescription)")
            }
        }
    }

    public func cacheItemToCloud(itemId: String, fileURL: URL) async {
        guard let api else { return }
        let cancelToken = TransferCancelToken()
        activeCancelTokens[itemId] = cancelToken
        activeTransfers[itemId] = TransferProgress(
            itemId: itemId,
            transferred: 0,
            total: 0,
            speedBps: 0,
            channel: "upload",
            finished: false
        )
        do {
            let updated = try await api.uploadItemFile(
                itemId: itemId,
                fileURL: fileURL,
                onProgress: { [weak self] sent, total in
                    Task { @MainActor in
                        self?.activeTransfers[itemId] = TransferProgress(
                            itemId: itemId,
                            transferred: sent,
                            total: total,
                            speedBps: 0,
                            channel: "upload",
                            finished: false
                        )
                    }
                },
                cancelToken: cancelToken
            )
            if let idx = items.firstIndex(where: { $0.id == updated.id }) {
                items[idx] = updated
            }
            activeTransfers.removeValue(forKey: itemId)
            activeCancelTokens.removeValue(forKey: itemId)
            showToast("已缓存到云盘")
        } catch is TransferCancelledError {
            activeTransfers.removeValue(forKey: itemId)
            activeCancelTokens.removeValue(forKey: itemId)
            showToast("已取消上传")
        } catch {
            activeTransfers.removeValue(forKey: itemId)
            activeCancelTokens.removeValue(forKey: itemId)
            showToast("云盘上传失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Download & Cancel

    public func downloadItem(
        _ item: DrawerItem,
        preferReplica: Bool = true,
        cloudOnly: Bool = false
    ) async {
        guard let api, let deviceId else { return }
        if item.isText { return }
        let cancelToken = TransferCancelToken()
        activeCancelTokens[item.id] = cancelToken
        activeTransfers[item.id] = TransferProgress(
            itemId: item.id,
            transferred: 0,
            total: item.size,
            speedBps: 0,
            channel: "preparing",
            finished: false
        )

        do {
            let plan = try await api.getDownloadPlan(
                itemId: item.id,
                requesterDeviceId: deviceId,
                preferReplica: preferReplica
            )
            let destURL = uniqueDestinationURL(for: item.name, itemId: item.id)

            if !cloudOnly, p2pReady, let p2pSrc = plan.p2p {
                let transferId = try p2p.downloadFile(
                    itemId: item.id,
                    remoteNodeId: p2pSrc.irohNodeId,
                    remoteRelayUrl: p2pSrc.irohRelayUrl,
                    remoteDirectAddrs: p2pSrc.directAddrs,
                    transferToken: p2pSrc.transferToken,
                    destPath: destURL.path,
                    replicaHash: p2pSrc.replicaHash
                )
                p2pDownloadIds[item.id] = transferId
                if p2pSrc.replicaHash != nil {
                    replicaDownloads.insert(item.id)
                }
                cancelToken.attach { [p2p] in
                    _ = try? p2p.cancelTransfer(transferId: transferId)
                }
                return
            }

            guard let cloud = plan.cloud else {
                activeTransfers.removeValue(forKey: item.id)
                activeCancelTokens.removeValue(forKey: item.id)
                showToast("来源设备离线且未缓存到云盘")
                return
            }

            let saved = try await api.downloadFromCloud(
                cloud: cloud,
                destURL: destURL,
                onProgress: { [weak self] received, total in
                    Task { @MainActor in
                        self?.activeTransfers[item.id] = TransferProgress(
                            itemId: item.id,
                            transferred: received,
                            total: total > 0 ? total : item.size,
                            speedBps: 0,
                            channel: "cloud",
                            finished: false
                        )
                    }
                },
                cancelToken: cancelToken
            )
            localFilePaths[item.id] = saved.path
            storage.localFilePaths = localFilePaths
            if p2pReady {
                _ = try? p2p.registerFile(itemId: item.id, path: saved.path)
            }
            activeTransfers.removeValue(forKey: item.id)
            activeCancelTokens.removeValue(forKey: item.id)
            showToast("已从云端下载完成")
        } catch is TransferCancelledError {
            activeTransfers.removeValue(forKey: item.id)
            activeCancelTokens.removeValue(forKey: item.id)
            showToast("已取消下载")
        } catch {
            activeTransfers.removeValue(forKey: item.id)
            activeCancelTokens.removeValue(forKey: item.id)
            showToast("下载失败：\(error.localizedDescription)")
        }
    }

    public func cancelTransfer(for itemId: String) {
        if let cur = activeTransfers[itemId] {
            activeTransfers[itemId] = TransferProgress(
                itemId: itemId,
                transferred: cur.transferred,
                total: cur.total,
                speedBps: 0,
                channel: "cancelling",
                finished: false
            )
        }
        // Keep p2pDownloadIds[itemId] until native reports terminal event (`AGENTS.md` #6).
        activeCancelTokens[itemId]?.cancel()
    }

    public func downloadAllPending() async {
        let targets = items.filter { !$0.isText && localFileURL(for: $0.id) == nil }
        for item in targets {
            await downloadItem(item)
        }
    }

    // MARK: - Deletion

    public func deleteItem(_ itemId: String) async {
        guard let api else { return }
        do {
            try await api.deleteItem(itemId)
            items.removeAll { $0.id == itemId }
            if p2pReady { _ = try? p2p.unregisterFile(itemId: itemId) }
        } catch {
            showToast("移出失败：\(error.localizedDescription)")
        }
    }

    public func batchDelete(itemIds: [String] = [], clearAll: Bool = false) async {
        guard let api else { return }
        do {
            let res = try await api.batchDeleteItems(itemIds: itemIds, clearAll: clearAll)
            let removed = Set(res.deletedIds)
            items.removeAll { removed.contains($0.id) }
            for id in removed where p2pReady {
                _ = try? p2p.unregisterFile(itemId: id)
            }
            showToast(clearAll ? "已清空 \(removed.count) 项" : "已移出 \(removed.count) 项")
        } catch {
            showToast("批量清理失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Share Links

    public func createShareLink(
        items targetItems: [DrawerItem],
        title: String? = nil,
        passcode: String? = nil,
        expiresHours: Int? = nil,
        maxDownloads: Int? = nil
    ) async throws -> ShareLinkInfo {
        guard let api else { throw APIError.message("未登录") }
        // Ensure files are uploaded to cloud before creating public share links.
        for item in targetItems where !item.isText && !item.cloudReady {
            if let local = localFileURL(for: item.id) {
                await cacheItemToCloud(itemId: item.id, fileURL: local)
            }
        }
        let info: ShareLinkInfo
        if targetItems.count == 1, let only = targetItems.first {
            info = try await api.createShareLink(
                itemId: only.id,
                passcode: passcode,
                expiresHours: expiresHours,
                maxDownloads: maxDownloads
            )
        } else {
            info = try await api.createBatchShareLink(
                itemIds: targetItems.map(\.id),
                title: title,
                passcode: passcode,
                expiresHours: expiresHours,
                maxDownloads: maxDownloads
            )
        }
        await refreshShareLinks()
        return info
    }

    public func deleteShareLink(code: String) async {
        guard let api else { return }
        do {
            try await api.deleteShareLink(code: code)
            shareLinks.removeAll { $0.code == code }
            showToast("已撤销外链")
        } catch {
            showToast("撤销失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Storage Backends

    public func addStorageBackend(
        name: String,
        config: [String: JSONValue],
        isDefault: Bool
    ) async throws {
        guard let api else { throw APIError.message("未登录") }
        _ = try await api.createStorageBackend(name: name, config: config, isDefault: isDefault)
        await refreshStorageBackends()
    }

    public func getStorageCapacity(id: String) async throws -> Int? {
        guard let api else { throw APIError.message("未登录") }
        return try await api.getStorageCapacity(id: id)
    }

    public func updateStorageBackend(
        id: String,
        name: String,
        config: [String: JSONValue]
    ) async throws {
        guard let api else { throw APIError.message("未登录") }
        let backends = try await api.updateStorageBackend(id: id, name: name, config: config)
        guard self.api === api else { return }
        storageRevision += 1
        storageBackends = backends
    }

    public func setDefaultStorageBackend(id: String) async throws {
        guard let api else { throw APIError.message("未登录") }
        let backends = try await api.setDefaultStorageBackend(id: id)
        guard self.api === api else { return }
        storageRevision += 1
        storageBackends = backends
    }

    public func removeStorageBackend(id: String) async {
        guard let api else { return }
        do {
            try await api.deleteStorageBackend(id: id)
            storageBackends.removeAll { $0.id == id }
            showToast("已删除存储策略")
        } catch {
            showToast("删除失败：\(error.localizedDescription)")
        }
    }

    public func testStorageBackend(id: String) async throws -> (Bool, String) {
        guard let api else { throw APIError.message("未登录") }
        return try await api.checkStorageHealth(id: id)
    }

    public func startGoogleDriveOAuth(
        name: String,
        clientId: String,
        clientSecret: String,
        folderId: String,
        isDefault: Bool
    ) async throws -> URL {
        guard let api else { throw APIError.message("未登录") }
        return try await api.startGoogleOAuth(
            name: name,
            clientId: clientId,
            clientSecret: clientSecret,
            folderId: folderId,
            isDefault: isDefault
        )
    }

    // MARK: - App Group Share Queue Consumption

    public func consumeSharedAppGroupQueue() async {
        guard isLoggedIn else { return }
        let fm = FileManager.default
        guard let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: SessionStorage.appGroupId) else {
            return
        }
        let queueDir = groupURL.appendingPathComponent("pending_shares", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil),
              !entries.isEmpty
        else { return }

        var filesToAdd: [URL] = []
        var textsToAdd: [String] = []
        for url in entries {
            if url.pathExtension.lowercased() == "ddtext",
               let text = try? String(contentsOf: url, encoding: .utf8) {
                textsToAdd.append(text)
                try? fm.removeItem(at: url)
            } else {
                filesToAdd.append(url)
            }
        }
        for text in textsToAdd {
            await addText(text)
        }
        if !filesToAdd.isEmpty {
            await addFiles(filesToAdd)
            for url in filesToAdd {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Local File & Thumbnail Helpers

    private func copyIntoManagedDocuments(sourceURL: URL, preferredName: String) throws -> URL {
        let fm = FileManager.default
        let dir = downloadsDirectory()
        var dest = dir.appendingPathComponent(preferredName)
        if fm.fileExists(atPath: dest.path) {
            let stem = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let name = ext.isEmpty ? "\(stem)_\(stamp)" : "\(stem)_\(stamp).\(ext)"
            dest = dir.appendingPathComponent(name)
        }
        try fm.copyItem(at: sourceURL, to: dest)
        return dest
    }

    private func uniqueDestinationURL(for fileName: String, itemId: String) -> URL {
        if let existing = localFilePaths[itemId] {
            return URL(fileURLWithPath: existing)
        }
        let fm = FileManager.default
        let dir = downloadsDirectory()
        let safeName = (fileName as NSString).lastPathComponent
        var dest = dir.appendingPathComponent(safeName.isEmpty ? itemId : safeName)
        if fm.fileExists(atPath: dest.path) {
            let stem = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            let shortId = String(itemId.prefix(6))
            let alt = ext.isEmpty ? "\(stem)_\(shortId)" : "\(stem)_\(shortId).\(ext)"
            dest = dir.appendingPathComponent(alt)
        }
        return dest
    }

    private func makeThumbnailBase64(for fileURL: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImg, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }
}
