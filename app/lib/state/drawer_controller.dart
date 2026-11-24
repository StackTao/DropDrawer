import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/drawer_window_service.dart';
import '../services/p2p_ffi.dart';

class DropDrawerController extends ChangeNotifier {
  static final bool _tracksLiveP2pPath = Platform.isWindows || Platform.isMacOS;

  final DrawerWindowService windowService = DrawerWindowService();
  final P2pFfiBridge p2p = P2pFfiBridge();

  ApiClient? _api;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _p2pPollTimer;
  Timer? _wsReconnectTimer;

  String serverUrl = 'http://127.0.0.1:8080';
  String? token;
  UserProfile? user;
  String? deviceId;
  String deviceName = Platform.localHostname.replaceAll(
    RegExp(r'\.local$', caseSensitive: false),
    '',
  );

  bool p2pReady = false;
  LocalNodeInfo? localNodeInfo;
  bool wsConnected = false;

  /// 'smart' (auto-cloud below threshold, P2P for large), 'p2p_only', 'cloud_cached'
  String defaultDropPolicy = 'smart';
  int autoCloudThresholdBytes = 20 * 1024 * 1024; // 20 MB default
  /// Default item TTL in hours (0 = never expires)
  int defaultTtlHours = 0;
  String? customDownloadDir;

  List<DeviceInfo> devices = [];
  List<DrawerItem> items = [];
  List<StorageBackendSummary> storageBackends = [];
  List<ShareLinkInfo> shareLinks = [];

  /// Local file paths owned or already downloaded by this device (enables instant drag-out).
  final Map<String, String> localFilePaths = {};
  final Map<String, TransferProgress> activeTransfers = {};
  final Map<String, TransferProgress> outgoingTransfers = {};
  final Map<String, String> _p2pDownloadIds = {};
  final Map<String, TransferCancelToken> _activeCancelTokens = {};
  String? statusBanner;

  DropDrawerController() {
    windowService.onStateChanged = notifyListeners;
  }

  bool get isLoggedIn => token != null && user != null;
  int get onlineDeviceCount => devices.where((d) => d.online).length;

  String get defaultStorageBackendName {
    for (final b in storageBackends) {
      if (b.isDefault) return b.name;
    }
    return storageBackends.isNotEmpty ? storageBackends.first.name : '默认云盘';
  }

  void setBanner(String? message) {
    statusBanner = message;
    notifyListeners();
  }

  Future<void> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString('server_url') ?? serverUrl;
    token = prefs.getString('auth_token');
    deviceId = prefs.getString('device_id');
    deviceName = prefs.getString('device_name') ?? Platform.localHostname;
    defaultDropPolicy = prefs.getString('drop_policy') ?? 'smart';
    final savedThresholdMb = prefs.getInt('auto_cloud_threshold_mb');
    if (savedThresholdMb != null && savedThresholdMb > 0) {
      autoCloudThresholdBytes = savedThresholdMb * 1024 * 1024;
    }
    defaultTtlHours = prefs.getInt('default_ttl_hours') ?? 0;
    customDownloadDir = prefs.getString('custom_download_dir');
    if (customDownloadDir != null && customDownloadDir!.trim().isEmpty) {
      customDownloadDir = null;
    }
    await windowService.refreshSystemSettings();
    final savedUser = prefs.getString('username');
    final savedUserId = prefs.getString('user_id');

    final savedPathsRaw = prefs.getString('local_file_paths');
    if (savedPathsRaw != null) {
      try {
        final decoded = Map<String, dynamic>.from(jsonDecode(savedPathsRaw) as Map);
        for (final entry in decoded.entries) {
          final path = entry.value.toString();
          if (File(path).existsSync()) {
            localFilePaths[entry.key] = path;
          }
        }
      } catch (_) {}
    }

    if (token != null && savedUser != null && savedUserId != null) {
      user = UserProfile(id: savedUserId, username: savedUser);
      _api = ApiClient(baseUrl: serverUrl, token: token);
      try {
        await _postLoginInit();
      } catch (e) {
        statusBanner = 'Reconnect failed: $e';
        token = null;
        user = null;
        if (windowService.supportsEdgeDrawer) {
          await windowService.setEdgeDrawerMode(false);
        }
      }
    } else if (windowService.supportsEdgeDrawer) {
      await windowService.setEdgeDrawerMode(false);
    }
    notifyListeners();
  }

  Future<void> authenticate({
    required String url,
    required String username,
    required String password,
    required bool isRegister,
  }) async {
    serverUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final api = ApiClient(baseUrl: serverUrl);
    final (tok, profile) = isRegister
        ? await api.register(username, password)
        : await api.login(username, password);

    _api = api;
    token = tok;
    user = profile;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', serverUrl);
    await prefs.setString('auth_token', tok);
    await prefs.setString('username', profile.username);
    await prefs.setString('user_id', profile.id);

    await _postLoginInit();
    notifyListeners();
  }

  Future<void> logout() async {
    _wsReconnectTimer?.cancel();
    _p2pPollTimer?.cancel();
    await _wsSub?.cancel();
    await _ws?.sink.close();
    for (final token in _activeCancelTokens.values.toList()) {
      token.cancel();
    }
    for (final id in _p2pDownloadIds.keys) {
      _activeCancelTokens.remove(id);
    }
    _p2pDownloadIds.clear();
    outgoingTransfers.clear();
    activeTransfers.clear();
    p2p.shutdown();

    token = null;
    user = null;
    _api = null;
    devices = [];
    items = [];
    storageBackends = [];
    shareLinks = [];
    wsConnected = false;
    p2pReady = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await windowService.setEdgeDrawerMode(false);
    notifyListeners();
  }

  Future<void> _postLoginInit() async {
    await _startLocalP2pNode();

    final dev = await _api!.registerDevice(
      deviceId: deviceId,
      name: deviceName,
      platform: _platformName(),
      irohNodeId: localNodeInfo?.nodeId,
      irohRelayUrl: localNodeInfo?.relayUrl,
      directAddrs: localNodeInfo?.directAddrs ?? const [],
    );
    deviceId = dev.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', dev.id);

    storageBackends = await _api!.listStorageBackends();
    try {
      shareLinks = await _api!.listShareLinks();
    } catch (_) {}
    _connectWs();

    if (windowService.supportsEdgeDrawer) {
      await windowService.setEdgeDrawerMode(true);
    }
  }

  Future<void> _startLocalP2pNode() async {
    if (!p2p.loadLibrary()) {
      p2pReady = false;
      statusBanner = 'P2P native lib not loaded — running in Cloud/Relay mode';
      return;
    }
    try {
      final supportDir = await getApplicationSupportDirectory();
      final p2pDir = p.join(supportDir.path, 'iroh_node');
      localNodeInfo = p2p.start(dataDir: p2pDir);
      p2pReady = true;
      // Re-register persisted local files so P2P seeding survives app restarts.
      for (final entry in localFilePaths.entries.toList()) {
        if (File(entry.value).existsSync()) {
          try {
            p2p.registerFile(entry.key, entry.value);
          } catch (_) {}
        } else {
          localFilePaths.remove(entry.key);
        }
      }
      _p2pPollTimer?.cancel();
      _p2pPollTimer = Timer.periodic(
        const Duration(milliseconds: 220),
        (_) => _pollP2pEvents(),
      );
    } catch (e) {
      p2pReady = false;
      statusBanner = 'P2P init warning: $e';
    }
  }

  void _pollP2pEvents() {
    if (!p2pReady) return;
    final events = p2p.pollEvents();
    if (events.isEmpty) return;

    for (final ev in events) {
      final itemId = ev['item_id'] as String;
      final pathKind = ev['path_kind'] as String? ?? 'unknown';
      final channel = switch (pathKind) {
        'direct' => 'p2p_direct',
        'relay' => 'p2p_relay',
        _ => _tracksLiveP2pPath ? 'p2p_connecting' : 'p2p_relay',
      };
      final savedPath = ev['saved_path'] as String?;
      final finished = ev['finished'] as bool? ?? false;
      final err = ev['error'] as String?;

      final transferId = ev['transfer_id'] as String;
      final sendingTo = ev['sending_to'] as String?;
      final cancelled = ev['cancelled'] == true;
      final progress = TransferProgress(
        sendingTo: sendingTo,
        itemId: itemId,
        transferred: (ev['bytes_transferred'] as num?)?.toInt() ?? 0,
        total: (ev['total_bytes'] as num?)?.toInt() ?? 0,
        speedBps: (ev['speed_bps'] as num?)?.toInt() ?? 0,
        channel: channel,
        finished: finished,
        savedPath: savedPath,
        error: err,
      );

      if (sendingTo != null) {
        if (finished) {
          outgoingTransfers.remove(transferId);
          if (cancelled) statusBanner = '已取消发送';
          if (err != null) statusBanner = 'P2P 发送失败：$err';
        } else {
          outgoingTransfers[transferId] = progress;
        }
        continue;
      }
      if (_p2pDownloadIds[itemId] != transferId) continue;
      final token = _activeCancelTokens[itemId];
      if (finished) {
        _p2pDownloadIds.remove(itemId);
        _activeCancelTokens.remove(itemId);
      }
      if (cancelled || (finished && err != null && token?.isCancelled == true)) {
        activeTransfers.remove(itemId);
        statusBanner = '已取消下载';
        continue;
      }
      activeTransfers[itemId] = progress;
      if (savedPath != null) {
        localFilePaths[itemId] = savedPath;
        unawaited(_persistLocalFilePaths());
      }
      if (finished && err != null) {
        final item = items.where((i) => i.id == itemId).firstOrNull;
        if (item != null && item.cloudReady) {
          unawaited(downloadItem(item, cloudOnly: true));
        }
      } else if (finished && savedPath != null) {
        final transport = switch (channel) {
          'p2p_direct' => 'P2P Direct',
          'p2p_relay' => 'P2P Relay',
          _ => 'P2P',
        };
        statusBanner = 'Downloaded via $transport';
      }
    }
    notifyListeners();
  }

  void _connectWs() {
    if (_api == null || deviceId == null) return;
    _wsSub?.cancel();
    _ws?.sink.close();

    try {
      _ws = _api!.connectWebSocket(deviceId!);
      wsConnected = true;
      notifyListeners();

      // Refresh node addr shortly after connecting so relay/direct addrs are published.
      Future.delayed(const Duration(milliseconds: 900), () {
        if (p2pReady && wsConnected) {
          try {
            localNodeInfo = p2p.nodeInfo();
            _ws?.sink.add(jsonEncode({
              'type': 'update_node_addr',
              'payload': {
                'iroh_node_id': localNodeInfo!.nodeId,
                'iroh_relay_url': localNodeInfo!.relayUrl,
                'direct_addrs': localNodeInfo!.directAddrs,
              },
            }));
          } catch (_) {}
        }
      });

      _wsSub = _ws!.stream.listen(
        _onWsMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    wsConnected = false;
    notifyListeners();
    if (!isLoggedIn) return;
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = Timer(const Duration(seconds: 3), _connectWs);
  }

  void _onWsMessage(dynamic raw) {
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = map['type'] as String;
    final payload = map['payload'];

    switch (type) {
      case 'snapshot':
        final pMap = payload as Map<String, dynamic>;
        devices = (pMap['devices'] as List<dynamic>)
            .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        items = (pMap['items'] as List<dynamic>)
            .map((e) => DrawerItem.fromJson(e as Map<String, dynamic>))
            .toList();
        break;
      case 'device_updated':
        final dev = DeviceInfo.fromJson(payload as Map<String, dynamic>);
        final idx = devices.indexWhere((d) => d.id == dev.id);
        if (idx >= 0) {
          devices[idx] = dev;
        } else {
          devices.insert(0, dev);
        }
        // Refresh ownerOnline flag on items owned by this device.
        items = items.map((it) {
          if (it.ownerDeviceId != dev.id) return it;
          return DrawerItem(
            id: it.id,
            userId: it.userId,
            ownerDeviceId: it.ownerDeviceId,
            ownerDeviceName: dev.name,
            ownerOnline: dev.online,
            ownerIrohNodeId: dev.irohNodeId,
            ownerIrohRelayUrl: dev.irohRelayUrl,
            ownerDirectAddrs: dev.directAddrs,
            kind: it.kind,
            name: it.name,
            size: it.size,
            mimeType: it.mimeType,
            blake3Hash: it.blake3Hash,
            textContent: it.textContent,
            thumbnailBase64: it.thumbnailBase64,
            transferMode: it.transferMode,
            storageBackendId: it.storageBackendId,
            storageBackendName: it.storageBackendName,
            cloudReady: it.cloudReady,
            expiresAt: it.expiresAt,
            createdAt: it.createdAt,
          );
        }).toList();
        break;
      case 'item_added':
        final item = DrawerItem.fromJson(payload as Map<String, dynamic>);
        items.removeWhere((e) => e.id == item.id);
        items.insert(0, item);
        break;
      case 'item_updated':
        final item = DrawerItem.fromJson(payload as Map<String, dynamic>);
        final idx = items.indexWhere((e) => e.id == item.id);
        if (idx >= 0) {
          items[idx] = item;
        } else {
          items.insert(0, item);
        }
        break;
      case 'item_deleted':
        final itemId = (payload as Map<String, dynamic>)['item_id'] as String;
        items.removeWhere((e) => e.id == itemId);
        if (p2pReady) {
          try {
            p2p.unregisterFile(itemId);
          } catch (_) {}
        }
        break;
      case 'authorize_p2p_token':
        if (p2pReady) {
          final authMap = payload as Map<String, dynamic>;
          try {
            p2p.authorizeToken(
              itemId: authMap['item_id'] as String,
              token: authMap['token'] as String,
              expiresAtIso: authMap['expires_at'] as String,
            );
          } catch (_) {}
        }
        break;
    }
    notifyListeners();
  }

  /// Drops one or more local files or folders into the cross-device drawer.
  /// Folders are seamlessly zipped (preserving structure & UTF-8 names) before syncing.
  Future<void> addFilesToDrawer(List<String> paths) async {
    if (_api == null || deviceId == null) return;
    for (final rawPath in paths) {
      String filePath = rawPath;
      String? displayName;

      if (FileSystemEntity.isDirectorySync(rawPath)) {
        final folderName = p.basename(rawPath);
        statusBanner = '正在打包文件夹「$folderName」...';
        notifyListeners();
        try {
          filePath = await _archiveFolderToZip(rawPath);
          displayName = '$folderName.zip';
        } catch (e) {
          statusBanner = '打包文件夹「$folderName」失败: $e';
          notifyListeners();
          continue;
        }
      }

      final file = File(filePath);
      if (!await file.exists()) continue;

      final size = await file.length();
      final name = displayName ?? p.basename(filePath);
      final mime = lookupMimeType(filePath) ?? 'application/octet-stream';
      String? thumbBase64;
      final lowerName = name.toLowerCase();
      final isImage = mime.startsWith('image/') ||
          lowerName.endsWith('.png') ||
          lowerName.endsWith('.jpg') ||
          lowerName.endsWith('.jpeg') ||
          lowerName.endsWith('.webp') ||
          lowerName.endsWith('.heic') ||
          lowerName.endsWith('.gif');
      if (isImage) {
        thumbBase64 = await windowService.generateThumbnailBase64(filePath);
      }

      final bool shouldRegisterP2p;
      final bool shouldAutoCloud;
      final String mode;

      if (defaultDropPolicy == 'cloud_cached') {
        shouldRegisterP2p = false;
        shouldAutoCloud = true;
        mode = 'cloud_cached';
      } else if (defaultDropPolicy == 'p2p_only') {
        shouldRegisterP2p = p2pReady;
        shouldAutoCloud = !p2pReady;
        mode = p2pReady ? 'p2p_only' : 'cloud_cached';
      } else {
        // smart: <= threshold caches to cloud in addition to P2P; larger files stay P2P-only.
        shouldRegisterP2p = p2pReady;
        shouldAutoCloud = (size <= autoCloudThresholdBytes) || !p2pReady;
        mode = shouldAutoCloud
            ? (p2pReady ? 'hybrid' : 'cloud_cached')
            : 'p2p_only';
      }

      try {
        final created = await _api!.createItem(
          deviceId: deviceId!,
          kind: 'file',
          name: name,
          size: size,
          mimeType: mime,
          thumbnailBase64: thumbBase64,
          transferMode: mode,
          ttlHours: defaultTtlHours > 0 ? defaultTtlHours : null,
        );

        localFilePaths[created.id] = filePath;
        unawaited(_persistLocalFilePaths());

        if (shouldRegisterP2p) {
          try {
            p2p.registerFile(created.id, filePath);
          } catch (e) {
            statusBanner = 'P2P 注册提示: $e';
          }
        }

        if (shouldAutoCloud) {
          unawaited(cacheItemToCloud(created.id, filePath));
        } else {
          statusBanner = '已加入「$name」(纯 P2P 端到端直连)';
        }
      } catch (e) {
        statusBanner = '添加「$name」失败: $e';
      }
      notifyListeners();
    }
  }

  Future<void> addTextToDrawer(String text) async {
    if (_api == null || deviceId == null || text.trim().isEmpty) return;
    final trimmed = text.trim();
    final preview =
        trimmed.length > 36 ? '${trimmed.substring(0, 36)}...' : trimmed;
    await _api!.createItem(
      deviceId: deviceId!,
      kind: 'text',
      name: preview,
      size: utf8.encode(trimmed).length,
      mimeType: 'text/plain',
      textContent: trimmed,
      transferMode: 'cloud_cached',
      ttlHours: defaultTtlHours > 0 ? defaultTtlHours : null,
    );
    statusBanner = '文本已同步到所有设备';
    notifyListeners();
  }

  String recipientName(String nodeId) =>
      devices.where((d) => d.irohNodeId == nodeId).firstOrNull?.name ??
      nodeId.substring(0, 8);

  void cancelTransfer(String itemId) {
    _activeCancelTokens[itemId]?.cancel();
  }

  Future<void> retryTransfer(DrawerItem item) async {
    final prev = activeTransfers[item.id];
    activeTransfers.remove(item.id);
    notifyListeners();
    if (prev?.channel == 'upload') {
      final path = localFilePaths[item.id];
      if (path != null) {
        await cacheItemToCloud(item.id, path);
        return;
      }
    }
    await downloadItem(item);
  }

  /// Uploads a local drawer file to the user's configured cloud/server storage backend.
  Future<void> cacheItemToCloud(
    String itemId,
    String filePath, {
    String? storageBackendId,
  }) async {
    if (_api == null) return;
    final file = File(filePath);
    if (!await file.exists()) return;
    final total = await file.length();
    if (_activeCancelTokens.containsKey(itemId)) return;
    final cancelToken = TransferCancelToken();
    _activeCancelTokens[itemId] = cancelToken;

    final sw = Stopwatch()..start();
    var lastNotifyMs = 0;

    activeTransfers[itemId] = TransferProgress(
      itemId: itemId,
      transferred: 0,
      total: total,
      speedBps: 0,
      channel: 'upload',
      finished: false,
    );
    notifyListeners();

    try {
      await _api!.uploadItemFile(
        itemId: itemId,
        file: file,
        storageBackendId: storageBackendId,
        cancelToken: cancelToken,
        onProgress: (sent, tot) {
          final elapsedMs = sw.elapsedMilliseconds;
          if (elapsedMs - lastNotifyMs < 120 && sent < tot) return;
          lastNotifyMs = elapsedMs;
          final bps = elapsedMs > 0 ? (sent * 1000 ~/ elapsedMs) : 0;
          activeTransfers[itemId] = TransferProgress(
            itemId: itemId,
            transferred: sent,
            total: tot,
            speedBps: bps,
            channel: 'upload',
            finished: false,
          );
          notifyListeners();
        },
      );
      activeTransfers[itemId] = TransferProgress(
        itemId: itemId,
        transferred: total,
        total: total,
        speedBps: 0,
        channel: 'upload',
        finished: true,
        savedPath: filePath,
      );
      statusBanner = '已转存到「$defaultStorageBackendName」';
    } on TransferCancelledException {
      activeTransfers.remove(itemId);
      statusBanner = '已取消上传';
    } catch (e) {
      activeTransfers[itemId] = TransferProgress(
        itemId: itemId,
        transferred: 0,
        total: total,
        speedBps: 0,
        channel: 'upload',
        finished: true,
        error: e.toString(),
      );
      statusBanner = '上传云端失败: $e';
    } finally {
      _activeCancelTokens.remove(itemId);
    }
    notifyListeners();
  }

  /// Downloads an item using P2P-first strategy, automatically falling back to cloud storage.
  Future<void> downloadItem(DrawerItem item, {bool cloudOnly = false}) async {
    if (_api == null || deviceId == null ||
        _activeCancelTokens.containsKey(item.id)) {
      return;
    }
    final cancel = TransferCancelToken();
    _activeCancelTokens[item.id] = cancel;
    activeTransfers[item.id] = TransferProgress(
      itemId: item.id,
      transferred: 0,
      total: item.size,
      speedBps: 0,
      channel: 'preparing',
      finished: false,
    );
    cancel.attach(() {
      _activeCancelTokens.remove(item.id);
      activeTransfers.remove(item.id);
      setBanner('已取消下载');
    });
    notifyListeners();
    try {
      final downloadsDir = await _resolveDownloadDir();
      if (cancel.isCancelled) return;
      final destPath = p.join(downloadsDir, _downloadFileName(item.name));
      final plan = await _api!.getDownloadPlan(
        item.id,
        requesterDeviceId: deviceId!,
      );
      if (cancel.isCancelled) return;

      if (!cloudOnly && plan.p2p != null && p2pReady &&
          plan.p2p!.deviceId != deviceId) {
        final id = p2p.downloadFile(
          itemId: item.id,
          remoteNodeId: plan.p2p!.irohNodeId,
          remoteRelayUrl: plan.p2p!.irohRelayUrl,
          remoteDirectAddrs: plan.p2p!.directAddrs,
          transferToken: plan.p2p!.transferToken,
          destPath: destPath,
        );
        _p2pDownloadIds[item.id] = id;
        cancel.attach(() => p2p.cancelTransfer(id));
        activeTransfers[item.id] = TransferProgress(
          itemId: item.id,
          transferred: 0,
          total: item.size,
          speedBps: 0,
          channel: _tracksLiveP2pPath ? 'p2p_connecting' : 'p2p_direct',
          finished: false,
        );
        notifyListeners();

        return;
      }

      if (plan.cloud != null) {
        await _downloadViaCloud(item.id, item.size, plan.cloud!, destPath, cancel);
        return;
      }

      throw StateError('来源设备离线，文件尚未存到云端');
    } catch (e) {
      if (_activeCancelTokens[item.id] != cancel) return;
      activeTransfers.remove(item.id);
      statusBanner = cancel.isCancelled ? '已取消下载' : '下载失败：$e';
      notifyListeners();
    } finally {
      if (!_p2pDownloadIds.containsKey(item.id) &&
          _activeCancelTokens[item.id] == cancel) {
        _activeCancelTokens.remove(item.id);
      }
    }
  }

  Future<void> _downloadViaCloud(
    String itemId,
    int expectedSize,
    CloudDownloadInfo cloud,
    String destPath,
    TransferCancelToken cancelToken,
  ) async {
    final sw = Stopwatch()..start();
    var lastNotifyMs = 0;

    activeTransfers[itemId] = TransferProgress(
      itemId: itemId,
      transferred: 0,
      total: expectedSize,
      speedBps: 0,
      channel: 'cloud',
      finished: false,
    );
    notifyListeners();

    try {
      final saved = await _api!.downloadFromCloud(
        cloud: cloud,
        destPath: destPath,
        cancelToken: cancelToken,
        onProgress: (rec, tot) {
          final elapsedMs = sw.elapsedMilliseconds;
          final effTot = tot > 0 ? tot : expectedSize;
          if (elapsedMs - lastNotifyMs < 120 && rec < effTot) return;
          lastNotifyMs = elapsedMs;
          final bps = elapsedMs > 0 ? (rec * 1000 ~/ elapsedMs) : 0;
          activeTransfers[itemId] = TransferProgress(
            itemId: itemId,
            transferred: rec,
            total: effTot,
            speedBps: bps,
            channel: 'cloud',
            finished: false,
          );
          notifyListeners();
        },
      );

      localFilePaths[itemId] = saved;
      unawaited(_persistLocalFilePaths());
      activeTransfers[itemId] = TransferProgress(
        itemId: itemId,
        transferred: expectedSize,
        total: expectedSize,
        speedBps: 0,
        channel: 'cloud',
        finished: true,
        savedPath: saved,
      );
      statusBanner = '已从「${cloud.backendName}」下载完成';
    } on TransferCancelledException {
      activeTransfers.remove(itemId);
      statusBanner = '已取消下载';
    } catch (e) {
      activeTransfers[itemId] = TransferProgress(
        itemId: itemId,
        transferred: 0,
        total: expectedSize,
        speedBps: 0,
        channel: 'cloud',
        finished: true,
        error: e.toString(),
      );
      statusBanner = '云端下载失败: $e';
    }
    notifyListeners();
  }

  Future<void> deleteItem(String itemId) async {
    if (_api == null) return;
    await _api!.deleteItem(itemId);
    localFilePaths.remove(itemId);
    unawaited(_persistLocalFilePaths());
    activeTransfers.remove(itemId);
    notifyListeners();
  }

  /// Batch downloads the given file items (or all downloadable files in drawer).
  Future<void> batchDownloadItems(List<DrawerItem> targets) async {
    final files = targets
        .where((it) => it.kind == 'file' && (it.canP2p || it.cloudReady))
        .toList();
    if (files.isEmpty) {
      statusBanner = '没有可下载的文件（纯文本或离线未上云文件已跳过）';
      notifyListeners();
      return;
    }

    statusBanner = '正在批量下载 ${files.length} 个文件...';
    notifyListeners();
    var okCount = 0;
    for (final item in files) {
      try {
        await downloadItem(item);
        okCount++;
      } catch (_) {}
    }
    final dir = await _resolveDownloadDir();
    statusBanner = '已发起/完成 $okCount 个文件下载 → $dir';
    notifyListeners();
  }

  /// Batch caches local P2P-only items to configured cloud storage.
  Future<void> batchCacheToCloud(List<DrawerItem> targets) async {
    final eligible = targets
        .where((it) =>
            it.kind == 'file' &&
            !it.cloudReady &&
            localFilePaths.containsKey(it.id))
        .toList();
    if (eligible.isEmpty) {
      statusBanner = '所选条目均已存云盘或不在本机';
      notifyListeners();
      return;
    }

    statusBanner = '正在批量上传 ${eligible.length} 个文件到「$defaultStorageBackendName」...';
    notifyListeners();
    for (final item in eligible) {
      final path = localFilePaths[item.id];
      if (path != null) {
        await cacheItemToCloud(item.id, path);
      }
    }
    statusBanner = '已完成 ${eligible.length} 个文件的云端转存';
    notifyListeners();
  }

  /// Batch deletes specific item IDs from drawer & cloud storage.
  Future<void> batchDeleteItems(List<String> ids) async {
    if (_api == null || ids.isEmpty) return;
    final count = await _api!.batchDeleteItems(itemIds: ids);
    for (final id in ids) {
      items.removeWhere((e) => e.id == id);
      localFilePaths.remove(id);
      activeTransfers.remove(id);
      if (p2pReady) {
        try {
          p2p.unregisterFile(id);
        } catch (_) {}
      }
    }
    unawaited(_persistLocalFilePaths());
    statusBanner = '已移出 $count 个条目';
    notifyListeners();
  }

  /// Clears the entire cross-device drawer and deletes associated cloud blobs.
  Future<void> clearDrawer() async {
    if (_api == null || items.isEmpty) return;
    final count = await _api!.batchDeleteItems(clearAll: true);
    for (final it in items) {
      if (p2pReady) {
        try {
          p2p.unregisterFile(it.id);
        } catch (_) {}
      }
    }
    items.clear();
    localFilePaths.clear();
    activeTransfers.clear();
    unawaited(_persistLocalFilePaths());
    statusBanner = '已清空抽屉（共清理 $count 项）';
    notifyListeners();
  }

  Future<void> setDropPolicy(String policy) async {
    defaultDropPolicy = policy;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('drop_policy', policy);
    final mb = autoCloudThresholdBytes ~/ (1024 * 1024);
    if (policy == 'p2p_only') {
      statusBanner = '新文件策略：纯 P2P 直连（不上传服务器/云盘）';
    } else if (policy == 'cloud_cached') {
      statusBanner = '新文件策略：强制上传至「$defaultStorageBackendName」';
    } else {
      statusBanner = '新文件策略：智能分流（<${mb}MB 自动云存，大文件纯 P2P）';
    }
    notifyListeners();
  }

  Future<void> setDefaultTtlHours(int hours) async {
    defaultTtlHours = hours;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('default_ttl_hours', hours);
    notifyListeners();
  }

  Future<void> setAutoCloudThresholdMb(int mb) async {
    autoCloudThresholdBytes = mb * 1024 * 1024;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('auto_cloud_threshold_mb', mb);
    notifyListeners();
  }

  Future<void> setCustomDownloadDir(String? dirPath) async {
    customDownloadDir =
        (dirPath != null && dirPath.trim().isNotEmpty) ? dirPath.trim() : null;
    final prefs = await SharedPreferences.getInstance();
    if (customDownloadDir == null) {
      await prefs.remove('custom_download_dir');
    } else {
      await prefs.setString('custom_download_dir', customDownloadDir!);
    }
    statusBanner = customDownloadDir == null
        ? '已恢复默认下载目录'
        : '下载目录已改为 $customDownloadDir';
    notifyListeners();
  }

  Future<String> getEffectiveDownloadDir() => _resolveDownloadDir();

  String buildFullShareUrl(String sharePath) {
    final cleanBase = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return '$cleanBase$sharePath';
  }

  Future<void> refreshShareLinks() async {
    if (_api == null) return;
    shareLinks = await _api!.listShareLinks();
    notifyListeners();
  }

  /// Creates a public share link for one or multiple drawer items (single file/text or multi-item bundle).
  /// Any selected P2P-only local file not yet cached on cloud/server is uploaded automatically first.
  Future<ShareLinkInfo> createShareLinkForItems(
    List<DrawerItem> targets, {
    String? title,
    String? passcode,
    int? expiresHours,
    int? maxDownloads,
  }) async {
    if (_api == null) {
      throw StateError('未连接到服务器');
    }
    if (targets.isEmpty) {
      throw StateError('请至少选择一个条目');
    }

    for (final item in targets) {
      if (item.kind == 'file' && !item.cloudReady) {
        final localPath = localFilePaths[item.id];
        if (localPath == null || !File(localPath).existsSync()) {
          throw StateError(
            '文件「${item.name}」仅存在于来源设备且尚未上云，请在原设备先点“存云盘”后再分享',
          );
        }
        statusBanner = '外链分享前正在自动转存「${item.name}」到云端...';
        notifyListeners();
        await cacheItemToCloud(item.id, localPath);
        final latestTransfer = activeTransfers[item.id];
        if (latestTransfer?.error != null) {
          throw StateError('「${item.name}」自动上传失败：${latestTransfer!.error}');
        }
      }
    }

    final link = targets.length == 1 && (title == null || title.trim().isEmpty)
        ? await _api!.createShareLink(
            itemId: targets.first.id,
            passcode: passcode,
            expiresHours: expiresHours,
            maxDownloads: maxDownloads,
          )
        : await _api!.createBatchShareLink(
            itemIds: targets.map((e) => e.id).toList(),
            title: title,
            passcode: passcode,
            expiresHours: expiresHours,
            maxDownloads: maxDownloads,
          );
    await refreshShareLinks();
    statusBanner = '已生成外链分享：${buildFullShareUrl(link.sharePath)}';
    notifyListeners();
    return link;
  }

  Future<ShareLinkInfo> createShareLinkForItem(
    DrawerItem item, {
    String? passcode,
    int? expiresHours,
    int? maxDownloads,
  }) {
    return createShareLinkForItems(
      [item],
      passcode: passcode,
      expiresHours: expiresHours,
      maxDownloads: maxDownloads,
    );
  }

  Future<void> revokeShareLink(String code) async {
    if (_api == null) return;
    await _api!.deleteShareLink(code);
    shareLinks.removeWhere((e) => e.code == code);
    statusBanner = '已撤销外链分享';
    notifyListeners();
  }

  Future<void> refreshStorageBackends() async {
    if (_api == null) return;
    storageBackends = await _api!.listStorageBackends();
    notifyListeners();
  }

  Future<void> addStorageBackend({
    required String name,
    required Map<String, dynamic> config,
    bool isDefault = false,
  }) async {
    if (_api == null) return;
    await _api!.createStorageBackend(
      name: name,
      config: config,
      isDefault: isDefault,
    );
    await refreshStorageBackends();
  }

  Future<void> removeStorageBackend(String id) async {
    if (_api == null) return;
    await _api!.deleteStorageBackend(id);
    await refreshStorageBackends();
  }

  Future<(bool, String)> testStorageBackend(String id) async {
    if (_api == null) return (false, 'Not connected');
    return _api!.checkStorageHealth(id);
  }

  Future<String> startGoogleDriveOAuth({
    required String name,
    required String clientId,
    required String clientSecret,
    String folderId = 'root',
    bool isDefault = true,
  }) async {
    if (_api == null) throw StateError('Not connected');
    return _api!.startGoogleOAuth(
      name: name,
      clientId: clientId,
      clientSecret: clientSecret,
      folderId: folderId,
      isDefault: isDefault,
    );
  }

  /// Packs a local folder into a lossless ZIP archive in app cache so it transfers cleanly across all OSes.
  Future<String> _archiveFolderToZip(String folderPath) async {
    final supportDir = await getApplicationSupportDirectory();
    final zipDir = Directory(p.join(supportDir.path, 'folder_archives'));
    await zipDir.create(recursive: true);

    final folderName = p.basename(folderPath);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final outZip = p.join(zipDir.path, '${folderName}_$ts.zip');

    if (Platform.isMacOS) {
      final res = await Process.run('/usr/bin/ditto', [
        '-c',
        '-k',
        '--sequesterRsrc',
        '--keepParent',
        folderPath,
        outZip,
      ]);
      if (res.exitCode != 0) {
        throw StateError('ditto failed: ${res.stderr}');
      }
      return outZip;
    }

    if (Platform.isWindows) {
      final res = await Process.run('tar.exe', [
        '-a', '-c', '-f', outZip, '-C', p.dirname(folderPath), '--', folderName,
      ]);
      if (res.exitCode != 0) {
        final partial = File(outZip);
        if (await partial.exists()) await partial.delete();
        throw StateError('tar failed: ${res.stderr}');
      }
      return outZip;
    }

    // Fallback for other platforms using standard zip CLI if available.
    final parentDir = p.dirname(folderPath);
    final res = await Process.run(
      'zip',
      ['-r', '-q', outZip, folderName],
      workingDirectory: parentDir,
    );
    if (res.exitCode != 0) {
      throw StateError('zip failed: ${res.stderr}');
    }
    return outZip;
  }

  Future<void> _persistLocalFilePaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('local_file_paths', jsonEncode(localFilePaths));
    } catch (_) {}
  }

  String _downloadFileName(String name) {
    if (!Platform.isWindows) return name;
    var safe = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceFirst(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) return 'download';
    final stem = safe.split('.').first.trimRight().toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$')
        .hasMatch(stem)) {
      safe = '_$safe';
    }
    return safe;
  }

  Future<String> _resolveDownloadDir() async {
    if (customDownloadDir != null && customDownloadDir!.trim().isNotEmpty) {
      return customDownloadDir!;
    }
    final dl = await getDownloadsDirectory();
    if (dl != null) {
      return p.join(dl.path, 'DropDrawer');
    }
    final doc = await getApplicationDocumentsDirectory();
    return p.join(doc.path, 'DropDrawer');
  }

  String _platformName() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'web';
  }
}
