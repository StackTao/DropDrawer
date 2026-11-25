import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';

import '../services/app_update_service.dart';
import '../services/drawer_window_service.dart';
import 'theme.dart';

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({
    super.key,
    required this.windowService,
    this.platform,
    this.updateService,
  });

  final DrawerWindowService windowService;
  final UpdatePlatform? platform;
  final AppUpdateService? updateService;

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  late final AppUpdateService _service =
      widget.updateService ?? AppUpdateService();
  late final UpdatePlatform _platform =
      widget.platform ?? UpdatePlatform.current;

  Version? _installed;
  String? _iosInstaller;
  AppUpdate? _update;
  File? _package;
  String _status = '正在读取当前版本…';
  bool _checking = false;
  bool _opening = false;
  double? _progress;

  bool get _busy => _checking || _opening || _progress != null;

  @override
  void initState() {
    super.initState();
    _readVersion();
  }

  @override
  void dispose() {
    if (widget.updateService == null) _service.close();
    super.dispose();
  }

  Future<void> _readVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _installed = AppUpdateService.installedVersion(info);
        _iosInstaller = info.installerStore;
        _status = _installed == null ? '无法识别当前版本。' : '';
      });
    } catch (_) {
      if (mounted) setState(() => _status = '无法读取当前版本。');
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _status = '正在检查更新…';
      _update = null;
      _package = null;
    });
    try {
      final result = await _service.check(
        _installed!,
        _platform,
        iosInstaller: _iosInstaller,
      );
      if (!mounted) return;
      setState(() {
        _update = result.update;
        _status = switch (result) {
          (update: AppUpdate update, hasNewerRelease: _) =>
            '发现版本 ${update.version}',
          (update: null, hasNewerRelease: true) =>
            _platform == UpdatePlatform.ios
                ? '新版本尚未在当前 iOS 分发渠道发布。'
                : '有新版发布，当前平台暂无可用安装包。',
          _ => '当前已是最新版本。',
        };
      });
    } catch (_) {
      if (mounted) setState(() => _status = '检查更新失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download(AppUpdate update) async {
    setState(() {
      _status = '正在下载并校验安装包…';
      _progress = 0;
    });
    try {
      final file = await _service.download(
        update,
        onProgress: (received, total) {
          if (!mounted) return;
          final progress = received / total;
          if ((progress - _progress!).abs() >= 0.01 || received == total) {
            setState(() => _progress = progress);
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _package = file;
        _status = _platform == UpdatePlatform.macosArm64
            ? '安装包已校验。打开后将应用拖入「应用程序」。'
            : '安装包已校验。请在安装前完成正在进行的传输。';
      });
    } catch (_) {
      if (mounted) setState(() => _status = '下载或校验失败，请重新下载。');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  Future<void> _openPackage(File file) async {
    setState(() => _opening = true);
    try {
      if (!await file.exists()) {
        if (mounted) {
          setState(() {
            _package = null;
            _status = '安装包已被系统清理，请重新下载。';
          });
        }
        return;
      }
      final result = await widget.windowService.openUpdatePackage(file.path);
      if (!mounted) return;
      setState(() {
        _status = switch (result) {
          UpdatePackageOpenResult.opened => '已打开安装包，请按系统提示完成更新。',
          UpdatePackageOpenResult.permissionRequired =>
            '请允许 DropDrawer 安装应用，返回后再次点击安装。',
          UpdatePackageOpenResult.incompatibleVersion =>
            '此 Android 安装包的构建号过旧，请从发布页选择对应的安装包。',
          UpdatePackageOpenResult.unavailable => '无法打开安装包，请重试。',
        };
      });
    } catch (_) {
      if (mounted) setState(() => _status = '无法打开安装包，请重试。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _openPage(Uri url) async {
    try {
      if (await widget.windowService.openExternalUrl(url.toString())) return;
    } catch (_) {}
    if (mounted) setState(() => _status = '无法打开更新页面，请重试。');
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    final store = update?.storeUrl;
    final file = _package;
    final progress = _progress;
    final mobile = widget.windowService.isMobile;
    final minimumHeight = mobile ? 44.0 : 32.0;
    final packageSize = update?.packageSize;
    final supported = _platform != UpdatePlatform.unsupported;
    final status = supported ? _status : '当前平台请从发布页获取更新。';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _installed == null ? '当前版本' : '当前版本 ${_installed!}',
            style: TextStyle(
              color: MacPalette.textPrimary,
              fontSize: mobile ? 14 : 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (status.isNotEmpty) ...[
            const SizedBox(height: 4),
            Semantics(
              liveRegion: true,
              child: Text(
                status,
                style: TextStyle(
                  color: MacPalette.textSecondary,
                  fontSize: mobile ? 12 : 11,
                ),
              ),
            ),
          ],
          if (_checking || progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress,
              semanticsLabel: _checking ? '正在检查更新' : '安装包下载进度',
              semanticsValue: progress == null
                  ? null
                  : '${(progress * 100).round()}%',
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (supported)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size(0, minimumHeight),
                  ),
                  onPressed: _busy || _installed == null ? null : _check,
                  child: const Text('检查更新'),
                ),
              if (store != null)
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: Size(0, minimumHeight),
                  ),
                  onPressed: _busy ? null : () => _openPage(store),
                  child: Text(
                    store.host == 'testflight.apple.com'
                        ? '打开 TestFlight'
                        : '打开 App Store',
                  ),
                )
              else if (update != null)
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: Size(0, minimumHeight),
                  ),
                  onPressed: _busy
                      ? null
                      : file == null
                      ? () => _download(update)
                      : () => _openPackage(file),
                  child: Text(
                    file != null
                        ? '打开安装包'
                        : '下载更新 · ${(packageSize! / 1048576).toStringAsFixed(1)} MB',
                  ),
                ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: Size(0, minimumHeight),
                ),
                onPressed: () => _openPage(
                  update?.releasePage ?? AppUpdateService.releasesPage,
                ),
                child: Text(update == null ? '发布页' : '更新说明'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
