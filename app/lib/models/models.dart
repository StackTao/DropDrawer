class UserProfile {
  final String id;
  final String username;

  UserProfile({required this.id, required this.username});

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        username: json['username'] as String,
      );
}

class DeviceInfo {
  final String id;
  final String userId;
  final String name;
  final String platform;
  final String? irohNodeId;
  final String? irohRelayUrl;
  final List<String> directAddrs;
  final bool online;

  DeviceInfo({
    required this.id,
    required this.userId,
    required this.name,
    required this.platform,
    this.irohNodeId,
    this.irohRelayUrl,
    required this.directAddrs,
    required this.online,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String,
        irohNodeId: json['iroh_node_id'] as String?,
        irohRelayUrl: json['iroh_relay_url'] as String?,
        directAddrs: (json['direct_addrs'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        online: json['online'] as bool? ?? false,
      );
}

class DrawerItem {
  final String id;
  final String userId;
  final String ownerDeviceId;
  final String? ownerDeviceName;
  final bool ownerOnline;
  final String? ownerIrohNodeId;
  final String? ownerIrohRelayUrl;
  final List<String> ownerDirectAddrs;
  final String kind; // 'file' | 'text'
  final String name;
  final int size;
  final String? mimeType;
  final String? blake3Hash;
  final String? textContent;
  final String? thumbnailBase64;
  final String transferMode; // 'p2p_only' | 'cloud_cached' | 'hybrid'
  final String? storageBackendId;
  final String? storageBackendName;
  final bool cloudReady;
  final DateTime? expiresAt;
  final DateTime createdAt;

  DrawerItem({
    required this.id,
    required this.userId,
    required this.ownerDeviceId,
    this.ownerDeviceName,
    required this.ownerOnline,
    this.ownerIrohNodeId,
    this.ownerIrohRelayUrl,
    required this.ownerDirectAddrs,
    required this.kind,
    required this.name,
    required this.size,
    this.mimeType,
    this.blake3Hash,
    this.textContent,
    this.thumbnailBase64,
    required this.transferMode,
    this.storageBackendId,
    this.storageBackendName,
    required this.cloudReady,
    this.expiresAt,
    required this.createdAt,
  });

  factory DrawerItem.fromJson(Map<String, dynamic> json) => DrawerItem(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        ownerDeviceId: json['owner_device_id'] as String,
        ownerDeviceName: json['owner_device_name'] as String?,
        ownerOnline: json['owner_online'] as bool? ?? false,
        ownerIrohNodeId: json['owner_iroh_node_id'] as String?,
        ownerIrohRelayUrl: json['owner_iroh_relay_url'] as String?,
        ownerDirectAddrs: (json['owner_direct_addrs'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        kind: json['kind'] as String? ?? 'file',
        name: json['name'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        mimeType: json['mime_type'] as String?,
        blake3Hash: json['blake3_hash'] as String?,
        textContent: json['text_content'] as String?,
        thumbnailBase64: json['thumbnail_base64'] as String?,
        transferMode: json['transfer_mode'] as String? ?? 'p2p_only',
        storageBackendId: json['storage_backend_id'] as String?,
        storageBackendName: json['storage_backend_name'] as String?,
        cloudReady: json['cloud_ready'] as bool? ?? false,
        expiresAt: json['expires_at'] != null
            ? DateTime.tryParse(json['expires_at'] as String)
            : null,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
      );

  bool get canP2p =>
      transferMode != 'cloud_cached' &&
      ownerOnline &&
      ownerIrohNodeId != null &&
      ownerIrohNodeId!.isNotEmpty;
}

class StorageBackendSummary {
  final String id;
  final String name;
  final String kind; // 'local' | 'open_list' | 'web_dav' | 's3'
  final bool isDefault;
  final String displayTarget;

  StorageBackendSummary({
    required this.id,
    required this.name,
    required this.kind,
    required this.isDefault,
    required this.displayTarget,
  });

  factory StorageBackendSummary.fromJson(Map<String, dynamic> json) =>
      StorageBackendSummary(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        isDefault: json['is_default'] as bool? ?? false,
        displayTarget: json['display_target'] as String? ?? '',
      );
}

class P2pSourceInfo {
  final String deviceId;
  final String irohNodeId;
  final String? irohRelayUrl;
  final List<String> directAddrs;
  final String transferToken;

  P2pSourceInfo({
    required this.deviceId,
    required this.irohNodeId,
    this.irohRelayUrl,
    required this.directAddrs,
    required this.transferToken,
  });

  factory P2pSourceInfo.fromJson(Map<String, dynamic> json) => P2pSourceInfo(
        deviceId: json['device_id'] as String,
        irohNodeId: json['iroh_node_id'] as String,
        irohRelayUrl: json['iroh_relay_url'] as String?,
        directAddrs: (json['direct_addrs'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        transferToken: json['transfer_token'] as String,
      );
}

class CloudDownloadInfo {
  final String url;
  final bool isDirectUrl;
  final String backendName;

  CloudDownloadInfo({
    required this.url,
    required this.isDirectUrl,
    required this.backendName,
  });

  factory CloudDownloadInfo.fromJson(Map<String, dynamic> json) =>
      CloudDownloadInfo(
        url: json['url'] as String,
        isDirectUrl: json['is_direct_url'] as bool? ?? false,
        backendName: json['backend_name'] as String? ?? 'Cloud',
      );
}

class DownloadPlan {
  final String itemId;
  final P2pSourceInfo? p2p;
  final CloudDownloadInfo? cloud;

  DownloadPlan({required this.itemId, this.p2p, this.cloud});

  factory DownloadPlan.fromJson(Map<String, dynamic> json) => DownloadPlan(
        itemId: json['item_id'] as String,
        p2p: json['p2p'] != null
            ? P2pSourceInfo.fromJson(json['p2p'] as Map<String, dynamic>)
            : null,
        cloud: json['cloud'] != null
            ? CloudDownloadInfo.fromJson(json['cloud'] as Map<String, dynamic>)
            : null,
      );
}

class ShareLinkInfo {
  final String code;
  final String itemId;
  final String itemName;
  final String itemKind; // 'file' | 'text'
  final int itemSize;
  final int itemCount;
  final bool hasPasscode;
  final int? maxDownloads;
  final int downloadCount;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final String sharePath;

  ShareLinkInfo({
    required this.code,
    required this.itemId,
    required this.itemName,
    required this.itemKind,
    required this.itemSize,
    this.itemCount = 1,
    required this.hasPasscode,
    this.maxDownloads,
    required this.downloadCount,
    this.expiresAt,
    required this.createdAt,
    required this.sharePath,
  });

  factory ShareLinkInfo.fromJson(Map<String, dynamic> json) => ShareLinkInfo(
        code: json['code'] as String,
        itemId: json['item_id'] as String,
        itemName: json['item_name'] as String,
        itemKind: json['item_kind'] as String? ?? 'file',
        itemSize: (json['item_size'] as num?)?.toInt() ?? 0,
        itemCount: (json['item_count'] as num?)?.toInt() ?? 1,
        hasPasscode: json['has_passcode'] as bool? ?? false,
        maxDownloads: (json['max_downloads'] as num?)?.toInt(),
        downloadCount: (json['download_count'] as num?)?.toInt() ?? 0,
        expiresAt: json['expires_at'] != null
            ? DateTime.tryParse(json['expires_at'] as String)
            : null,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
        sharePath: json['share_path'] as String,
      );

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  bool get isExhausted =>
      maxDownloads != null && downloadCount >= maxDownloads!;
}

class TransferProgress {
  final String itemId;
  final int transferred;
  final int total;
  final int speedBps;
  final String channel; // 'p2p_connecting' | 'p2p_direct' | 'p2p_relay' | 'cloud' | 'upload'
  final bool finished;
  final String? savedPath;
  final String? sendingTo;
  final String? error;

  TransferProgress({
    required this.itemId,
    required this.transferred,
    required this.total,
    required this.speedBps,
    required this.channel,
    required this.finished,
    this.savedPath,
    this.sendingTo,
    this.error,
  });

  double get fraction => total > 0 ? (transferred / total).clamp(0.0, 1.0) : 0.0;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
