import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/models.dart';

class TransferCancelledException implements Exception {
  @override
  String toString() => '传输已取消';
}

class TransferCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void attach(void Function() onCancel) {
    if (_cancelled) {
      try {
        onCancel();
      } catch (_) {}
      return;
    }
    _listeners.add(onCancel);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final fn in callbacks) {
      try {
        fn();
      } catch (_) {}
    }
  }
}

class ApiClient {
  String baseUrl;
  String? token;

  ApiClient({required this.baseUrl, this.token});

  String get _cleanBase => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<(String, UserProfile)> register(String username, String password) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/auth/register'),
      headers: _headers(),
      body: jsonEncode({'username': username, 'password': password}),
    );
    _check(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    token = data['token'] as String;
    return (token!, UserProfile.fromJson(data['user'] as Map<String, dynamic>));
  }

  Future<(String, UserProfile)> login(String username, String password) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/auth/login'),
      headers: _headers(),
      body: jsonEncode({'username': username, 'password': password}),
    );
    _check(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    token = data['token'] as String;
    return (token!, UserProfile.fromJson(data['user'] as Map<String, dynamic>));
  }

  Future<DeviceInfo> registerDevice({
    String? deviceId,
    required String name,
    required String platform,
    String? irohNodeId,
    String? irohRelayUrl,
    List<String> directAddrs = const [],
  }) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/devices'),
      headers: _headers(),
      body: jsonEncode({
        'device_id': deviceId,
        'name': name,
        'platform': platform,
        'iroh_node_id': irohNodeId,
        'iroh_relay_url': irohRelayUrl,
        'direct_addrs': directAddrs,
      }),
    );
    _check(resp);
    return DeviceInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<List<DeviceInfo>> listDevices() async {
    final resp = await http.get(
      Uri.parse('$_cleanBase/api/devices'),
      headers: _headers(),
    );
    _check(resp);
    return (jsonDecode(resp.body) as List<dynamic>)
        .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<DrawerItem>> listItems() async {
    final resp = await http.get(
      Uri.parse('$_cleanBase/api/drawer/items'),
      headers: _headers(),
    );
    _check(resp);
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => DrawerItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DrawerItem> createItem({
    required String deviceId,
    required String kind,
    required String name,
    required int size,
    String? mimeType,
    String? blake3Hash,
    String? textContent,
    String? thumbnailBase64,
    required String transferMode,
    String? storageBackendId,
    int? ttlHours,
  }) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/drawer/items'),
      headers: _headers(),
      body: jsonEncode({
        'device_id': deviceId,
        'kind': kind,
        'name': name,
        'size': size,
        'mime_type': mimeType,
        'blake3_hash': blake3Hash,
        'text_content': textContent,
        'thumbnail_base64': thumbnailBase64,
        'transfer_mode': transferMode,
        'storage_backend_id': storageBackendId,
        'ttl_hours': ttlHours,
      }),
    );
    _check(resp);
    return DrawerItem.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteItem(String itemId) async {
    final resp = await http.delete(
      Uri.parse('$_cleanBase/api/drawer/items/$itemId'),
      headers: _headers(),
    );
    _check(resp);
  }

  Future<int> batchDeleteItems({
    List<String> itemIds = const [],
    bool clearAll = false,
  }) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/drawer/items/batch-delete'),
      headers: _headers(),
      body: jsonEncode({
        'item_ids': itemIds,
        'clear_all': clearAll,
      }),
    );
    _check(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['deleted'] as num?)?.toInt() ?? 0;
  }

  Future<DrawerItem> uploadItemFile({
    required String itemId,
    required File file,
    String? storageBackendId,
    void Function(int sent, int total)? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    final planResp = await http.post(
      Uri.parse('$_cleanBase/api/drawer/items/$itemId/upload-plan'),
      headers: _headers(),
      body: jsonEncode({'storage_backend_id': storageBackendId}),
    );
    _check(planResp);
    final plan = jsonDecode(planResp.body) as Map<String, dynamic>;
    final strategy = plan['strategy'] as String;
    final total = await file.length();

    if (strategy == 'direct_presigned_put') {
      final putUrl = plan['url'] as String;
      final extraHeaders = <String, String>{};
      for (final pair in (plan['headers'] as List<dynamic>? ?? const [])) {
        final list = pair as List<dynamic>;
        extraHeaders[list[0].toString()] = list[1].toString();
      }
      await _streamPutFile(
        Uri.parse(putUrl),
        file,
        extraHeaders,
        total,
        onProgress,
        cancelToken,
      );

      final confirmResp = await http.post(
        Uri.parse('$_cleanBase/api/drawer/items/$itemId/confirm-upload'),
        headers: _headers(),
        body: jsonEncode({
          'storage_backend_id': plan['storage_backend_id'],
          'remote_key': plan['remote_key'],
          'size': total,
        }),
      );
      _check(confirmResp);
      return DrawerItem.fromJson(
          jsonDecode(confirmResp.body) as Map<String, dynamic>);
    } else {
      final relUrl = plan['url'] as String;
      final targetUri = Uri.parse('$_cleanBase$relUrl');
      final bodyStr = await _streamPutFile(
        targetUri,
        file,
        {
          if (token != null) 'Authorization': 'Bearer $token',
          'Content-Type': 'application/octet-stream',
        },
        total,
        onProgress,
        cancelToken,
      );
      return DrawerItem.fromJson(jsonDecode(bodyStr) as Map<String, dynamic>);
    }
  }

  HttpClient _createHttpClient() {
    final client = HttpClient();
    client.findProxy = (uri) {
      if (uri.host == '127.0.0.1' || uri.host == 'localhost') {
        return 'DIRECT';
      }
      return HttpClient.findProxyFromEnvironment(uri);
    };
    return client;
  }

  Future<String> _streamPutFile(
    Uri uri,
    File file,
    Map<String, String> headers,
    int total,
    void Function(int sent, int total)? onProgress,
    TransferCancelToken? cancelToken,
  ) async {
    final client = _createHttpClient();
    cancelToken?.attach(() => client.close(force: true));
    try {
      if (cancelToken?.isCancelled ?? false) {
        throw TransferCancelledException();
      }
      final req = await client.putUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      req.contentLength = total;

      var sent = 0;
      await for (final chunk in file.openRead()) {
        if (cancelToken?.isCancelled ?? false) {
          throw TransferCancelledException();
        }
        req.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent, total);
      }
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('Upload failed (${resp.statusCode}): $body');
      }
      return body;
    } catch (e) {
      if (cancelToken?.isCancelled ?? false) {
        throw TransferCancelledException();
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<DownloadPlan> getDownloadPlan(
    String itemId, {
    required String requesterDeviceId,
  }) async {
    final uri = Uri.parse(
      '$_cleanBase/api/drawer/items/$itemId/download-plan?requester_device_id=${Uri.encodeQueryComponent(requesterDeviceId)}',
    );
    final resp = await http.get(uri, headers: _headers());
    _check(resp);
    return DownloadPlan.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<String> downloadFromCloud({
    required CloudDownloadInfo cloud,
    required String destPath,
    void Function(int received, int total)? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    final uri = cloud.isDirectUrl
        ? Uri.parse(cloud.url)
        : Uri.parse('$_cleanBase${cloud.url}');
    final client = _createHttpClient();
    cancelToken?.attach(() => client.close(force: true));
    IOSink? sink;
    Directory? staging;
    try {
      if (cancelToken?.isCancelled ?? false) {
        throw TransferCancelledException();
      }
      final req = await client.getUrl(uri);
      if (!cloud.isDirectUrl && token != null) {
        req.headers.set('Authorization', 'Bearer $token');
      }
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('Cloud download failed (${resp.statusCode})');
      }
      final total = resp.contentLength > 0 ? resp.contentLength : 0;
      final outFile = File(destPath);
      await outFile.parent.create(recursive: true);
      staging = await outFile.parent.createTemp('.dropdrawer-');
      final partial = File('${staging.path}/download.part');
      sink = partial.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        if (cancelToken?.isCancelled ?? false) {
          throw TransferCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (cancelToken?.isCancelled ?? false) throw TransferCancelledException();
      // Staging is on the same volume. A failed replacement preserves the destination.
      await partial.rename(destPath);
      return destPath;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (cancelToken?.isCancelled ?? false) {
        throw TransferCancelledException();
      }
      rethrow;
    } finally {
      client.close();
      try {
        if (staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  // ---- Public Share Links ----

  Future<ShareLinkInfo> createShareLink({
    required String itemId,
    String? passcode,
    int? expiresHours,
    int? maxDownloads,
  }) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/drawer/items/$itemId/share'),
      headers: _headers(),
      body: jsonEncode({
        'passcode': (passcode != null && passcode.trim().isNotEmpty)
            ? passcode.trim()
            : null,
        'expires_hours': expiresHours,
        'max_downloads': maxDownloads,
      }),
    );
    _check(resp);
    return ShareLinkInfo.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  Future<ShareLinkInfo> createBatchShareLink({
    required List<String> itemIds,
    String? title,
    String? passcode,
    int? expiresHours,
    int? maxDownloads,
  }) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/shares'),
      headers: _headers(),
      body: jsonEncode({
        'item_ids': itemIds,
        'title': (title != null && title.trim().isNotEmpty) ? title.trim() : null,
        'passcode': (passcode != null && passcode.trim().isNotEmpty)
            ? passcode.trim()
            : null,
        'expires_hours': expiresHours,
        'max_downloads': maxDownloads,
      }),
    );
    _check(resp);
    return ShareLinkInfo.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  Future<List<ShareLinkInfo>> listShareLinks() async {
    final resp = await http.get(
      Uri.parse('$_cleanBase/api/shares'),
      headers: _headers(),
    );
    _check(resp);
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => ShareLinkInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteShareLink(String code) async {
    final resp = await http.delete(
      Uri.parse('$_cleanBase/api/shares/$code'),
      headers: _headers(),
    );
    _check(resp);
  }

  // ---- Storage Backends ----

  Future<List<StorageBackendSummary>> listStorageBackends() async {
    final resp = await http.get(
      Uri.parse('$_cleanBase/api/storage'),
      headers: _headers(),
    );
    _check(resp);
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => StorageBackendSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StorageBackendSummary> createStorageBackend({
    required String name,
    required Map<String, dynamic> config,
    bool isDefault = false,
  }) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/storage'),
      headers: _headers(),
      body: jsonEncode({
        'name': name,
        'config': config,
        'is_default': isDefault,
      }),
    );
    _check(resp);
    return StorageBackendSummary.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteStorageBackend(String id) async {
    final resp = await http.delete(
      Uri.parse('$_cleanBase/api/storage/$id'),
      headers: _headers(),
    );
    _check(resp);
  }

  Future<(bool, String)> checkStorageHealth(String id) async {
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/storage/$id/health'),
      headers: _headers(),
    );
    _check(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['ok'] as bool? ?? false, data['message'] as String? ?? '');
  }

  Future<String> startGoogleOAuth({
    required String name,
    required String clientId,
    required String clientSecret,
    String folderId = 'root',
    bool isDefault = true,
  }) async {
    final redirectUri = '$_cleanBase/api/oauth/google/callback';
    final resp = await http.post(
      Uri.parse('$_cleanBase/api/oauth/google/start'),
      headers: _headers(),
      body: jsonEncode({
        'name': name,
        'client_id': clientId,
        'client_secret': clientSecret,
        'folder_id': folderId,
        'is_default': isDefault,
        'redirect_uri': redirectUri,
      }),
    );
    _check(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['auth_url'] as String;
  }

  WebSocketChannel connectWebSocket(String deviceId) {
    final wsBase = _cleanBase
        .replaceFirst(RegExp(r'^https://'), 'wss://')
        .replaceFirst(RegExp(r'^http://'), 'ws://');
    // The JWT goes in a header, not the URL, so proxies do not log it.
    final uri = Uri.parse(
      '$wsBase/ws?device_id=${Uri.encodeQueryComponent(deviceId)}',
    );
    return IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer ${token ?? ''}'},
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 10),
    );
  }

  void _check(http.Response resp) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}: ${resp.body}');
    }
  }
}
