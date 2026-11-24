import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DrawerWindowService {
  static const _channel = MethodChannel('com.dropdrawer/drawer_window');

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
  void Function()? onStateChanged;
  void Function()? onPasteShortcut;
  bool _dragGuidePending = false;

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
          onStateChanged?.call();
        } else if (call.method == 'onPasteShortcut') {
          onPasteShortcut?.call();
        }
      });
    }
  }

  bool get isWindows => Platform.isWindows;
  bool get supportsEdgeDrawer => Platform.isMacOS || isWindows;
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
    await _channel.invokeMethod('moveDrawerHandle', {'save': save});
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
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setModalOpen', {'open': open});
  }

  Future<void> setMainDrawerActive(bool active) async {
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('setMainDrawerActive', {'active': active});
  }

  Future<void> revealInFinder(String path) async {
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('revealInFinder', {'path': path});
  }

  Future<List<String>> pickFilesNative() async {
    if (isWindows) {
      final files = await FilePicker.platform.pickFiles(allowMultiple: true);
      return files?.paths.whereType<String>().toList() ?? const [];
    }
    if (!supportsEdgeDrawer) return const [];
    final raw = await _channel.invokeMethod<List<dynamic>>('pickFiles');
    return (raw ?? const []).map((e) => e.toString()).toList();
  }

  /// Reads files, screenshots/images, or text from system clipboard.
  Future<Map<String, dynamic>> readClipboardSmart() async {
    if (supportsEdgeDrawer) {
      Map<String, String>? arguments;
      if (isWindows) {
        final dir = await getApplicationSupportDirectory();
        final name = 'Screenshot-${DateTime.now().microsecondsSinceEpoch}.png';
        arguments = {'imagePath': p.join(dir.path, 'clipboard', name)};
      }
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readClipboard',
        arguments,
      );
      return raw != null ? Map<String, dynamic>.from(raw) : {'kind': 'empty'};
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
    if (!supportsEdgeDrawer) return false;
    final ok = await _channel.invokeMethod<bool>('openExternalUrl', {'url': url});
    return ok ?? false;
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
    if (!supportsEdgeDrawer) return null;
    try {
      if (isWindows) {
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

  Future<void> quitApp() async {
    if (!supportsEdgeDrawer) return;
    await _channel.invokeMethod('quitApp');
  }

  Future<String?> showNativeMoreMenu({
    required double anchorRightX,
    required double anchorBottomY,
    required String username,
  }) async {
    if (!supportsEdgeDrawer) return null;
    return _channel.invokeMethod<String>('showMoreMenu', {
      'x': anchorRightX,
      'y': anchorBottomY,
      'username': username,
    });
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
