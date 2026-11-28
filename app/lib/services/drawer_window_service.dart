import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum DrawerDragPhase { start, update, end }

/// Outcome of handing a downloaded, verified package to the platform.
enum UpdateInstallResult {
  /// Desktop: the app quits and the new version starts. Android: the system
  /// installer is showing.
  installing,
  /// Android: "install unknown apps" must be allowed for DropDrawer first.
  permissionRequired,
  /// The package is signed by a different identity than the running app.
  signatureMismatch,
  /// macOS: the app's location cannot be written by this user.
  notWritable,
  /// Android: the package's version code is not newer.
  versionTooOld,
  unavailable,
}

class DrawerWindowService {
  static const _channel = MethodChannel('com.dropdrawer/drawer_window');
  static const _mobileChannel = MethodChannel('com.dropdrawer/mobile');

  bool edgeMode = false;
  bool expanded = true;
  bool pinned = false;
  /// 'collapsed' | 'drag_pill' | 'drag_zone' | 'expanded'
  String drawerMode = 'expanded';
  /// 'left' | 'right'
  String dockSide = 'right';
  bool hotkeyEnabled = true;
  String hotkeyLabel = Platform.isWindows ? 'Alt+Shift+D' : '⌥⇧D';
  bool hasGlobalHotkeyPermission = false;
  String hotkeyEngine = 'local_only';
  bool launchAtLogin = false;
  bool showDockIcon = false;

  /// Windows: whether the Mica/Acrylic system backdrop is on (the user setting)
  /// and whether DWM actually applied it (Windows 11 22H2 and later).
  bool windowsBackdropEnabled = true;
  bool windowsBackdrop = false;
  bool modalOpen = false;
  int _lastActiveTransferCount = 0;
  bool _mobileTransferActive = false;
  int _lastMobileTransferNotifyMs = 0;
  void Function()? onStateChanged;
  void Function()? onPasteShortcut;
  void Function(List<String> files, List<String> texts)? onSharedPayload;
  bool _dragGuidePending = false;
  bool _handleMovePending = false;
  bool _drawerDragUpdatePending = false;

  DrawerWindowService() {
    if (supportsEdgeDrawer) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onDrawerStateChanged') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          edgeMode = args['edgeMode'] as bool? ?? edgeMode;
          expanded = args['expanded'] as bool? ?? expanded;
          pinned = args['pinned'] as bool? ?? pinned;
          drawerMode = args['mode'] as String? ?? (expanded ? 'expanded' : 'collapsed');
          dockSide = args['dockSide'] as String? ?? dockSide;
          hotkeyEnabled = args['hotkeyEnabled'] as bool? ?? hotkeyEnabled;
          hotkeyLabel = args['hotkeyLabel'] as String? ?? hotkeyLabel;
          hasGlobalHotkeyPermission =
              args['hasGlobalHotkeyPermission'] as bool? ??
                  hasGlobalHotkeyPermission;
          hotkeyEngine = args['hotkeyEngine'] as String? ?? hotkeyEngine;
          launchAtLogin = args['launchAtLogin'] as bool? ?? launchAtLogin;
          showDockIcon = args['showDockIcon'] as bool? ?? showDockIcon;
          windowsBackdrop = args['backdrop'] as bool? ?? windowsBackdrop;
          windowsBackdropEnabled =
              args['backdropEnabled'] as bool? ?? windowsBackdropEnabled;
          onStateChanged?.call();
          unawaited(_confirmFrameDrawn(drawerMode));
        } else if (call.method == 'onPasteShortcut') {
          onPasteShortcut?.call();
        }
      });
    }
    if (isMobile) {
      _mobileChannel.setMethodCallHandler((call) async {
        if (call.method == 'onSharedPayload') {
          final args = call.arguments is Map
              ? Map<String, dynamic>.from(call.arguments as Map)
              : const <String, dynamic>{};
          final files = (args['files'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
          final texts = (args['texts'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList();
          if (files.isNotEmpty || texts.isNotEmpty) {
            onSharedPayload?.call(files, texts);
          }
        }
      });
    }
  }

  /// The native window hides itself while switching modes and reappears once
  /// Flutter has drawn a frame for the new mode, so the old layout is never
  /// shown stretched into the resized window.
  Future<void> _confirmFrameDrawn(String mode) async {
    final binding = SchedulerBinding.instance;
    binding.scheduleFrame();
    await binding.endOfFrame;
    if (drawerMode != mode) return;
    try {
      await _channel.invokeMethod('drawerFrameReady', {'mode': mode});
    } catch (_) {
      // Older native runners fall back to their own reveal timeout.
    }
  }

  bool get isWindows => Platform.isWindows;
  bool get isIOS => Platform.isIOS;
  bool get isAndroid => Platform.isAndroid;
  bool get isMobile => isIOS || isAndroid;
  bool get supportsEdgeDrawer => Platform.isMacOS || isWindows;
  bool get needsMacTrafficLightPadding => Platform.isMacOS && !edgeMode;
  String get pasteShortcutLabel => isWindows ? 'Ctrl+V' : '⌘V';

  Future<void> showDragGuide() async {
    if (!isWindows || drawerMode != 'collapsed' || _dragGuidePending) return;
    _dragGuidePending = true;
    try {
      await _channel.invokeMethod('showDragGuide');
    } finally {
      _dragGuidePending = false;
    }
  }

  Future<void> moveDrawerHandle({bool save = false}) async {
    if (!isWindows) return;
    if (!save && _handleMovePending) return;
    _handleMovePending = true;
    try {
      await _channel.invokeMethod('moveDrawerHandle', {'save': save});
    } finally {
      _handleMovePending = false;
    }
  }

  Future<void> dragExpandedDrawer(DrawerDragPhase phase) async {
    if (!supportsEdgeDrawer) return;
    if (phase != DrawerDragPhase.update) {
      await _channel.invokeMethod('dragExpandedDrawer', phase.name);
      return;
    }
    if (_drawerDragUpdatePending) return;
    _drawerDragUpdatePending = true;
    try {
      await _channel.invokeMethod('dragExpandedDrawer', phase.name);
    } finally {
      _drawerDragUpdatePending = false;
    }
  }

  Future<void> setEdgeDrawerMode(bool enabled) async {
    edgeMode = enabled;
    expanded = true;
    pinned = false;
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setEdgeDrawerMode', {'enabled': enabled});
    onStateChanged?.call();
  }

  Future<void> expandDrawer() async {
    expanded = true;
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('expandDrawer');
    onStateChanged?.call();
  }

  Future<void> collapseDrawer() async {
    expanded = false;
    pinned = false;
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('collapseDrawer');
    onStateChanged?.call();
  }

  Future<void> setPinned(bool value) async {
    pinned = value;
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setPinned', {'pinned': value});
    onStateChanged?.call();
  }

  Future<void> setDockSide(String side) async {
    dockSide = side == 'left' ? 'left' : 'right';
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setDockSide', {'side': dockSide});
    onStateChanged?.call();
  }

  Future<void> setModalOpen(bool open) async {
    modalOpen = open;
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setModalOpen', {'open': open});
  }

  Future<void> setMainDrawerActive(bool active) async {
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setMainDrawerActive', {'active': active});
  }

  /// Tells macOS/Windows native runners how many transfers are currently in
  /// flight so user-initiated Quit (⌘Q / tray menu) can warn before exiting.
  Future<void> setActiveTransferCount(int count) async {
    final normalized = count < 0 ? 0 : count;
    if (normalized == _lastActiveTransferCount) return;
    _lastActiveTransferCount = normalized;
    if (!supportsEdgeDrawer) return;
    try {
      await _channel.invokeMethod('setActiveTransferCount', {'count': normalized});
    } catch (_) {}
  }

  /// Sends tray/menu/panel/alert titles in the UI language to the macOS and
  /// Windows runners, which fall back to Chinese until this arrives.
  Future<void> setNativeStrings(Map<String, String> strings) async {
    if (!supportsEdgeDrawer) return;
    try {
      await _channel.invokeMethod('setNativeStrings', strings);
    } catch (_) {}
  }

  /// Starts/updates/stops the Android dataSync Foreground Service so cloud
  /// uploads & downloads continue uninterrupted when the app is backgrounded.
  Future<void> updateMobileTransferService({
    required bool active,
    String title = '',
    String detail = '',
    int progress = 0,
    int max = 0,
  }) async {
    if (!isAndroid) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (active && _mobileTransferActive && now - _lastMobileTransferNotifyMs < 500) {
      return;
    }
    if (!active && !_mobileTransferActive) return;
    _mobileTransferActive = active;
    _lastMobileTransferNotifyMs = now;
    try {
      await _mobileChannel.invokeMethod('updateTransferNotification', {
        'active': active,
        'title': title,
        'detail': detail,
        'progress': progress,
        'max': max,
      });
    } catch (_) {}
  }

  /// Initializes Firebase with the server's options and returns this device's
  /// FCM token, or `null` when push is unavailable (no Google Play services,
  /// or an older app build). Also asks for the notification permission.
  Future<String?> configurePush(Map<String, String> options) async {
    if (!isAndroid) return null;
    try {
      return await _mobileChannel.invokeMethod<String>('configurePush', options);
    } catch (_) {
      return null;
    }
  }

  /// Stops push delivery to this device (sign-out).
  Future<void> disablePush() async {
    if (!isAndroid) return;
    try {
      await _mobileChannel.invokeMethod('disablePush');
    } catch (_) {}
  }

  Future<void> revealInFinder(String path) async {
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('revealInFinder', {'path': path});
  }

  Future<List<String>> pickFilesNative() async {
    if (isWindows || isMobile) {
      final files = await FilePicker.platform.pickFiles(allowMultiple: true);
      return files?.paths.whereType<String>().toList() ?? const [];
    }
    if (!supportsEdgeDrawer) return const [];
    final raw = await _channel.invokeMethod<List<dynamic>>('pickFiles');
    return (raw ?? const []).map((e) => e.toString()).toList();
  }

  Future<List<String>> pickMediaNative() async {
    if (isAndroid) {
      final raw = await _mobileChannel.invokeMethod<List<dynamic>>('pickMedia');
      return (raw ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final files = await FilePicker.platform.pickFiles(
      type: FileType.media,
      allowMultiple: true,
    );
    return files?.paths.whereType<String>().toList() ?? const [];
  }

  Future<Map<String, List<String>>> consumePendingShares() async {
    if (!isMobile) return const {'files': [], 'texts': []};
    try {
      final raw = await _mobileChannel.invokeMethod<Map<dynamic, dynamic>>(
        'consumePendingShares',
      );
      if (raw == null) return const {'files': [], 'texts': []};
      final map = Map<String, dynamic>.from(raw);
      return {
        'files': (map['files'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
        'texts': (map['texts'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList(),
      };
    } catch (_) {
      return const {'files': [], 'texts': []};
    }
  }

  Future<bool> shareFilesNative(List<String> paths) async {
    if (!isMobile || paths.isEmpty) return false;
    try {
      final ok = await _mobileChannel.invokeMethod<bool>(
        'shareFiles',
        {'paths': paths},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens a local file in the system viewer: Quick Look on iOS, the default
  /// app for its type on Android. False when nothing can show it.
  Future<bool> openFileNative(String path) async {
    if (!isMobile || path.isEmpty) return false;
    try {
      final ok = await _mobileChannel.invokeMethod<bool>(
        'openFile',
        {'path': path},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> shareTextNative(String text) async {
    if (!isMobile || text.trim().isEmpty) return false;
    try {
      final ok = await _mobileChannel.invokeMethod<bool>(
        'shareText',
        {'text': text},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> saveToGalleryNative(String path) async {
    if (!isMobile || path.isEmpty) return false;
    try {
      final ok = await _mobileChannel.invokeMethod<bool>(
        'saveToGallery',
        {'path': path},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Reads files, screenshots/images, or text from system clipboard.
  Future<Map<String, dynamic>> readClipboardSmart() async {
    if (supportsEdgeDrawer) {
      Map<String, String>? arguments;
      if (isWindows) {
        final dir = await getApplicationSupportDirectory();
        final clipDir = Directory(p.join(dir.path, 'clipboard'));
        final name = 'Screenshot-${DateTime.now().microsecondsSinceEpoch}.png';
        arguments = {'imagePath': p.join(clipDir.path, name)};
      }
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readClipboard',
        arguments,
      );
      return raw != null ? Map<String, dynamic>.from(raw) : {'kind': 'empty'};
    }
    if (isMobile) {
      try {
        final dir = await getApplicationSupportDirectory();
        final clipDir = Directory(p.join(dir.path, 'clipboard'));
        final name = 'Screenshot-${DateTime.now().microsecondsSinceEpoch}.png';
        final raw = await _mobileChannel.invokeMethod<Map<dynamic, dynamic>>(
          'readClipboard',
          {'imagePath': p.join(clipDir.path, name)},
        );
        if (raw != null) {
          final map = Map<String, dynamic>.from(raw);
          if (map['kind'] != null && map['kind'] != 'empty') {
            return map;
          }
        }
      } catch (_) {}
    }
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null && clip!.text!.trim().isNotEmpty) {
      return {'kind': 'text', 'text': clip.text!};
    }
    return {'kind': 'empty'};
  }

  /// Writes one or more local file URLs to the OS clipboard so the user can ⌘V into Finder/WeChat/etc.
  Future<bool> copyFileToClipboard(String path) async {
    if (!supportsEdgeDrawer) return false;
    final ok = await _channel.invokeMethod<bool>('copyFileToClipboard', {'path': path});
    return ok ?? false;
  }

  Future<bool> copyFilesToClipboard(List<String> paths) async {
    if (!supportsEdgeDrawer || paths.isEmpty) return false;
    final ok = await _channel.invokeMethod<bool>('copyFilesToClipboard', {'paths': paths});
    return ok ?? false;
  }

  /// Opens an OAuth authorization URL in the system default browser.
  Future<bool> openExternalUrl(String url) async {
    if (isMobile) {
      try {
        final ok = await _mobileChannel.invokeMethod<bool>(
          'openExternalUrl',
          {'url': url},
        );
        return ok ?? false;
      } catch (_) {
        return false;
      }
    }
    if (!supportsEdgeDrawer) return false;
    final ok = await _channel.invokeMethod<bool>('openExternalUrl', {'url': url});
    return ok ?? false;
  }

  /// Installs a verified update package: macOS replaces the app bundle and
  /// relaunches, Windows runs the installer silently and relaunches, Android
  /// opens the system installer.
  Future<UpdateInstallResult> installUpdate(String path) async {
    if (!isAndroid && !supportsEdgeDrawer) return UpdateInstallResult.unavailable;
    final channel = isAndroid ? _mobileChannel : _channel;
    final result = await channel.invokeMethod<String>(
      'installUpdate',
      {'path': path},
    );
    return switch (result) {
      'installing' => UpdateInstallResult.installing,
      'permission_required' => UpdateInstallResult.permissionRequired,
      'signature_mismatch' => UpdateInstallResult.signatureMismatch,
      'not_writable' => UpdateInstallResult.notWritable,
      'version_too_old' => UpdateInstallResult.versionTooOld,
      _ => UpdateInstallResult.unavailable,
    };
  }

  /// macOS: opens a downloaded disk image in Finder for a manual install.
  Future<bool> openUpdatePackage(String path) async {
    if (!supportsEdgeDrawer || isWindows) return false;
    final result = await _channel.invokeMethod<String>(
      'openUpdatePackage',
      {'path': path},
    );
    return result == 'opened';
  }

  Future<String?> pickDirectoryNative() async {
    if (isWindows) return FilePicker.platform.getDirectoryPath();
    if (!supportsEdgeDrawer) return null;
    return _channel.invokeMethod<String>('pickDirectory');
  }

  Future<bool> openDirectoryNative(String path) async {
    if (!supportsEdgeDrawer) return false;
    final ok = await _channel.invokeMethod<bool>('openDirectory', {'path': path});
    return ok ?? false;
  }

  Future<String?> generateThumbnailBase64(String path) async {
    if (!supportsEdgeDrawer && !isMobile) return null;
    try {
      if (isWindows || isMobile) {
        final buffer = await ui.ImmutableBuffer.fromFilePath(path);
        final codec = await ui.instantiateImageCodecWithSize(
          buffer,
          getTargetSize: (width, height) => ui.TargetImageSize(
            width: width >= height && width > 256 ? 256 : null,
            height: height > width && height > 256 ? 256 : null,
          ),
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
            return data == null ? null : base64Encode(data.buffer.asUint8List());
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
      return await _channel.invokeMethod<String>('generateThumbnail', {'path': path});
    } catch (_) {
      return null;
    }
  }

  Future<void> refreshSystemSettings() async {
    if (!supportsEdgeDrawer) return;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getSystemSettings');
      if (raw != null) {
        hotkeyEnabled = raw['hotkeyEnabled'] as bool? ?? hotkeyEnabled;
        hotkeyLabel = raw['hotkeyLabel'] as String? ?? hotkeyLabel;
        hasGlobalHotkeyPermission =
            raw['hasGlobalHotkeyPermission'] as bool? ??
                hasGlobalHotkeyPermission;
        hotkeyEngine = raw['hotkeyEngine'] as String? ?? hotkeyEngine;
        launchAtLogin = raw['launchAtLogin'] as bool? ?? launchAtLogin;
        showDockIcon = raw['showDockIcon'] as bool? ?? showDockIcon;
        dockSide = raw['dockSide'] as String? ?? dockSide;
        windowsBackdrop = raw['backdrop'] as bool? ?? windowsBackdrop;
        windowsBackdropEnabled =
            raw['backdropEnabled'] as bool? ?? windowsBackdropEnabled;
        onStateChanged?.call();
      }
    } catch (_) {}
  }

  Future<void> setShowDockIcon(bool shown) async {
    showDockIcon = shown;
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setShowDockIcon', {'shown': shown});
    onStateChanged?.call();
  }

  Future<void> setWindowsBackdrop(bool enabled) async {
    windowsBackdropEnabled = enabled;
    if (!isWindows) return;
    await _channel.invokeMethod('setBackdrop', {'enabled': enabled});
  }

  Future<void> quitApp() async {
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('quitApp');
  }

  Future<String?> showNativeMoreMenu({
    required double anchorRightX,
    required double anchorBottomY,
    required String username,
  }) async {
    if (!Platform.isMacOS) return null;
    return _channel.invokeMethod<String>('showMoreMenu', {
      'x': anchorRightX,
      'y': anchorBottomY,
      'username': username,
    });
  }

  Future<void> pruneClipboardFiles(Iterable<String> retainedPaths) async {
    if (!isWindows && !isMobile) return;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'clipboard'));
      if (!await dir.exists()) return;
      final retained = retainedPaths.map(p.canonicalize).toSet();
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      final screenshot = RegExp(r'^Screenshot-[0-9]+\.png$');
      await for (final file in dir.list(followLinks: false)) {
        if (file is File && screenshot.hasMatch(p.basename(file.path)) &&
            !retained.contains(p.canonicalize(file.path)) &&
            (await file.lastModified()).isBefore(cutoff)) {
          await file.delete();
        }
      }
    } on FileSystemException {
      // Cache maintenance can be retried at the next startup.
    }
  }

  /// Removes day-old working copies that nothing refers to any more: folder
  /// ZIPs, pasted images (macOS) and files staged for sharing (Android).
  /// Files still listed in [retainedPaths] (drawer items kept on this device,
  /// pending cloud uploads) are never touched.
  Future<void> pruneCacheFiles(Iterable<String> retainedPaths) async {
    final retained = retainedPaths.map(p.canonicalize).toSet();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final dirs = <String>[];
    try {
      final support = await getApplicationSupportDirectory();
      dirs.add(p.join(support.path, 'folder_archives'));
      if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          dirs.add(p.join(home, 'Library', 'Application Support', 'DropDrawer', 'clipboard_images'));
        }
      }
      if (isAndroid) {
        final cache = await getTemporaryDirectory();
        for (final name in const ['shared_incoming', 'picked_media', 'shared_outgoing']) {
          dirs.add(p.join(cache.path, name));
        }
      }
    } catch (_) {
      return;
    }
    for (final path in dirs) {
      final dir = Directory(path);
      try {
        if (!await dir.exists()) continue;
        await for (final file in dir.list(followLinks: false)) {
          if (file is File &&
              !retained.contains(p.canonicalize(file.path)) &&
              (await file.lastModified()).isBefore(cutoff)) {
            await file.delete();
          }
        }
      } on FileSystemException {
        // Cache maintenance can be retried at the next startup.
      }
    }
  }

  Future<bool> requestAccessibilityPermission() async {
    if (!Platform.isMacOS) return false;
    final ok = await _channel.invokeMethod<bool>('requestAccessibilityPermission');
    await refreshSystemSettings();
    return ok ?? false;
  }

  Future<bool> requestInputMonitoringPermission() async {
    if (!Platform.isMacOS) return false;
    final ok = await _channel.invokeMethod<bool>('requestInputMonitoringPermission');
    await refreshSystemSettings();
    return ok ?? false;
  }

  Future<void> setHotkeyEnabled(bool enabled) async {
    hotkeyEnabled = enabled;
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setHotkeyEnabled', {'enabled': enabled});
    onStateChanged?.call();
  }

  Future<Map<String, dynamic>> recordHotkeyNative() async {
    if (!supportsEdgeDrawer) return {'recorded': false};
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('startHotkeyRecording');
    final map = raw != null ? Map<String, dynamic>.from(raw) : {'recorded': false};
    if (map['label'] is String) {
      hotkeyLabel = map['label'] as String;
    }
    onStateChanged?.call();
    return map;
  }

  Future<void> cancelHotkeyRecording() async {
    if (!supportsEdgeDrawer) return;
    try {
      await _channel.invokeMethod('cancelHotkeyRecording');
    } catch (_) {}
  }

  Future<bool> setHotkeyPreset({
    required int keyCode,
    required List<String> modifiers,
  }) async {
    if (!supportsEdgeDrawer) return false;
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'setHotkeyPreset',
      {'keyCode': keyCode, 'modifiers': modifiers},
    );
    if (raw != null) {
      if (raw['label'] is String) {
        hotkeyLabel = raw['label'] as String;
      }
      onStateChanged?.call();
      return raw['ok'] as bool? ?? false;
    }
    return false;
  }

  Future<bool> setLaunchAtLogin(bool enabled) async {
    launchAtLogin = enabled;
    if (!supportsEdgeDrawer) return false;
    final ok = await _channel.invokeMethod<bool>('setLaunchAtLogin', {'enabled': enabled});
    if (isWindows && ok != true) await refreshSystemSettings();
    onStateChanged?.call();
    return ok ?? false;
  }
}
