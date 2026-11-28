import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/drawer_window_service.dart';
import '../services/p2p_ffi.dart';
import 'app_update_controller.dart';
import '../l10n/l10n.dart';

class DropDrawerController extends ChangeNotifier {
  static final bool _tracksLiveP2pPath =
      Platform.isWindows || Platform.isMacOS || Platform.isIOS || Platform.isAndroid;

  final DrawerWindowService windowService = DrawerWindowService();
  final P2pFfiBridge p2p = P2pFfiBridge();

  ApiClient? _api;
  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _p2pPollTimer;
  Timer? _wsReconnectTimer;
  /// Failed reconnects in a row; resets once a socket is open.
  int _wsReconnectAttempt = 0;
  static final _jitter = math.Random();
  Timer? _nodeAddressTimer;
  Map<String, String> _publishedFiles = const {};
  final Set<String> _replicaDownloads = {};
  int _deviceRevision = 0;

  String serverUrl = 'http://127.0.0.1:8080';
  String? token;
  UserProfile? user;
  AccountInfo? accountInfo;
  String? deviceId;
  String deviceName = Platform.localHostname.replaceAll(
    RegExp(r'\.local$', caseSensitive: false),
    '',
  );

  bool p2pReady = false;
  LocalNodeInfo? localNodeInfo;
  bool wsConnected = false;
  bool _bootstrapping = false;
  bool get isBootstrapping => _bootstrapping;

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
  /// Persisted cloud uploads interrupted by app exit/network loss, resumed automatically.
  final Map<String, ({String path, String? storageBackendId})> _pendingCloudUploads = {};
  final Map<String, TransferProgress> activeTransfers = {};
  final Map<String, TransferProgress> outgoingTransfers = {};
  final Set<String> _cancellingSends = {};
  final Map<String, String> _p2pDownloadIds = {};
  final Map<String, TransferCancelToken> _activeCancelTokens = {};
  final List<String> _pendingSharedFiles = [];
  final List<String> _pendingSharedTexts = [];
  String? _statusBanner;

  /// Increases with every new status message, so the UI can tell a repeated
  /// message apart from one it has already shown (mobile shows each as a toast).
  int bannerSerial = 0;
  String? get statusBanner => _statusBanner;
  set statusBanner(String? message) {
    _statusBanner = message;
    if (message != null) bannerSerial++;
  }

  /// Files dropped into the drawer that are still being packed, hashed or
  /// created on the server. Shown at the top of the list right away.
  final List<PendingDrop> pendingDrops = [];
  int _pendingDropSeq = 0;

  /// Ticks for transfer progress alone (bytes, speed, route). Only the progress
  /// area of each item listens to it, so a progress stream (every 120 ms, or
  /// every P2P poll) no longer rebuilds the whole drawer.
  final ValueNotifier<int> transferTicks = ValueNotifier(0);

  /// App updates. Started by [bootstrap], so tests that never bootstrap make
  /// no update requests.
  late final AppUpdateController updates = _createUpdates();
  bool _updatesCreated = false;

  AppUpdateController _createUpdates() {
    _updatesCreated = true;
    return AppUpdateController(window: windowService);
  }
  void _tickTransfers() => transferTicks.value++;

  DropDrawerController({SharedPreferences? initialPrefs}) {
    if (initialPrefs != null) {
      _restorePrefsSync(initialPrefs);
    }
    windowService.onStateChanged = notifyListeners;
    windowService.onSharedPayload = (files, texts) {
      unawaited(handleIncomingSharePayload(files, texts));
    };
  }

  void _restorePrefsSync(SharedPreferences prefs) {
    _dismissedAnnouncementId = prefs.getString('dismissed_announcement');
    serverUrl = prefs.getString('server_url') ?? serverUrl;
    token = prefs.getString('auth_token');
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

    final savedUploadsRaw = prefs.getString('pending_cloud_uploads');
    if (savedUploadsRaw != null) {
      try {
        final decoded = Map<String, dynamic>.from(jsonDecode(savedUploadsRaw) as Map);
        for (final entry in decoded.entries) {
          final raw = entry.value;
          if (raw is Map) {
            final path = raw['path']?.toString();
            final backendId = raw['storage_backend_id']?.toString();
            if (path != null && path.isNotEmpty && File(path).existsSync()) {
              _pendingCloudUploads[entry.key] = (
                path: path,
                storageBackendId: backendId,
              );
            }
          }
        }
      } catch (_) {}
    }

    if (token != null && savedUser != null && savedUserId != null) {
      user = UserProfile(id: savedUserId, username: savedUser);
      deviceId = prefs.getString('device_id.$savedUserId') ??
          prefs.getString('device_id');
      _api ??= ApiClient(baseUrl: serverUrl, token: token);
    }
  }

  bool get isLoggedIn => token != null && user != null;

  // ---- Server policy (admin console switches & announcement) ----

  /// Effective switches for this account; `null` until loaded or on old servers.
  ClientConfig? clientConfig;
  String? _dismissedAnnouncementId;

  bool get browserShareEnabled =>
      clientConfig?.features.browserShareEnabled ?? false;

  bool get canCreateShares => clientConfig?.features.shareCreateEnabled ?? true;
  bool get canUploadToCloud => clientConfig?.features.cloudUploadEnabled ?? true;
  bool get shareRequiresPasscode => clientConfig?.features.shareRequiresPasscode ?? false;
  int? get maxShareExpiresHours => clientConfig?.features.maxShareExpiresHours;
  int? get maxShareDownloads => clientConfig?.features.maxShareDownloads;

  /// Whether a storage backend kind may be added (admin console storage policy).
  bool isStorageKindAllowed(String kind) =>
      !(clientConfig?.features.disabledStorageKinds.contains(kind) ?? false);

  /// The announcement to show, unless the user already closed this revision.
  ClientAnnouncement? get activeAnnouncement {
    final a = clientConfig?.announcement;
    if (a == null || a.id == _dismissedAnnouncementId) return null;
    return a;
  }

  Future<void> dismissAnnouncement() async {
    final a = clientConfig?.announcement;
    if (a == null) return;
    _dismissedAnnouncementId = a.id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dismissed_announcement', a.id);
  }

  Future<void> refreshClientConfig() async {
    final api = _api;
    if (api == null) return;
    try {
      final cfg = await api.fetchClientConfig(deviceId: deviceId);
      if (identical(_api, api)) {
        clientConfig = cfg;
        notifyListeners();
        unawaited(_syncPushRegistration(api, cfg));
      }
    } catch (e) {
      if (identical(_api, api)) await _handleAuthFailure(e);
    }
  }

  /// `<device id>|<token>` the server last accepted, to avoid re-sending it on
  /// every reconnect.
  String? _registeredPushKey;
  bool _pushForeground = true;

  void setPushForeground(bool foreground) {
    if (_pushForeground == foreground) return;
    _pushForeground = foreground;
    final channel = _ws;
    if (wsConnected && channel != null) _publishPushVisibility(channel);
  }

  void _publishPushVisibility(WebSocketChannel channel) {
    if (!windowService.isAndroid) return;
    try {
      channel.sink.add(jsonEncode({
        'type': 'push_visibility',
        'payload': {'foreground': _pushForeground},
      }));
    } on StateError {
      // The next socket will publish the current state after reconnecting.
    }
  }

  /// Registers this Android device for notifications while it is in the background.
  Future<void> _syncPushRegistration(ApiClient api, ClientConfig? cfg) async {
    final options = cfg?.fcm;
    final device = deviceId;
    if (options == null || device == null || !windowService.isAndroid) return;
    final pushToken = await windowService.configurePush(options.toMap());
    if (pushToken == null || pushToken.isEmpty || !identical(_api, api)) return;
    final key = '$device|$pushToken';
    if (_registeredPushKey == key) return;
    try {
      await api.registerPushToken(deviceId: device, provider: 'fcm', pushToken: pushToken);
      _registeredPushKey = key;
    } catch (_) {
      // Retried on the next config refresh.
    }
  }

  /// Retention choices for new items, capped by the administrator's maximum.
  int? get maxItemTtlHours => clientConfig?.features.maxItemTtlHours;

  /// Returns to the login screen when the server rejects this session (forced
  /// sign-out, password reset, disabled account). Returns `true` if it did.
  Future<bool> _handleAuthFailure(Object error) async {
    if (!isLoggedIn || !error.toString().contains('HTTP 401')) return false;
    await logout();
    statusBanner = l10n.yourSessionHasExpiredAnAdministrator;
    return true;
  }

  Future<String?> _appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
  }
  int get activeTransferCount =>
      activeTransfers.values.where((t) => !t.finished).length +
      outgoingTransfers.values.where((t) => !t.finished).length;
  bool get hasActiveTransfers => activeTransferCount > 0;
  @visibleForTesting
  int get pendingCloudUploadCount => _pendingCloudUploads.length;
  bool canDownloadP2p(DrawerItem item) => item.canP2p ||
      (item.transferMode != 'cloud_cached' && devices.any((d) =>
          d.id != deviceId && d.online && d.replicaItems.contains(item.id)));

  int get onlineDeviceCount => displayedDevices.where((d) => d.online).length;

  List<DeviceInfo> get displayedDevices {
    final unique = <(String, bool, String), DeviceInfo>{};
    for (final device in devices) {
      final nodeId = device.irohNodeId;
      final hasNode = nodeId != null && nodeId.isNotEmpty;
      final key = (device.platform, hasNode, hasNode ? nodeId : device.id);
      final shown = unique[key];
      if (shown == null ||
          (device.online && !shown.online) ||
          (device.online == shown.online && device.id == deviceId)) {
        unique[key] = device;
      }
    }
    return unique.values.toList();
  }

  String get defaultStorageBackendName {
    for (final b in storageBackends) {
      if (b.isDefault) return b.name;
    }
    return storageBackends.isNotEmpty ? storageBackends.first.name : l10n.defaultCloudStorage;
  }

  void setBanner(String? message) {
    statusBanner = message;
    notifyListeners();
  }

  Future<void> bootstrap() async {
    _bootstrapping = true;
    unawaited(updates.start());
    final prefs = await SharedPreferences.getInstance();
    _restorePrefsSync(prefs);

    if (isLoggedIn) {
      // Transition immediately to DrawerScreen before network/P2P init so the
      // login screen never flashes on relaunch.
      _bootstrapping = false;
      notifyListeners();

      await windowService.refreshSystemSettings();
      if (localFilePaths.isNotEmpty) {
        await windowService.pruneClipboardFiles(localFilePaths.values);
      }
      unawaited(windowService.pruneCacheFiles([
        ...localFilePaths.values,
        ..._pendingCloudUploads.values.map((upload) => upload.path),
      ]));
      try {
        await _postLoginInit();
      } catch (e) {
        final isUnauthorized = e.toString().contains('HTTP 401');
        final upgradeRequired = e.toString().contains('HTTP 426');
        if (upgradeRequired) {
          // The administrator requires a newer app; keep the session and point to the updater.
          statusBanner = _serverMessage(e) ?? l10n.thisVersionIsTooOldUpdate;
          unawaited(updates.check());
        } else if (isUnauthorized) {
          statusBanner = l10n.yourSessionHasExpiredSignIn;
          // The server rejected this token; don't keep it on disk.
          await prefs.remove('auth_token');
          token = null;
          user = null;
          _api = null;
          if (windowService.supportsEdgeDrawer) {
            await windowService.setEdgeDrawerMode(false);
          }
        } else {
          statusBanner = l10n.canTReachTheServerRight;
          if (deviceId != null) {
            unawaited(_connectWs());
          }
        }
      }
    } else {
      await windowService.refreshSystemSettings();
      _bootstrapping = false;
      if (windowService.supportsEdgeDrawer) {
        await windowService.setEdgeDrawerMode(false);
      }
    }
    notifyListeners();
  }

  Future<AuthPublicConfig?> fetchServerAuthConfig(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(clean);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return ApiClient(baseUrl: clean).fetchAuthConfig();
  }

  Future<void> sendEmailVerificationCode({
    required String url,
    required String email,
    required String purpose,
  }) async {
    final api = ApiClient(baseUrl: url.trim().replaceAll(RegExp(r'/+$'), ''));
    await api.sendEmailCode(email: email, purpose: purpose);
  }

  Future<void> resetPasswordWithEmail({
    required String url,
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final api = ApiClient(baseUrl: url.trim().replaceAll(RegExp(r'/+$'), ''));
    await api.resetPassword(email: email, code: code, newPassword: newPassword);
  }

  Future<void> refreshAccountInfo() async {
    final api = _api;
    if (api == null) return;
    try {
      final info = await api.getAccountInfo();
      if (identical(_api, api) && info != null) {
        accountInfo = info;
        user = UserProfile(
          id: info.id,
          username: info.username,
          email: info.email,
        );
        notifyListeners();
      }
    } catch (e) {
      if (identical(_api, api)) await _handleAuthFailure(e);
    }
  }

  Future<void> changeOwnPassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    final api = _api;
    if (api == null) return;
    final (tok, profile) = await api.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
      deviceId: deviceId,
    );
    if (!identical(_api, api)) return;
    token = tok;
    user = profile;
    if (accountInfo != null) {
      accountInfo = AccountInfo(
        id: accountInfo!.id,
        username: profile.username,
        email: profile.email,
        emailVerified: accountInfo!.emailVerified,
        hasPassword: true,
        googleLinked: accountInfo!.googleLinked,
        emailBindingAvailable: accountInfo!.emailBindingAvailable,
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', tok);
    // Reconnect WS with the newly issued token_version so live sync stays up.
    _closeWs();
    unawaited(_connectWs());
    notifyListeners();
  }

  Future<void> sendBindEmailCode(String email) async {
    final api = _api;
    if (api == null) return;
    await api.sendBindEmailCode(email);
  }

  Future<void> confirmBindEmail({
    required String email,
    required String code,
    String? currentPassword,
  }) async {
    final api = _api;
    if (api == null) return;
    final info = await api.confirmBindEmail(
      email: email,
      code: code,
      currentPassword: currentPassword,
    );
    if (!identical(_api, api)) return;
    accountInfo = info;
    user = UserProfile(
      id: info.id,
      username: info.username,
      email: info.email,
    );
    notifyListeners();
  }

  Future<void> deleteOwnAccount({
    String? password,
    String? confirmUsername,
  }) async {
    final api = _api;
    if (api == null) return;
    await api.deleteOwnAccount(
      password: password,
      confirmUsername: confirmUsername,
    );
    await logout();
    statusBanner = l10n.accountDeletedBanner;
    notifyListeners();
  }

  Future<void> authenticate({
    required String url,
    required String username,
    required String password,
    required bool isRegister,
    String? email,
    String? emailCode,
    String? inviteCode,
  }) async {
    final api = ApiClient(baseUrl: url.trim().replaceAll(RegExp(r'/+$'), ''));
    final (tok, profile) = isRegister
        ? await api.register(
            username,
            password,
            email: email,
            emailCode: emailCode,
            inviteCode: inviteCode,
          )
        : await api.login(username, password);
    await _finishAuthentication(api, tok, profile);
  }

  Future<void> authenticateWithGoogle({
    required String url,
    required bool Function() isCancelled,
    required void Function() onBrowserOpened,
    String? inviteCode,
  }) async {
    final api = ApiClient(baseUrl: url.trim().replaceAll(RegExp(r'/+$'), ''));
    final clock = Stopwatch()..start();
    final attempt = await api.startGoogleSignIn(inviteCode: inviteCode);
    if (isCancelled()) return;
    if (!await windowService.openExternalUrl(attempt.url)) {
      throw HttpException(l10n.couldnTOpenTheBrowser);
    }
    if (isCancelled()) return;
    onBrowserOpened();
    final expires = Duration(seconds: attempt.expiresIn);
    while (!isCancelled() && clock.elapsed < expires) {
      final session = await api.pollGoogleSignIn(
        state: attempt.state,
        pollKey: attempt.pollKey,
      );
      if (isCancelled()) return;
      if (session != null) {
        final (tok, profile) = session;
        await _finishAuthentication(api, tok, profile);
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!isCancelled()) throw HttpException(l10n.googleSignInTimedOutTry);
  }

  Future<void> _finishAuthentication(
    ApiClient api,
    String tok,
    UserProfile profile,
  ) async {
    serverUrl = api.baseUrl;
    _api = api;
    token = tok;
    user = profile;

    final prefs = await SharedPreferences.getInstance();
    deviceId = prefs.getString('device_id.${profile.id}');
    if (deviceId == null &&
        prefs.getString('server_url') == serverUrl &&
        prefs.getString('user_id') == profile.id) {
      deviceId = prefs.getString('device_id');
    }
    if (deviceId == null) await prefs.remove('device_id');
    await prefs.setString('server_url', serverUrl);
    await prefs.setString('auth_token', tok);
    await prefs.setString('username', profile.username);
    await prefs.setString('user_id', profile.id);

    await _postLoginInit();
    notifyListeners();
  }

  Future<void> logout() async {
    // A signed-out phone must not keep receiving notifications for this account.
    final pushApi = _api;
    final pushDevice = deviceId;
    if (_registeredPushKey != null && pushApi != null && pushDevice != null) {
      unawaited(pushApi.deletePushToken(pushDevice).catchError((_) {}));
    }
    _registeredPushKey = null;
    unawaited(windowService.disablePush());
    _wsReconnectTimer?.cancel();
    _p2pPollTimer?.cancel();
    _closeWs();
    for (final token in _activeCancelTokens.values.toList()) {
      token.cancel();
    }
    for (final id in _p2pDownloadIds.keys) {
      _activeCancelTokens.remove(id);
    }
    _p2pDownloadIds.clear();
    _replicaDownloads.clear();
    _cancellingSends.clear();
    outgoingTransfers.clear();
    activeTransfers.clear();
    _pendingCloudUploads.clear();
    _syncPlatformTransferState();
    p2p.shutdown();

    token = null;
    user = null;
    accountInfo = null;
    _api = null;
    devices = [];
    items = [];
    storageBackends = [];
    shareLinks = [];
    clientConfig = null;
    p2pReady = false;
    localNodeInfo = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('pending_cloud_uploads');
    await windowService.setEdgeDrawerMode(false);
    notifyListeners();
  }

  Future<void> _postLoginInit() async {
    await _startLocalP2pNode();

    final prefs = await SharedPreferences.getInstance();
    deviceName = prefs.getString('device_name') ?? await _defaultDeviceName();
    final dev = await _api!.registerDevice(
      deviceId: deviceId,
      name: deviceName,
      platform: _platformName(),
      irohNodeId: localNodeInfo?.nodeId,
      irohRelayUrl: localNodeInfo?.relayUrl,
      directAddrs: localNodeInfo?.directAddrs ?? const [],
      appVersion: await _appVersion(),
    );
    deviceId = dev.id;
    unawaited(refreshClientConfig());
    await prefs.setString('device_id.${user!.id}', dev.id);
    await prefs.setString('device_id', dev.id);

    storageBackends = await _api!.listStorageBackends();
    try {
      shareLinks = await _api!.listShareLinks();
    } catch (_) {}
    unawaited(_connectWs());

    if (windowService.supportsEdgeDrawer) {
      await windowService.setEdgeDrawerMode(true);
    }
    if (windowService.isMobile) {
      await checkPendingMobileShares();
    }
  }

  Future<void> handleIncomingSharePayload(
    List<String> files,
    List<String> texts,
  ) async {
    if (files.isEmpty && texts.isEmpty) return;
    if (!isLoggedIn || _api == null || deviceId == null) {
      _pendingSharedFiles.addAll(files);
      _pendingSharedTexts.addAll(texts);
      statusBanner = l10n.sharedContentReceivedItWillSync;
      notifyListeners();
      return;
    }
    if (files.isNotEmpty) {
      await addFilesToDrawer(files);
    }
    for (final text in texts) {
      if (text.trim().isNotEmpty) {
        await addTextToDrawer(text);
      }
    }
  }

  Future<void> checkPendingMobileShares() async {
    if (!windowService.isMobile) return;
    final payload = await windowService.consumePendingShares();
    final files = <String>[
      ..._pendingSharedFiles,
      ...(payload['files'] ?? const []),
    ];
    final texts = <String>[
      ..._pendingSharedTexts,
      ...(payload['texts'] ?? const []),
    ];
    _pendingSharedFiles.clear();
    _pendingSharedTexts.clear();
    if (files.isNotEmpty || texts.isNotEmpty) {
      await handleIncomingSharePayload(files, texts);
    }
  }

  Future<void> refreshOnResume() async {
    if (!isLoggedIn || _api == null || deviceId == null) {
      if (windowService.isMobile) {
        await checkPendingMobileShares();
      }
      return;
    }
    final channel = _ws;
    if (wsConnected && channel != null) _publishNodeAddress(channel);
    await manualRefresh();
    if (windowService.isMobile) {
      await checkPendingMobileShares();
    }
  }

  Future<void> manualRefresh() async {
    final api = _api;
    if (api == null || !isLoggedIn) return;
    unawaited(_connectWs());
    unawaited(refreshClientConfig());
    final revision = _deviceRevision;
    final deviceRefresh = api.listDevices().then<void>((fetched) {
      if (identical(_api, api) && revision == _deviceRevision) {
        devices = fetched;
        _deviceRevision++;
        notifyListeners();
      }
    }, onError: (Object _) {});
    try {
      final fetched = await api.listItems();
      if (identical(_api, api)) {
        items = fetched;
        _resumePendingCloudUploads();
        await refreshStorageBackends();
        if (identical(_api, api)) notifyListeners();
      }
    } catch (e) {
      if (identical(_api, api) && await _handleAuthFailure(e)) return;
    }
    await deviceRefresh;
  }

  Future<String> _defaultDeviceName() async {
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        final info = DeviceInfoPlugin();
        final model = Platform.isIOS
            ? (await info.iosInfo).model
            : (await info.androidInfo).model;
        if (model.trim().isNotEmpty) return model.trim();
      } catch (_) {}
      return Platform.isIOS ? 'iPhone / iPad' : 'Android';
    }
    return Platform.localHostname.replaceAll(
      RegExp(r'\.local$', caseSensitive: false),
      '',
    );
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

    // Progress-only events just tick the progress listeners; anything that
    // ends a transfer or saves a file changes what the drawer shows.
    var structural = false;
    for (final ev in events) {
      final itemId = ev['item_id'] as String;
      final pathKind = ev['path_kind'] as String? ?? 'unknown';
      final channel = switch (pathKind) {
        'direct' when ev['sending_to'] == null && _replicaDownloads.contains(itemId) => 'p2p_replica',
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
          structural = true;
          if (_cancellingSends.remove(transferId) && !cancelled && err == null) {
            statusBanner = l10n.sent;
          }
          outgoingTransfers.remove(transferId);
          if (cancelled) statusBanner = l10n.sendingCanceled;
          if (err != null) statusBanner = l10n.p2pSendFailed(err);
        } else {
          outgoingTransfers[transferId] = progress;
        }
        continue;
      }
      if (_p2pDownloadIds[itemId] != transferId) continue;
      final token = _activeCancelTokens[itemId];
      if (finished || savedPath != null) structural = true;
      final wasReplica = finished && _replicaDownloads.remove(itemId);
      if (finished) {
        _p2pDownloadIds.remove(itemId);
        _activeCancelTokens.remove(itemId);
      }
      if (cancelled) {
        structural = true;
        activeTransfers.remove(itemId);
        statusBanner = l10n.downloadCanceled;
        continue;
      }
      activeTransfers[itemId] = progress;
      if (savedPath != null) {
        localFilePaths[itemId] = savedPath;
        unawaited(_persistLocalFilePaths());
      }
      if (finished && err != null) {
        final item = items.where((i) => i.id == itemId).firstOrNull;
        if (item != null && wasReplica && token?.isCancelled != true) {
          unawaited(downloadItem(item, preferReplica: false));
        } else if (item != null && item.cloudReady && token?.isCancelled != true) {
          unawaited(downloadItem(item, cloudOnly: true));
        }
      } else if (finished && savedPath != null) {
        final transport = switch (channel) {
          'p2p_replica' => l10n.lanCopy,
          'p2p_direct' => 'P2P Direct',
          'p2p_relay' => 'P2P Relay',
          _ => 'P2P',
        };
        statusBanner = 'Downloaded via $transport';
      }
    }
    if (structural) {
      _syncPlatformTransferState();
      notifyListeners();
    } else {
      _syncPlatformTransferState();
      _tickTransfers();
    }
  }

  Future<void> _connectWs() async {
    final api = _api;
    final id = deviceId;
    if (api == null || id == null || _ws != null) return;
    _wsReconnectTimer?.cancel();

    final channel = api.connectWebSocket(id);
    _ws = channel;
    _wsSub = channel.stream.listen(
      (message) {
        if (!identical(_ws, channel)) return;
        try {
          _onWsMessage(message);
        } catch (e) {
          // One malformed event must not end the subscription.
          debugPrint('ignored WebSocket event: $e');
        }
      },
      onError: (Object _) => _scheduleReconnect(channel),
      onDone: () => _scheduleReconnect(channel),
    );
    try {
      await channel.ready;
    } catch (_) {
      _scheduleReconnect(channel);
      return;
    }

    if (!identical(_ws, channel)) return;
    wsConnected = true;
    _wsReconnectAttempt = 0;
    _publishPushVisibility(channel);
    notifyListeners();
    if (!p2pReady) return;

    _publishNodeAddress(channel, force: true);
    _nodeAddressTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _publishNodeAddress(channel);
    });
  }

  Future<void> _answerBrowserShare(
    WebSocketChannel channel,
    Map<String, dynamic> request,
  ) async {
    String? answer;
    try {
      answer = await p2p.prepareBrowserShare(request);
    } catch (_) {
      // The browser can use its cloud fallback if the local file is unavailable.
    }
    if (!identical(_ws, channel)) return;
    channel.sink.add(jsonEncode({
      'type': 'browser_share_answer',
      'payload': {'session_id': request['session_id'], 'sdp': answer},
    }));
  }

  void _publishNodeAddress(WebSocketChannel channel, {bool force = false}) {
    if (!p2pReady || !identical(_ws, channel)) return;
    try {
      final info = p2p.nodeInfo();
      if (force && p2p.supportsBrowserShare) {
        channel.sink.add('{"type":"browser_share_ready","payload":{}}');
      }
      final visible = {for (final item in items) item.id};
      final files = Map<String, String>.fromEntries(
        info.readyFiles.entries.where((entry) => visible.contains(entry.key)),
      );
      if (force || !mapEquals(_publishedFiles, files)) {
        channel.sink.add(jsonEncode({
          'type': 'update_ready_files',
          'payload': {'files': files},
        }));
        _publishedFiles = files;
      }
      final previous = localNodeInfo;
      if (!force && previous?.nodeId == info.nodeId &&
          previous?.relayUrl == info.relayUrl &&
          listEquals(previous?.directAddrs, info.directAddrs)) {
        return;
      }
      channel.sink.add(jsonEncode({
        'type': 'update_node_addr',
        'payload': {
          'iroh_node_id': info.nodeId,
          'iroh_relay_url': info.relayUrl,
          'direct_addrs': info.directAddrs,
        },
      }));
      localNodeInfo = info;
    } catch (_) {}
  }

  void _closeWs() {
    _nodeAddressTimer?.cancel();
    final channel = _ws;
    _ws = null;
    final subscription = _wsSub;
    _wsSub = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (channel != null) {
      unawaited(channel.sink.close().catchError((Object _) {}));
    }
    wsConnected = false;
  }

  /// 3 s, 6 s, 12 s … up to a minute, with jitter so devices that lost the
  /// same server don't all come back at once (and phones don't spin the radio).
  Duration _nextReconnectDelay() {
    final step = math.min(_wsReconnectAttempt, 5);
    _wsReconnectAttempt++;
    final base = math.min(3000 * (1 << step), 60000);
    return Duration(milliseconds: base + _jitter.nextInt(1000));
  }

  void _scheduleReconnect(WebSocketChannel channel) {
    if (!identical(_ws, channel)) return;
    _closeWs();
    if (isLoggedIn) {
      // The server also drops the socket when it revokes this session; a cheap
      // authenticated call tells the two cases apart.
      unawaited(refreshClientConfig());
      _wsReconnectTimer = Timer(_nextReconnectDelay(), _connectWs);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _api = null;
    _wsReconnectTimer?.cancel();
    _p2pPollTimer?.cancel();
    _closeWs();
    unawaited(windowService.setActiveTransferCount(0));
    unawaited(windowService.updateMobileTransferService(active: false));
    transferTicks.dispose();
    if (_updatesCreated) updates.dispose();
    super.dispose();
  }

  void _onWsMessage(dynamic raw) {
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = map['type'] as String;
    final payload = map['payload'];

    switch (type) {
      case 'config_changed':
        unawaited(refreshClientConfig());
        break;
      case 'snapshot':
        _deviceRevision++;
        final pMap = payload as Map<String, dynamic>;
        devices = (pMap['devices'] as List<dynamic>)
            .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        items = (pMap['items'] as List<dynamic>)
            .map((e) => DrawerItem.fromJson(e as Map<String, dynamic>))
            .toList();
        _resumePendingCloudUploads();
        break;
      case 'device_updated':
        _deviceRevision++;
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
        if (_pendingCloudUploads.remove(itemId) != null) {
          unawaited(_persistPendingCloudUploads());
        }
        if (p2pReady) {
          try {
            p2p.unregisterFile(itemId);
          } catch (_) {}
        }
        break;
      case 'browser_share_offer':
        final channel = _ws;
        if (channel != null && p2pReady && p2p.supportsBrowserShare &&
            payload is Map<String, dynamic>) {
          unawaited(_answerBrowserShare(channel, payload));
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
              requesterNodeId: authMap['requester_node_id'] as String?,
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
    // Show every dropped entry immediately; each placeholder is replaced by the
    // real item once it has been created on the server.
    final drops = [
      for (final path in paths)
        PendingDrop(
          id: 'pending-${_pendingDropSeq++}',
          name: FileSystemEntity.isDirectorySync(path)
              ? '${p.basename(path)}.zip'
              : p.basename(path),
        ),
    ];
    pendingDrops.addAll(drops);
    notifyListeners();
    for (var i = 0; i < paths.length; i++) {
      try {
        await _addFileToDrawer(paths[i]);
      } finally {
        pendingDrops.remove(drops[i]);
        notifyListeners();
      }
    }
  }

  Future<void> _addFileToDrawer(String rawPath) async {
    String filePath = rawPath;
    String? displayName;

    if (FileSystemEntity.isDirectorySync(rawPath)) {
      final folderName = p.basename(rawPath);
      statusBanner = l10n.packingFolder(folderName);
      notifyListeners();
      try {
        filePath = await _archiveFolderToZip(rawPath);
        displayName = '$folderName.zip';
      } catch (e) {
        statusBanner = l10n.packingFolderFailed(folderName, e);
        notifyListeners();
        return;
      }
    }

    final file = File(filePath);
    if (!await file.exists()) return;

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

    bool shouldRegisterP2p;
    bool shouldAutoCloud;
    String mode;

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
    if (shouldAutoCloud && !canUploadToCloud) {
      // The administrator turned cloud uploads off: fall back to P2P only.
      shouldAutoCloud = false;
      shouldRegisterP2p = p2pReady;
      mode = 'p2p_only';
      statusBanner = l10n.cloudUploadsAreTurnedOffOn;
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
      // Show it now instead of waiting for the server's item_added broadcast.
      if (!items.any((e) => e.id == created.id)) items.insert(0, created);

      if (shouldRegisterP2p) {
        try {
          p2p.registerFile(created.id, filePath);
        } catch (e) {
          statusBanner = l10n.p2pRegisterNotice(e);
        }
      }

      if (shouldAutoCloud) {
        unawaited(cacheItemToCloud(created.id, filePath));
      } else {
        statusBanner = l10n.addedP2pOnly(name);
      }
    } catch (e) {
      statusBanner = l10n.addItemFailed(name, e);
    }
    notifyListeners();
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
    statusBanner = l10n.textSyncedToAllDevices;
    notifyListeners();
  }

  String recipientName(String nodeId) =>
      devices.where((d) => d.irohNodeId == nodeId).firstOrNull?.name ??
      (nodeId.length > 8 ? nodeId.substring(0, 8) : nodeId);

  void cancelTransfer(String itemId) {
    _activeCancelTokens[itemId]?.cancel();
  }

  bool isCancelling(String itemId) => _activeCancelTokens[itemId]?.isCancelled ?? false;
  bool isCancellingSend(String transferId) => _cancellingSends.contains(transferId);

  void cancelOutgoingTransfer(String transferId) {
    if (!_cancellingSends.add(transferId)) return;
    try {
      p2p.cancelTransfer(transferId);
      setBanner(l10n.cancelingSend);
    } catch (e) {
      _cancellingSends.remove(transferId);
      setBanner(l10n.cancelSendFailed(e));
    }
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

  Future<void> _persistPendingCloudUploads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_pendingCloudUploads.isEmpty) {
        await prefs.remove('pending_cloud_uploads');
        return;
      }
      final encoded = <String, dynamic>{
        for (final e in _pendingCloudUploads.entries)
          e.key: {
            'path': e.value.path,
            if (e.value.storageBackendId != null)
              'storage_backend_id': e.value.storageBackendId,
          },
      };
      await prefs.setString('pending_cloud_uploads', jsonEncode(encoded));
    } catch (_) {}
  }

  void _resumePendingCloudUploads() {
    if (_api == null || _pendingCloudUploads.isEmpty) return;
    final itemsById = {for (final item in items) item.id: item};
    var changed = false;
    final toResume = <({String itemId, String path, String? backendId})>[];
    for (final entry in _pendingCloudUploads.entries.toList()) {
      final item = itemsById[entry.key];
      if (item == null || item.cloudReady || !File(entry.value.path).existsSync()) {
        _pendingCloudUploads.remove(entry.key);
        changed = true;
        continue;
      }
      if (!_activeCancelTokens.containsKey(entry.key)) {
        toResume.add((
          itemId: entry.key,
          path: entry.value.path,
          backendId: entry.value.storageBackendId,
        ));
      }
    }
    if (changed) {
      unawaited(_persistPendingCloudUploads());
    }
    for (final task in toResume) {
      unawaited(cacheItemToCloud(
        task.itemId,
        task.path,
        storageBackendId: task.backendId,
      ));
    }
  }

  void _syncPlatformTransferState() {
    final running = activeTransfers.values.where((t) => !t.finished).toList();
    final outgoingCount =
        outgoingTransfers.values.where((t) => !t.finished).length;
    final count = running.length + outgoingCount;
    unawaited(windowService.setActiveTransferCount(count));
    if (!windowService.isAndroid) return;
    if (count == 0) {
      unawaited(windowService.updateMobileTransferService(active: false));
      return;
    }
    final primary = running.isNotEmpty
        ? running.first
        : outgoingTransfers.values.firstWhere((t) => !t.finished);
    final itemName =
        items.where((i) => i.id == primary.itemId).firstOrNull?.name ?? l10n.file;
    final isUpload = primary.channel == 'upload';
    final pct = primary.total > 0
        ? ((primary.transferred * 100) ~/ primary.total).clamp(0, 100)
        : 0;
    final title = isUpload
        ? (count > 1 ? l10n.uploadingFilesToCloud(count) : l10n.uploadingToTheCloud)
        : (count > 1 ? l10n.transferringFiles(count) : l10n.transferringFile);
    final detail = primary.awaitingUploadConfirmation
        ? l10n.itemAwaitingCloudConfirmation(itemName)
        : (primary.total > 0 ? '$itemName · $pct%' : itemName);
    unawaited(windowService.updateMobileTransferService(
      active: true,
      title: title,
      detail: detail,
      progress: primary.awaitingUploadConfirmation ? 0 : pct,
      max: primary.awaitingUploadConfirmation ? 0 : 100,
    ));
  }

  /// Uploads a local drawer file to the user's configured cloud/server storage backend.
  Future<void> cacheItemToCloud(
    String itemId,
    String filePath, {
    String? storageBackendId,
  }) async {
    if (_api == null) return;
    if (!canUploadToCloud) {
      statusBanner = l10n.cloudUploadsAreTurnedOffOn2;
      notifyListeners();
      return;
    }
    final file = File(filePath);
    if (!await file.exists()) {
      if (_pendingCloudUploads.remove(itemId) != null) {
        unawaited(_persistPendingCloudUploads());
      }
      return;
    }
    final total = await file.length();
    if (_activeCancelTokens.containsKey(itemId)) return;
    final cancelToken = TransferCancelToken();
    _activeCancelTokens[itemId] = cancelToken;

    _pendingCloudUploads[itemId] = (
      path: filePath,
      storageBackendId: storageBackendId,
    );
    unawaited(_persistPendingCloudUploads());

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
    _syncPlatformTransferState();
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
          _syncPlatformTransferState();
          _tickTransfers();
        },
        onAwaitingConfirmation: () {
          activeTransfers[itemId] = TransferProgress(
            itemId: itemId,
            transferred: total,
            total: total,
            speedBps: 0,
            channel: 'upload',
            finished: false,
            awaitingUploadConfirmation: true,
          );
          _syncPlatformTransferState();
          _tickTransfers();
        },
      );
      _pendingCloudUploads.remove(itemId);
      unawaited(_persistPendingCloudUploads());
      activeTransfers[itemId] = TransferProgress(
        itemId: itemId,
        transferred: total,
        total: total,
        speedBps: 0,
        channel: 'upload',
        finished: true,
        savedPath: filePath,
      );
      statusBanner = l10n.savedToBackend(defaultStorageBackendName);
    } on TransferCancelledException {
      _pendingCloudUploads.remove(itemId);
      unawaited(_persistPendingCloudUploads());
      activeTransfers.remove(itemId);
      statusBanner = l10n.uploadCanceled;
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
      statusBanner = l10n.cloudUploadFailed(e);
    } finally {
      _activeCancelTokens.remove(itemId);
      _syncPlatformTransferState();
    }
    notifyListeners();
  }

  /// Downloads an item using P2P-first strategy, automatically falling back to cloud storage.
  Future<void> downloadItem(DrawerItem item, {
    bool cloudOnly = false,
    bool preferReplica = true,
  }) async {
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
      if (activeTransfers[item.id]?.channel == 'preparing') {
        _activeCancelTokens.remove(item.id);
        activeTransfers.remove(item.id);
        setBanner(l10n.downloadCanceled);
      } else {
        setBanner(l10n.cancelingDownload);
      }
    });
    notifyListeners();
    try {
      final downloadsDir = await _resolveDownloadDir();
      if (cancel.isCancelled) return;
      final destPath = availableDownloadPath(
        downloadsDir,
        _downloadFileName(item.name),
        previousPath: localFilePaths[item.id],
      );
      final plan = await _api!.getDownloadPlan(
        item.id,
        requesterDeviceId: deviceId!,
        preferReplica: preferReplica && !cloudOnly,
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
          replicaHash: plan.p2p!.replicaHash,
          destPath: destPath,
          skipLegacyResume: _legacyNameIsShared(item, destPath),
        );
        _p2pDownloadIds[item.id] = id;
        if (plan.p2p!.replicaHash != null) _replicaDownloads.add(item.id);
        cancel.attach(() {
          try {
            p2p.cancelTransfer(id);
          } catch (e) {
            setBanner(l10n.cancelDownloadFailed(e));
          }
        });
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

      throw StateError(l10n.theSourceDeviceIsOfflineAnd);
    } catch (e) {
      if (_activeCancelTokens[item.id] != cancel) return;
      activeTransfers.remove(item.id);
      statusBanner = cancel.isCancelled ? l10n.downloadCanceled : l10n.downloadFailedError(e);
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
    _syncPlatformTransferState();
    notifyListeners();

    try {
      final saved = await _api!.downloadFromCloud(
        cloud: cloud,
        destPath: destPath,
        cancelToken: cancelToken,
        onProgress: (rec, tot) {
          if (cancelToken.isCancelled || _activeCancelTokens[itemId] != cancelToken) {
            return;
          }
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
          _syncPlatformTransferState();
          _tickTransfers();
        },
      );

      localFilePaths[itemId] = saved;
      if (p2pReady) {
        try {
          p2p.registerFile(itemId, saved);
        } catch (_) {}
      }
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
      statusBanner = l10n.downloadedFromBackend(cloud.backendName);
    } on TransferCancelledException {
      if (_activeCancelTokens[itemId] == cancelToken) {
        activeTransfers.remove(itemId);
        statusBanner = l10n.downloadCanceled;
      }
    } catch (e) {
      if (cancelToken.isCancelled) return;
      activeTransfers[itemId] = TransferProgress(
        itemId: itemId,
        transferred: 0,
        total: expectedSize,
        speedBps: 0,
        channel: 'cloud',
        finished: true,
        error: e.toString(),
      );
      statusBanner = l10n.cloudDownloadFailed(e);
    }
    _syncPlatformTransferState();
    notifyListeners();
  }

  Future<void> deleteItem(String itemId) async {
    if (_api == null) return;
    await _api!.deleteItem(itemId);
    localFilePaths.remove(itemId);
    if (_pendingCloudUploads.remove(itemId) != null) {
      unawaited(_persistPendingCloudUploads());
    }
    unawaited(_persistLocalFilePaths());
    activeTransfers.remove(itemId);
    _syncPlatformTransferState();
    notifyListeners();
  }

  /// Batch downloads the given file items (or all downloadable files in drawer).
  Future<void> batchDownloadItems(List<DrawerItem> targets) async {
    final files = targets
        .where((it) => it.kind == 'file' && (canDownloadP2p(it) || it.cloudReady))
        .toList();
    if (files.isEmpty) {
      statusBanner = l10n.nothingToDownloadTextItemsAnd;
      notifyListeners();
      return;
    }

    statusBanner = l10n.downloadingFilesBatch(files.length);
    notifyListeners();
    var okCount = 0;
    for (final item in files) {
      try {
        await downloadItem(item);
        okCount++;
      } catch (_) {}
    }
    final dir = await _resolveDownloadDir();
    statusBanner = l10n.downloadsStartedTo(okCount, dir);
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
      statusBanner = l10n.theSelectedItemsAreAlreadyIn;
      notifyListeners();
      return;
    }

    statusBanner = l10n.uploadingFilesBatchTo(eligible.length, defaultStorageBackendName);
    notifyListeners();
    for (final item in eligible) {
      final path = localFilePaths[item.id];
      if (path != null) {
        await cacheItemToCloud(item.id, path);
      }
    }
    statusBanner = l10n.savedFilesToCloud(eligible.length);
    notifyListeners();
  }

  Future<void> batchDeleteItems(List<String> ids) async {
    if (ids.isEmpty) return;
    await _batchDeleteDrawerItems(itemIds: ids);
  }

  /// Clears the entire cross-device drawer and deletes associated cloud blobs.
  Future<void> clearDrawer() async {
    if (items.isEmpty) return;
    await _batchDeleteDrawerItems(clearAll: true);
  }

  Future<void> _batchDeleteDrawerItems({
    List<String> itemIds = const [],
    bool clearAll = false,
  }) async {
    final api = _api;
    if (api == null) return;
    try {
      final result = await api.batchDeleteItems(
        itemIds: itemIds,
        clearAll: clearAll,
      );
      if (!identical(api, _api)) return;
      final deletedIds = result.deletedIds.toSet();
      items.removeWhere((item) => deletedIds.contains(item.id));
      for (final id in deletedIds) {
        localFilePaths.remove(id);
        _pendingCloudUploads.remove(id);
        activeTransfers.remove(id);
        if (p2pReady) {
          try {
            p2p.unregisterFile(id);
          } catch (_) {}
        }
      }
      unawaited(_persistLocalFilePaths());
      unawaited(_persistPendingCloudUploads());
      _syncPlatformTransferState();
      final deleted = deletedIds.length;
      final failed = result.failedIds.length;
      if (failed > 0) {
        statusBanner = l10n.clearedWithFailures(deleted, failed);
      } else if (clearAll && items.isEmpty) {
        statusBanner = l10n.drawerCleared(deleted);
      } else {
        statusBanner = l10n.removedItems(deleted);
      }
    } catch (_) {
      if (!identical(api, _api)) return;
      statusBanner = l10n.couldnTConfirmTheCleanupTry;
    }
    notifyListeners();
  }

  Future<void> setDropPolicy(String policy) async {
    defaultDropPolicy = policy;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('drop_policy', policy);
    final mb = autoCloudThresholdBytes ~/ (1024 * 1024);
    if (policy == 'p2p_only') {
      statusBanner = l10n.newFilesP2pOnlyNothingIs;
    } else if (policy == 'cloud_cached') {
      statusBanner = l10n.policyAlwaysUpload(defaultStorageBackendName);
    } else {
      statusBanner = l10n.policySmart(mb);
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
        ? l10n.downloadFolderResetToTheDefault
        : l10n.downloadFolderChanged(customDownloadDir!);
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
  /// Older servers require a cloud copy before creating a file share.
  Future<ShareLinkInfo> createShareLinkForItems(
    List<DrawerItem> targets, {
    String? title,
    String? passcode,
    int? expiresHours,
    int? maxDownloads,
  }) async {
    if (_api == null) {
      throw StateError(l10n.notConnectedToTheServer);
    }
    if (!canCreateShares) {
      throw StateError(l10n.shareLinksAreTurnedOffOn);
    }
    if (targets.isEmpty) {
      throw StateError(l10n.selectAtLeastOneItem);
    }

    for (final item in targets) {
      if (!browserShareEnabled && item.kind == 'file' && !item.cloudReady) {
        final localPath = localFilePaths[item.id];
        if (localPath == null || !File(localPath).existsSync()) {
          throw StateError(
            l10n.fileOnlyOnSourceDevice(item.name),
          );
        }
        statusBanner = l10n.savingBeforeSharing(item.name);
        notifyListeners();
        await cacheItemToCloud(item.id, localPath);
        final latestTransfer = activeTransfers[item.id];
        if (latestTransfer?.error != null) {
          throw StateError(l10n.autoUploadFailed(item.name, latestTransfer!.error!));
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
    statusBanner = l10n.shareLinkCreated(buildFullShareUrl(link.sharePath));
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
    statusBanner = l10n.shareLinkRevoked;
    notifyListeners();
  }

  int _storageRevision = 0;

  Future<void> refreshStorageBackends() async {
    final api = _api;
    if (api == null) return;
    final revision = ++_storageRevision;
    final backends = await api.listStorageBackends();
    if (!identical(api, _api) || revision != _storageRevision) return;
    storageBackends = backends;
    notifyListeners();
  }

  Future<void> setDefaultStorageBackend(String id) async {
    final api = _api;
    if (api == null) throw StateError(l10n.notConnectedToServer);
    final backends = await api.setDefaultStorageBackend(id);
    if (!identical(api, _api)) return;
    _storageRevision++;
    storageBackends = backends;
    notifyListeners();
  }

  Future<int?> getStorageCapacity(String id) async {
    final api = _api;
    if (api == null) throw StateError(l10n.notConnectedToServer);
    return api.getStorageCapacity(id);
  }

  Future<void> updateStorageBackend(
    String id, {
    required String name,
    required Map<String, dynamic> config,
  }) async {
    final api = _api;
    if (api == null) throw StateError(l10n.notConnectedToServer);
    final backends = await api.updateStorageBackend(id, name: name, config: config);
    if (!identical(api, _api)) return;
    _storageRevision++;
    storageBackends = backends;
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
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final powershell = p.join(
        systemRoot,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      if (File(powershell).existsSync()) {
        final res = await Process.run(
          powershell,
          const [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'Add-Type -AssemblyName System.IO.Compression.FileSystem; '
                r'[System.IO.Compression.ZipFile]::CreateFromDirectory('
                r'$env:DROPDRAWER_ZIP_SRC, $env:DROPDRAWER_ZIP_DST, '
                r'[System.IO.Compression.CompressionLevel]::Optimal, '
                r'$true, [System.Text.Encoding]::UTF8)',
          ],
          environment: {
            'DROPDRAWER_ZIP_SRC': folderPath,
            'DROPDRAWER_ZIP_DST': outZip,
          },
        );
        if (res.exitCode == 0 && await File(outZip).exists()) {
          return outZip;
        }
        final partial = File(outZip);
        if (await partial.exists()) await partial.delete();
      }

      // Fallback to Windows built-in bsdtar (explicit System32 path avoids Git Bash GNU tar).
      final systemTar = p.join(systemRoot, 'System32', 'tar.exe');
      if (!File(systemTar).existsSync()) {
        throw StateError('Windows archive utility not found');
      }
      final res = await Process.run(systemTar, [
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
    // A folder named like "-T…" must not be read as a zip option.
    final source = folderName.startsWith('-') ? './$folderName' : folderName;
    final res = await Process.run(
      'zip',
      ['-r', '-q', outZip, source],
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

  bool _legacyNameIsShared(DrawerItem item, String destPath) {
    final legacy = p.setExtension(destPath, '.dropdrawer.part');
    final stem = p.basenameWithoutExtension(destPath).toLowerCase();
    return localFilePaths.values.any((path) => p.equals(path, legacy)) ||
        items.any((other) => other.id != item.id && other.kind == 'file' &&
            p.basenameWithoutExtension(_downloadFileName(other.name)).toLowerCase() == stem);
  }

  String _downloadFileName(String name) =>
      safeDownloadFileName(name, windows: Platform.isWindows);

  Future<String> _resolveDownloadDir() async {
    if (customDownloadDir != null && customDownloadDir!.trim().isNotEmpty) {
      return customDownloadDir!;
    }
    if (Platform.isIOS) {
      final doc = await getApplicationDocumentsDirectory();
      return p.join(doc.path, 'DropDrawer');
    }
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        return p.join(ext.path, 'DropDrawer');
      }
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

/// Reduces a drawer item name (which comes from the server) to a single safe
/// file name, so a download can never be written outside the download folder.
@visibleForTesting
String safeDownloadFileName(String name, {required bool windows}) {
  // Keep only the last path segment, whichever separator the sender used.
  var safe = name.split(RegExp(r'[/\\]')).last;
  safe = safe.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_');
  if (windows) {
    safe = safe
        .replaceAll(RegExp(r'[<>:"|?*]'), '_')
        .replaceFirst(RegExp(r'[. ]+$'), '');
    final stem = safe.split('.').first.trimRight().toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$')
        .hasMatch(stem)) {
      safe = '_$safe';
    }
  }
  if (safe.trim().isEmpty || safe == '.' || safe == '..') return 'download';
  return safe;
}

/// Picks where to save a download named [name] in [dir] without replacing an
/// unrelated file that already has that name: `photo.png` becomes
/// `photo (1).png`, and so on. [previousPath], where this item was saved before,
/// may be reused so re-downloading an item replaces its own earlier copy. A name
/// whose only trace is an unfinished `.dropdrawer.part` is still free, so an
/// interrupted transfer resumes under the same name.
@visibleForTesting
String availableDownloadPath(String dir, String name, {String? previousPath}) {
  bool usable(String candidate) =>
      (previousPath != null && p.equals(previousPath, candidate)) ||
      FileSystemEntity.typeSync(candidate, followLinks: false) ==
          FileSystemEntityType.notFound;

  final preferred = p.join(dir, name);
  if (usable(preferred)) return preferred;
  final stem = p.basenameWithoutExtension(name);
  final ext = p.extension(name);
  for (var i = 1; i < 10000; i++) {
    final candidate = p.join(dir, '$stem ($i)$ext');
    if (usable(candidate)) return candidate;
  }
  return p.join(dir, '$stem (${DateTime.now().millisecondsSinceEpoch})$ext');
}

/// A dropped file that has not become a drawer item yet.
class PendingDrop {
  final String id;
  final String name;

  PendingDrop({required this.id, required this.name});
}

/// User-facing text for an error from [ApiClient] or the controller: drops the
/// `HttpException:` / `HTTP 4xx:` / `Bad state:` prefixes and keeps the server's message.
String describeError(Object error) {
  final message = _serverMessage(error);
  if (message != null) return message;
  return error
      .toString()
      .replaceFirst('HttpException: ', '')
      .replaceFirst('Bad state: ', '');
}

/// Body of an `HttpException('HTTP <code>: <body>')` from [ApiClient], if any.
String? _serverMessage(Object error) {
  final text = error.toString();
  final idx = text.indexOf(RegExp(r'HTTP \d{3}: '));
  if (idx < 0) return null;
  final body = text.substring(idx).replaceFirst(RegExp(r'HTTP \d{3}: '), '').trim();
  return body.isEmpty ? null : body;
}
