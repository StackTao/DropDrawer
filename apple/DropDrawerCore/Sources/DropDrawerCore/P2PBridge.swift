import DropDrawerP2P
import Foundation

public struct P2PEvent: Codable, Sendable, Equatable {
    public let transferId: String
    public let itemId: String
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let speedBps: Int64
    public let pathKind: String
    public let finished: Bool
    public let cancelled: Bool
    public let savedPath: String?
    public let sendingTo: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case itemId = "item_id"
        case bytesTransferred = "bytes_transferred"
        case totalBytes = "total_bytes"
        case speedBps = "speed_bps"
        case pathKind = "path_kind"
        case finished
        case cancelled
        case savedPath = "saved_path"
        case sendingTo = "sending_to"
        case error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transferId = try c.decode(String.self, forKey: .transferId)
        itemId = try c.decode(String.self, forKey: .itemId)
        bytesTransferred = try c.decodeIfPresent(Int64.self, forKey: .bytesTransferred) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        speedBps = try c.decodeIfPresent(Int64.self, forKey: .speedBps) ?? 0
        pathKind = try c.decodeIfPresent(String.self, forKey: .pathKind) ?? "unknown"
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        savedPath = try c.decodeIfPresent(String.self, forKey: .savedPath)
        sendingTo = try c.decodeIfPresent(String.self, forKey: .sendingTo)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public enum P2PError: LocalizedError, Sendable {
    case nullPointer
    case invalidUTF8
    case nativeError(String)

    public var errorDescription: String? {
        switch self {
        case .nullPointer: String(localized: "P2P 原生库返回空指针", bundle: Bundle.module)
        case .invalidUTF8: String(localized: "P2P 原生库返回了无效的 UTF-8 数据", bundle: Bundle.module)
        case .nativeError(let msg): msg
        }
    }
}

private struct FFIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

private struct FFIEmptyEnvelope: Decodable {
    let ok: Bool
    let error: String?
}

/// Thread-safe Swift wrapper around the shared Rust `DropDrawerP2P.xcframework`.
public final class P2PBridge: Sendable {
    public init() {}

    public func start(
        dataDir: String,
        customRelayUrl: String? = nil,
        disableRelay: Bool = false
    ) throws -> LocalNodeInfo {
        struct StartConfig: Encodable {
            let data_dir: String
            let custom_relay_url: String?
            let disable_relay: Bool
        }
        return try callJSON(
            dropdrawer_p2p_start,
            payload: StartConfig(
                data_dir: dataDir,
                custom_relay_url: customRelayUrl,
                disable_relay: disableRelay
            )
        )
    }

    public func nodeInfo() throws -> LocalNodeInfo {
        try decodeEnvelope(dropdrawer_p2p_node_info())
    }

    public func registerFile(itemId: String, path: String) throws -> RegisteredP2PFile {
        struct Req: Encodable {
            let item_id: String
            let path: String
        }
        return try callJSON(dropdrawer_p2p_register_file, payload: Req(item_id: itemId, path: path))
    }

    public func authorizeToken(
        itemId: String,
        token: String,
        expiresAtIso: String,
        requesterNodeId: String? = nil
    ) throws {
        struct Req: Encodable {
            let item_id: String
            let token: String
            let expires_at: String
            let requester_node_id: String?
        }
        try callJSONVoid(
            dropdrawer_p2p_authorize_token,
            payload: Req(
                item_id: itemId,
                token: token,
                expires_at: expiresAtIso,
                requester_node_id: requesterNodeId
            )
        )
    }

    public func unregisterFile(itemId: String) throws {
        try itemId.withCString { cStr in
            try decodeEmpty(dropdrawer_p2p_unregister_file(cStr))
        }
    }

    public func downloadFile(
        itemId: String,
        remoteNodeId: String,
        remoteRelayUrl: String?,
        remoteDirectAddrs: [String],
        transferToken: String,
        destPath: String,
        skipLegacyResume: Bool = false,
        replicaHash: String? = nil
    ) throws -> String {
        struct Req: Encodable {
            let item_id: String
            let remote_node_id: String
            let remote_relay_url: String?
            let remote_direct_addrs: [String]
            let transfer_token: String
            let dest_path: String
            let skip_legacy_resume: Bool
            let replica_hash: String?
        }
        return try callJSON(
            dropdrawer_p2p_download_file,
            payload: Req(
                item_id: itemId,
                remote_node_id: remoteNodeId,
                remote_relay_url: remoteRelayUrl,
                remote_direct_addrs: remoteDirectAddrs,
                transfer_token: transferToken,
                dest_path: destPath,
                skip_legacy_resume: skipLegacyResume,
                replica_hash: replicaHash
            )
        )
    }

    public func cancelTransfer(transferId: String) throws {
        try transferId.withCString { cStr in
            try decodeEmpty(dropdrawer_p2p_cancel_transfer(cStr))
        }
    }

    public func pollEvents() throws -> [P2PEvent] {
        try decodeEnvelope(dropdrawer_p2p_poll_events())
    }

    public func shutdown() {
        if let ptr = dropdrawer_p2p_shutdown() {
            dropdrawer_p2p_free_string(ptr)
        }
    }

    private func callJSON<Req: Encodable, Res: Decodable>(
        _ fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
        payload: Req
    ) throws -> Res {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw P2PError.invalidUTF8
        }
        return try json.withCString { cStr in
            try decodeEnvelope(fn(cStr))
        }
    }

    private func callJSONVoid<Req: Encodable>(
        _ fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
        payload: Req
    ) throws {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw P2PError.invalidUTF8
        }
        try json.withCString { cStr in
            try decodeEmpty(fn(cStr))
        }
    }

    private func takeString(_ ptr: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let ptr else { throw P2PError.nullPointer }
        defer { dropdrawer_p2p_free_string(ptr) }
        return Data(String(cString: ptr).utf8)
    }

    private func decodeEnvelope<T: Decodable>(_ ptr: UnsafeMutablePointer<CChar>?) throws -> T {
        let raw = try takeString(ptr)
        let env = try JSONDecoder().decode(FFIEnvelope<T>.self, from: raw)
        guard env.ok, let value = env.data else {
            throw P2PError.nativeError(env.error ?? "Unknown P2P FFI error")
        }
        return value
    }

    private func decodeEmpty(_ ptr: UnsafeMutablePointer<CChar>?) throws {
        let raw = try takeString(ptr)
        let env = try JSONDecoder().decode(FFIEmptyEnvelope.self, from: raw)
        guard env.ok else {
            throw P2PError.nativeError(env.error ?? "Unknown P2P FFI error")
        }
    }
}
