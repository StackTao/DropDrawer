import Foundation

public struct TransferCancelledError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "传输已取消" }
}

/// Thread-safe cancellation token supporting multiple attached listeners
/// (mirroring `AGENTS.md` #5: never overwrite a previously attached listener).
public final class TransferCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var listeners: [@Sendable () -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func attach(_ handler: @escaping @Sendable () -> Void) {
        let shouldFireImmediately: Bool
        lock.lock()
        if cancelled {
            shouldFireImmediately = true
        } else {
            listeners.append(handler)
            shouldFireImmediately = false
        }
        lock.unlock()
        if shouldFireImmediately {
            handler()
        }
    }

    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let callbacks = listeners
        listeners.removeAll()
        lock.unlock()
        for fn in callbacks {
            fn()
        }
    }
}

public enum APIError: LocalizedError, Sendable {
    case invalidURL(String)
    case httpStatus(Int, String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "无效的服务器地址：\(url)"
        case .httpStatus(let code, let body):
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String, !err.isEmpty {
                return err
            }
            return body.isEmpty ? "请求失败 (\(code))" : "请求失败 (\(code))：\(body)"
        case .message(let msg):
            return msg
        }
    }
}

public struct GoogleSignInStart: Sendable, Equatable {
    public let url: URL
    public let state: String
    public let pollKey: String
    public let expiresIn: Int
}

public struct AuthResult: Codable, Sendable, Equatable {
    public let token: String
    public let user: UserProfile
}

public struct BatchDeleteResult: Sendable, Equatable {
    public let deletedIds: [String]
    public let failedIds: [String]
}

private final class TransferStreamDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let onSendProgress: (@Sendable (Int64, Int64) -> Void)?

    init(onSendProgress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.onSendProgress = onSendProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onSendProgress?(totalBytesSent, totalBytesExpectedToSend)
    }
}

/// Async REST + streaming upload/download + WebSocket client matching `crates/server`.
public final class APIClient: @unchecked Sendable {
    private let lock = NSLock()
    private var _baseUrl: String
    private var _token: String?
    private let session: URLSession

    public init(baseUrl: String, token: String? = nil, session: URLSession? = nil) {
        self._baseUrl = baseUrl
        self._token = token
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 3600
            self.session = URLSession(configuration: cfg)
        }
    }

    public var baseUrl: String {
        get { lock.withLock { _baseUrl } }
        set { lock.withLock { _baseUrl = newValue } }
    }

    public var token: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }

    public var cleanBase: String {
        baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private func makeURL(_ path: String) throws -> URL {
        let full = path.hasPrefix("http://") || path.hasPrefix("https://")
            ? path
            : "\(cleanBase)\(path)"
        guard let url = URL(string: full) else {
            throw APIError.invalidURL(full)
        }
        return url
    }

    private func makeRequest(
        _ path: String,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        authenticated: Bool = true
    ) throws -> URLRequest {
        var req = URLRequest(url: try makeURL(path))
        req.httpMethod = method
        if authenticated, let tok = token, !tok.isEmpty {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        return req
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("无效的服务器响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, body)
        }
        return data
    }

    // MARK: - Auth

    public func register(username: String, password: String) async throws -> AuthResult {
        let req = try makeRequest(
            "/api/auth/register",
            method: "POST",
            jsonBody: ["username": username, "password": password],
            authenticated: false
        )
        let data = try await perform(req)
        let result = try JSONDecoder().decode(AuthResult.self, from: data)
        token = result.token
        return result
    }

    public func login(username: String, password: String) async throws -> AuthResult {
        let req = try makeRequest(
            "/api/auth/login",
            method: "POST",
            jsonBody: ["username": username, "password": password],
            authenticated: false
        )
        let data = try await perform(req)
        let result = try JSONDecoder().decode(AuthResult.self, from: data)
        token = result.token
        return result
    }

    public func startGoogleSignIn() async throws -> GoogleSignInStart {
        guard let server = URL(string: cleanBase), let scheme = server.scheme?.lowercased() else {
            throw APIError.invalidURL(cleanBase)
        }
        let host = server.host?.lowercased() ?? ""
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        if scheme != "https" && !(scheme == "http" && isLoopback) {
            throw APIError.message("Google 登录需要 HTTPS 服务器地址。")
        }
        var req = try makeRequest("/api/auth/google/start", method: "POST", authenticated: false)
        req.timeoutInterval = 10
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("无效的服务器响应")
        }
        if http.statusCode == 404 || http.statusCode == 503 {
            throw APIError.message("此服务器尚未启用 Google 登录。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Resp: Decodable {
            let authorization_url: String
            let state: String
            let poll_key: String
            let expires_in: Int
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let authURL = URL(string: decoded.authorization_url),
              authURL.scheme?.lowercased() == "https",
              authURL.host?.lowercased() == "accounts.google.com",
              authURL.user == nil
        else {
            throw APIError.message("服务器返回了无效的 Google 授权地址。")
        }
        return GoogleSignInStart(
            url: authURL,
            state: decoded.state,
            pollKey: decoded.poll_key,
            expiresIn: decoded.expires_in
        )
    }

    public func pollGoogleSignIn(state: String, pollKey: String) async throws -> AuthResult? {
        var req = try makeRequest(
            "/api/auth/google/poll",
            method: "POST",
            jsonBody: ["state": state, "poll_key": pollKey],
            authenticated: false
        )
        req.timeoutInterval = 10
        let data = try await perform(req)
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == "null" {
            return nil
        }
        let result = try JSONDecoder().decode(AuthResult.self, from: data)
        token = result.token
        return result
    }

    // MARK: - Devices

    public func registerDevice(
        deviceId: String?,
        name: String,
        platform: String,
        irohNodeId: String? = nil,
        irohRelayUrl: String? = nil,
        directAddrs: [String] = []
    ) async throws -> DeviceInfo {
        var body: [String: Any] = [
            "name": name,
            "platform": platform,
            "direct_addrs": directAddrs,
        ]
        body["device_id"] = deviceId ?? NSNull()
        body["iroh_node_id"] = irohNodeId ?? NSNull()
        body["iroh_relay_url"] = irohRelayUrl ?? NSNull()
        let req = try makeRequest("/api/devices", method: "POST", jsonBody: body)
        let data = try await perform(req)
        return try JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    public func listDevices() async throws -> [DeviceInfo] {
        let req = try makeRequest("/api/devices")
        let data = try await perform(req)
        return try JSONDecoder().decode([DeviceInfo].self, from: data)
    }

    // MARK: - Items

    public func listItems() async throws -> [DrawerItem] {
        let req = try makeRequest("/api/drawer/items")
        let data = try await perform(req)
        return try JSONDecoder().decode([DrawerItem].self, from: data)
    }

    public func createItem(
        deviceId: String,
        kind: String,
        name: String,
        size: Int64,
        mimeType: String? = nil,
        blake3Hash: String? = nil,
        textContent: String? = nil,
        thumbnailBase64: String? = nil,
        transferMode: String,
        storageBackendId: String? = nil,
        ttlHours: Int? = nil
    ) async throws -> DrawerItem {
        let body: [String: Any] = [
            "device_id": deviceId,
            "kind": kind,
            "name": name,
            "size": size,
            "mime_type": mimeType ?? NSNull(),
            "blake3_hash": blake3Hash ?? NSNull(),
            "text_content": textContent ?? NSNull(),
            "thumbnail_base64": thumbnailBase64 ?? NSNull(),
            "transfer_mode": transferMode,
            "storage_backend_id": storageBackendId ?? NSNull(),
            "ttl_hours": ttlHours ?? NSNull(),
        ]
        let req = try makeRequest("/api/drawer/items", method: "POST", jsonBody: body)
        let data = try await perform(req)
        return try JSONDecoder().decode(DrawerItem.self, from: data)
    }

    public func deleteItem(_ itemId: String) async throws {
        let req = try makeRequest("/api/drawer/items/\(itemId)", method: "DELETE")
        _ = try await perform(req)
    }

    public func batchDeleteItems(itemIds: [String] = [], clearAll: Bool = false) async throws -> BatchDeleteResult {
        let req = try makeRequest(
            "/api/drawer/items/batch-delete",
            method: "POST",
            jsonBody: ["item_ids": itemIds, "clear_all": clearAll]
        )
        let data = try await perform(req)
        struct Resp: Decodable {
            let item_ids: [String]
            let failed_item_ids: [String]?
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return BatchDeleteResult(
            deletedIds: decoded.item_ids,
            failedIds: decoded.failed_item_ids ?? []
        )
    }

    public func uploadItemFile(
        itemId: String,
        fileURL: URL,
        storageBackendId: String? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
        cancelToken: TransferCancelToken? = nil
    ) async throws -> DrawerItem {
        if cancelToken?.isCancelled == true { throw TransferCancelledError() }
        let planReq = try makeRequest(
            "/api/drawer/items/\(itemId)/upload-plan",
            method: "POST",
            jsonBody: ["storage_backend_id": storageBackendId ?? NSNull()]
        )
        let planData = try await perform(planReq)
        guard let plan = try JSONSerialization.jsonObject(with: planData) as? [String: Any],
              let strategy = plan["strategy"] as? String,
              let urlStr = plan["url"] as? String
        else {
            throw APIError.message("上传计划响应格式无效")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        if strategy == "direct_presigned_put" {
            guard let putURL = URL(string: urlStr) else { throw APIError.invalidURL(urlStr) }
            var req = URLRequest(url: putURL)
            req.httpMethod = "PUT"
            if let pairs = plan["headers"] as? [[Any]] {
                for pair in pairs where pair.count >= 2 {
                    req.setValue("\(pair[1])", forHTTPHeaderField: "\(pair[0])")
                }
            }
            _ = try await streamUpload(
                request: req,
                fileURL: fileURL,
                onProgress: onProgress,
                cancelToken: cancelToken
            )
            let confirmReq = try makeRequest(
                "/api/drawer/items/\(itemId)/confirm-upload",
                method: "POST",
                jsonBody: [
                    "storage_backend_id": plan["storage_backend_id"] ?? NSNull(),
                    "remote_key": plan["remote_key"] ?? NSNull(),
                    "size": total,
                ]
            )
            let confirmData = try await perform(confirmReq)
            return try JSONDecoder().decode(DrawerItem.self, from: confirmData)
        } else {
            var req = try makeRequest(urlStr, method: "PUT", authenticated: true)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let body = try await streamUpload(
                request: req,
                fileURL: fileURL,
                onProgress: onProgress,
                cancelToken: cancelToken
            )
            return try JSONDecoder().decode(DrawerItem.self, from: body)
        }
    }

    private func streamUpload(
        request: URLRequest,
        fileURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?,
        cancelToken: TransferCancelToken?
    ) async throws -> Data {
        if cancelToken?.isCancelled == true { throw TransferCancelledError() }
        let delegate = TransferStreamDelegate(onSendProgress: onProgress)
        let uploadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { uploadSession.finishTasksAndInvalidate() }

        let taskHolder = Box<URLSessionUploadTask?>(nil)
        cancelToken?.attach {
            taskHolder.withLock { $0?.cancel() }
        }
        return try await withCheckedThrowingContinuation { cont in
            let task = uploadSession.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if cancelToken?.isCancelled == true {
                    cont.resume(throwing: TransferCancelledError())
                    return
                }
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: APIError.message("上传未收到有效响应"))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    cont.resume(throwing: APIError.httpStatus(http.statusCode, msg))
                    return
                }
                cont.resume(returning: data ?? Data())
            }
            taskHolder.withLock { $0 = task }
            if cancelToken?.isCancelled == true {
                task.cancel()
            } else {
                task.resume()
            }
        }
    }

    public func getDownloadPlan(
        itemId: String,
        requesterDeviceId: String,
        preferReplica: Bool = true
    ) async throws -> DownloadPlan {
        let encoded = requesterDeviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? requesterDeviceId
        let path = "/api/drawer/items/\(itemId)/download-plan?prefer_replica=\(preferReplica)&requester_device_id=\(encoded)"
        let req = try makeRequest(path)
        let data = try await perform(req)
        return try JSONDecoder().decode(DownloadPlan.self, from: data)
    }

    /// Streams cloud download into a same-volume staging directory and atomically
    /// replaces `destURL`. Existing destination is never deleted on failure (`AGENTS.md` #7).
    public func downloadFromCloud(
        cloud: CloudDownloadInfo,
        destURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
        cancelToken: TransferCancelToken? = nil
    ) async throws -> URL {
        if cancelToken?.isCancelled == true { throw TransferCancelledError() }
        let req = try makeRequest(cloud.url, method: "GET", authenticated: !cloud.isDirectUrl)
        let fm = FileManager.default
        let parentDir = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let stagingDir = parentDir.appendingPathComponent(".dropdrawer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let partialURL = stagingDir.appendingPathComponent("download.part")
        fm.createFile(atPath: partialURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partialURL)

        let taskBox = Box<Task<Void, Never>?>(nil)
        do {
            let (bytes, response) = try await session.bytes(for: req)
            if cancelToken?.isCancelled == true { throw TransferCancelledError() }
            guard let http = response as? HTTPURLResponse else {
                throw APIError.message("下载未收到有效响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.httpStatus(http.statusCode, "")
            }
            let total = http.expectedContentLength > 0 ? http.expectedContentLength : 0
            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)

            for try await byte in bytes {
                if cancelToken?.isCancelled == true { throw TransferCancelledError() }
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress?(received, total)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                onProgress?(received, total)
            }
            try handle.synchronize()
            try handle.close()

            if cancelToken?.isCancelled == true { throw TransferCancelledError() }
            // Atomic replacement on the same volume preserves any existing destination on error.
            _ = try fm.replaceItemAt(destURL, withItemAt: partialURL)
            _ = taskBox
            return destURL
        } catch {
            try? handle.close()
            if cancelToken?.isCancelled == true {
                throw TransferCancelledError()
            }
            throw error
        }
    }

    // MARK: - Share Links

    public func createShareLink(
        itemId: String,
        passcode: String? = nil,
        expiresHours: Int? = nil,
        maxDownloads: Int? = nil
    ) async throws -> ShareLinkInfo {
        let trimmedPass = passcode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "passcode": (trimmedPass?.isEmpty == false) ? trimmedPass! : NSNull(),
            "expires_hours": expiresHours ?? NSNull(),
            "max_downloads": maxDownloads ?? NSNull(),
        ]
        let req = try makeRequest("/api/drawer/items/\(itemId)/share", method: "POST", jsonBody: body)
        let data = try await perform(req)
        return try JSONDecoder().decode(ShareLinkInfo.self, from: data)
    }

    public func createBatchShareLink(
        itemIds: [String],
        title: String? = nil,
        passcode: String? = nil,
        expiresHours: Int? = nil,
        maxDownloads: Int? = nil
    ) async throws -> ShareLinkInfo {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = passcode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "item_ids": itemIds,
            "title": (trimmedTitle?.isEmpty == false) ? trimmedTitle! : NSNull(),
            "passcode": (trimmedPass?.isEmpty == false) ? trimmedPass! : NSNull(),
            "expires_hours": expiresHours ?? NSNull(),
            "max_downloads": maxDownloads ?? NSNull(),
        ]
        let req = try makeRequest("/api/shares", method: "POST", jsonBody: body)
        let data = try await perform(req)
        return try JSONDecoder().decode(ShareLinkInfo.self, from: data)
    }

    public func listShareLinks() async throws -> [ShareLinkInfo] {
        let req = try makeRequest("/api/shares")
        let data = try await perform(req)
        return try JSONDecoder().decode([ShareLinkInfo].self, from: data)
    }

    public func deleteShareLink(code: String) async throws {
        let req = try makeRequest("/api/shares/\(code)", method: "DELETE")
        _ = try await perform(req)
    }

    // MARK: - Storage Backends

    public func listStorageBackends() async throws -> [StorageBackendSummary] {
        let req = try makeRequest("/api/storage")
        let data = try await perform(req)
        return try JSONDecoder().decode([StorageBackendSummary].self, from: data)
    }

    public func createStorageBackend(
        name: String,
        config: [String: JSONValue],
        isDefault: Bool
    ) async throws -> StorageBackendSummary {
        let rawConfig = config.mapValues(\.foundationValue)
        let req = try makeRequest(
            "/api/storage",
            method: "POST",
            jsonBody: ["name": name, "config": rawConfig, "is_default": isDefault]
        )
        let data = try await perform(req)
        return try JSONDecoder().decode(StorageBackendSummary.self, from: data)
    }

    public func deleteStorageBackend(id: String) async throws {
        let req = try makeRequest("/api/storage/\(id)", method: "DELETE")
        _ = try await perform(req)
    }

    public func checkStorageHealth(id: String) async throws -> (Bool, String) {
        let req = try makeRequest("/api/storage/\(id)/health", method: "POST")
        let data = try await perform(req)
        struct Resp: Decodable {
            let ok: Bool?
            let message: String?
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return (decoded.ok ?? false, decoded.message ?? "")
    }

    public func startGoogleOAuth(
        name: String,
        clientId: String,
        clientSecret: String,
        folderId: String = "root",
        isDefault: Bool = true
    ) async throws -> URL {
        let redirectUri = "\(cleanBase)/api/oauth/google/callback"
        let req = try makeRequest(
            "/api/oauth/google/start",
            method: "POST",
            jsonBody: [
                "name": name,
                "client_id": clientId,
                "client_secret": clientSecret,
                "folder_id": folderId,
                "is_default": isDefault,
                "redirect_uri": redirectUri,
            ]
        )
        let data = try await perform(req)
        struct Resp: Decodable { let auth_url: String }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let url = URL(string: decoded.auth_url) else {
            throw APIError.invalidURL(decoded.auth_url)
        }
        return url
    }

    // MARK: - WebSocket

    public func makeWebSocketTask(deviceId: String) throws -> URLSessionWebSocketTask {
        var wsBase = cleanBase
        if wsBase.hasPrefix("https://") {
            wsBase = "wss://" + wsBase.dropFirst("https://".count)
        } else if wsBase.hasPrefix("http://") {
            wsBase = "ws://" + wsBase.dropFirst("http://".count)
        }
        let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
        guard let url = URL(string: "\(wsBase)/ws?device_id=\(encoded)") else {
            throw APIError.invalidURL("\(wsBase)/ws")
        }
        var req = URLRequest(url: url)
        if let tok = token, !tok.isEmpty {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        return session.webSocketTask(with: req)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
