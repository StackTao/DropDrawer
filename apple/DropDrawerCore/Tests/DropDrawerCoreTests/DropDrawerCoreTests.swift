import CryptoKit
import Foundation
import Testing
@testable import DropDrawerCore

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("DropDrawerCore Tests")
struct DropDrawerCoreTests {
    @Test("DrawerItem decodes server JSON and computes display helpers")
    func decodeDrawerItem() throws {
        let json = """
        {
          "id": "item-1",
          "user_id": "u1",
          "owner_device_id": "d1",
          "owner_device_name": "Studio MacBook Pro.local",
          "owner_online": true,
          "owner_iroh_node_id": "node123",
          "owner_direct_addrs": ["192.168.1.5:4000"],
          "kind": "file",
          "name": "vacation.heic",
          "size": 1572864,
          "mime_type": "image/heic",
          "transfer_mode": "hybrid",
          "storage_backend_name": "Cloudflare R2",
          "cloud_ready": true,
          "created_at": "2026-11-26T02:00:00.123Z"
        }
        """
        let item = try JSONDecoder().decode(DrawerItem.self, from: Data(json.utf8))
        #expect(item.id == "item-1")
        #expect(item.cleanOwnerDeviceName == "Studio MacBook Pro")
        #expect(item.isImage)
        #expect(item.canSaveToPhotos)
        #expect(item.canP2P)
        #expect(formatBytes(item.size) == "1.5 MB")
    }

    @Test("TransferCancelToken notifies all attached listeners once")
    func multiListenerCancelToken() {
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ v: Int) { lock.withLock { values.append(v) } }
            var snapshot: [Int] { lock.withLock { values } }
        }
        let token = TransferCancelToken()
        let fired = Collector()
        token.attach { fired.append(1) }
        token.attach { fired.append(2) }
        token.cancel()
        token.cancel()
        // Attaching after cancel fires immediately.
        token.attach { fired.append(3) }
        #expect(token.isCancelled)
        #expect(fired.snapshot == [1, 2, 3])
    }

    @Test("WebSocket reducer updates devices and refreshes owner online state")
    @MainActor
    func wsStateReduction() {
        let storage = SessionStorage(suiteName: "test.\(UUID().uuidString)", keychainService: "test.\(UUID().uuidString)")
        let store = DropDrawerStore(storage: storage)

        store.handleWSMessage("""
        {
          "type": "snapshot",
          "payload": {
            "devices": [
              {"id": "d1", "user_id": "u1", "name": "Mac.local", "platform": "macos", "online": false, "direct_addrs": []}
            ],
            "items": [
              {"id": "i1", "user_id": "u1", "owner_device_id": "d1", "owner_device_name": "Mac.local", "owner_online": false, "kind": "file", "name": "demo.pdf", "size": 2048, "transfer_mode": "p2p_only", "cloud_ready": false, "created_at": "2026-11-26T02:00:00Z"}
            ]
          }
        }
        """)
        #expect(store.devices.count == 1)
        #expect(store.items.count == 1)
        #expect(store.items[0].ownerOnline == false)

        store.handleWSMessage("""
        {
          "type": "device_updated",
          "payload": {
            "id": "d1",
            "user_id": "u1",
            "name": "Mac.local",
            "platform": "macos",
            "iroh_node_id": "abc",
            "online": true,
            "direct_addrs": ["10.0.0.2:1234"]
          }
        }
        """)
        #expect(store.devices[0].online == true)
        #expect(store.items[0].ownerOnline == true)
        #expect(store.items[0].canP2P == true)

        store.handleWSMessage("""
        {"type": "item_deleted", "payload": {"item_id": "i1"}}
        """)
        #expect(store.items.isEmpty)
    }

    @Test("Relative time labels are localized")
    func relativeDateLabels() {
        // The test process picks Chinese or English from the machine's languages.
        let now = Date(timeIntervalSince1970: 1_795_660_000)
        #expect(["刚刚", "Just now"].contains(DateParsing.formatRelative(now.addingTimeInterval(-15), now: now)))
        #expect(["1 分钟前", "1 minute ago"].contains(DateParsing.formatRelative(now.addingTimeInterval(-60), now: now)))
        #expect(["7 分钟前", "7 minutes ago"].contains(DateParsing.formatRelative(now.addingTimeInterval(-420), now: now)))
        #expect(["3 小时前", "3 hours ago"].contains(DateParsing.formatRelative(now.addingTimeInterval(-10800), now: now)))
        #expect(["1 小时前", "1 hour ago"].contains(DateParsing.formatRelative(now.addingTimeInterval(-3600), now: now)))
    }

    @Test("Server requests carry the UI language")
    func acceptLanguageMatchesTheUILanguage() {
        #expect(AppLanguage.acceptLanguage == (AppLanguage.isChinese ? "zh-CN" : "en"))
        #expect(AppLanguage.locale.identifier == (AppLanguage.isChinese ? "zh-Hans" : "en"))
    }

    @Test("DropDrawerStore restores persisted session synchronously on init to avoid login flash")
    @MainActor
    func synchronousSessionRestore() {
        let suite = "test.restore.\(UUID().uuidString)"
        let service = "test.restore.\(UUID().uuidString)"
        let storage = SessionStorage(suiteName: suite, keychainService: service)
        storage.serverUrl = "https://drop.example.com"
        storage.user = UserProfile(id: "u-1", username: "alice")
        storage.token = "jwt-sample-token"

        let store = DropDrawerStore(storage: storage)
        #expect(store.isLoggedIn == true)
        #expect(store.user?.username == "alice")

        store.logout()
        #expect(store.isLoggedIn == false)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test("Cancelled cloud download preserves existing destination file")
    func cancelledDownloadPreservesDestination() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dd-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dest = tempDir.appendingPathComponent("existing.txt")
        try Data("original-content".utf8).write(to: dest)

        let api = APIClient(baseUrl: "http://127.0.0.1:9")
        let token = TransferCancelToken()
        token.cancel()

        do {
            _ = try await api.downloadFromCloud(
                cloud: CloudDownloadInfo(
                    url: "/api/drawer/items/1/download",
                    isDirectUrl: false,
                    backendName: "Local"
                ),
                destURL: dest,
                cancelToken: token
            )
            Issue.record("Expected TransferCancelledError")
        } catch is TransferCancelledError {
            // Expected
        }

        let preserved = try String(contentsOf: dest, encoding: .utf8)
        #expect(preserved == "original-content")
    }

    @Test("Pending cloud uploads persist across restarts and clear on item_deleted or logout")
    @MainActor
    func pendingCloudUploadsLifecycle() throws {
        let suite = "test.pending.\(UUID().uuidString)"
        let service = "test.pending.\(UUID().uuidString)"
        let storage = SessionStorage(suiteName: suite, keychainService: service)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dd-pending-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        storage.pendingCloudUploads = ["item-1": tempFile.path, "item-2": tempFile.path]
        let store = DropDrawerStore(storage: storage)

        store.handleWSMessage("""
        {"type": "item_deleted", "payload": {"item_id": "item-1"}}
        """)
        #expect(storage.pendingCloudUploads["item-1"] == nil)
        #expect(storage.pendingCloudUploads["item-2"] == tempFile.path)

        store.logout()
        #expect(storage.pendingCloudUploads.isEmpty)
    }

    @Test("uploadItemFile sends content_sha256 and short-circuits on already_cached")
    func uploadAlreadyCachedShortCircuits() async throws {
        let payload = Data("swift-dedup-content-12345".utf8)
        let expectedHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dd-dedup-\(UUID().uuidString).bin")
        try payload.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        final class Capture: @unchecked Sendable {
            private let lock = NSLock()
            var planBody: [String: Any]?
            var requestCount = 0
            func record(body: [String: Any]?) {
                lock.withLock {
                    requestCount += 1
                    planBody = body
                }
            }
        }
        let capture = Capture()

        StubURLProtocol.handler = { req in
            let bodyData: Data? = {
                if let direct = req.httpBody { return direct }
                guard let stream = req.httpBodyStream else { return nil }
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buf, maxLength: buf.count)
                    if read <= 0 { break }
                    data.append(buf, count: read)
                }
                return data
            }()
            let jsonObj = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            capture.record(body: jsonObj)

            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let respJson = """
            {
              "strategy": "already_cached",
              "item": {
                "id": "item-dedup",
                "user_id": "u1",
                "owner_device_id": "d1",
                "owner_online": true,
                "owner_direct_addrs": [],
                "kind": "file",
                "name": "sample.bin",
                "size": \(payload.count),
                "transfer_mode": "cloud_cached",
                "storage_backend_id": "local-1",
                "storage_backend_name": "Local",
                "cloud_ready": true,
                "created_at": "2026-11-26T02:00:00Z"
              }
            }
            """
            return (resp, Data(respJson.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let api = APIClient(baseUrl: "https://drop.example.com", token: "tok", session: session)

        let item = try await api.uploadItemFile(itemId: "item-dedup", fileURL: tempFile)
        #expect(item.id == "item-dedup")
        #expect(item.cloudReady == true)
        #expect(capture.requestCount == 1)
        #expect(capture.planBody?["content_sha256"] as? String == expectedHash)
        #expect(capture.planBody?["size"] as? Int == payload.count)
    }

    @Test("AuthPublicConfig decodes registration mode, email rules, and enabled providers")
    func decodeAuthPublicConfig() throws {
        let json = """
        {
          "registration_mode": "invite_only",
          "password_login_enabled": true,
          "email_verification_required": true,
          "email_password_reset_enabled": true,
          "providers": [
            {"id": "google", "name": "Google", "kind": "oauth2_oidc", "enabled": true}
          ]
        }
        """
        let cfg = try JSONDecoder().decode(AuthPublicConfig.self, from: Data(json.utf8))
        #expect(cfg.registrationAllowed == true)
        #expect(cfg.inviteCodeRequired == true)
        #expect(cfg.emailVerificationRequired == true)
        #expect(cfg.emailPasswordResetEnabled == true)
        #expect(cfg.googleEnabled == true)
    }

    @Test("ClientConfig decodes server switches and defaults missing fields to permissive values")
    func decodeClientConfig() throws {
        let json = """
        {
          "server_version": "0.1.6",
          "features": {"share_create_enabled": false, "cloud_upload_enabled": false, "share_requires_passcode": true, "max_share_expires_hours": 72, "disabled_storage_kinds": ["web_dav"]},
          "announcement": {"id": "1700", "level": "warning", "title": "维护", "message": "今晚升级"},
          "min_client_version": "0.1.5"
        }
        """
        let cfg = try JSONDecoder().decode(ClientConfig.self, from: Data(json.utf8))
        #expect(cfg.features.shareCreateEnabled == false)
        #expect(cfg.features.cloudUploadEnabled == false)
        #expect(cfg.features.shareRequiresPasscode == true)
        #expect(cfg.features.maxShareExpiresHours == 72)
        #expect(cfg.features.disabledStorageKinds == ["web_dav"])
        #expect(cfg.announcement?.level == "warning")
        #expect(cfg.minClientVersion == "0.1.5")

        let sparse = try JSONDecoder().decode(ClientConfig.self, from: Data(#"{"features": {}}"#.utf8))
        #expect(sparse.features.shareCreateEnabled == true)
        #expect(sparse.features.cloudUploadEnabled == true)
        #expect(sparse.announcement == nil)
        #expect(sparse.features.disabledStorageKinds.isEmpty)
    }

    @Test("Store gates sharing and remembers the dismissed announcement")
    @MainActor
    func storeAppliesServerPolicy() throws {
        let suite = "dd.tests.policy.\(UUID().uuidString)"
        let storage = SessionStorage(suiteName: suite, keychainService: "dd.tests.\(UUID().uuidString)")
        let store = DropDrawerStore(storage: storage)
        #expect(store.canCreateShares == true)
        #expect(store.canUploadToCloud == true)

        #expect(store.isStorageKindAllowed("web_dav") == true)
        store.clientConfig = ClientConfig(
            features: ClientFeatures(
                shareCreateEnabled: false,
                cloudUploadEnabled: false,
                shareRequiresPasscode: true,
                disabledStorageKinds: ["web_dav"]
            ),
            announcement: ClientAnnouncement(id: "a1", title: "通知")
        )
        #expect(store.canCreateShares == false)
        #expect(store.canUploadToCloud == false)
        #expect(store.shareRequiresPasscode == true)
        #expect(store.isStorageKindAllowed("web_dav") == false)
        #expect(store.isStorageKindAllowed("s3") == true)
        #expect(store.activeAnnouncement?.id == "a1")

        store.dismissAnnouncement()
        #expect(store.activeAnnouncement == nil)
        #expect(storage.dismissedAnnouncementId == "a1")

        store.clientConfig?.announcement = ClientAnnouncement(id: "a2", title: "新的通知")
        #expect(store.activeAnnouncement?.id == "a2")
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
