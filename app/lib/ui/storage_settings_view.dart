import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../state/drawer_controller.dart';
import 'phone_page.dart';
import 'theme.dart';

/// Full-width in-drawer subview for managing native cloud & server storage backends:
/// Google Drive (built-in OAuth2), Quark Drive, Baidu Netdisk, S3/R2, WebDAV, and Local Disk.
/// Zero external sidecars required.
class StorageSettingsView extends StatefulWidget {
  final DropDrawerController controller;
  final VoidCallback onBack;

  const StorageSettingsView({
    super.key,
    required this.controller,
    required this.onBack,
  });

  @override
  State<StorageSettingsView> createState() => _StorageSettingsViewState();
}

class _StorageSettingsViewState extends State<StorageSettingsView> {
  int _tab = 0; // 0 = 已配置, 1 = 新增
  String _selectedKind = 'google_drive';

  final _nameCtrl = TextEditingController(text: 'Google Drive');
  final _clientIdCtrl = TextEditingController();
  final _clientSecretCtrl = TextEditingController();
  final _refreshTokenCtrl = TextEditingController();
  final _accessTokenCtrl = TextEditingController();
  final _cookieCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _pathCtrl = TextEditingController(text: 'root');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _regionCtrl = TextEditingController(text: 'auto');
  final _bucketCtrl = TextEditingController(text: 'dropdrawer');

  bool _isDefault = true;
  bool _saving = false;
  String? _feedback;
  bool _feedbackOk = true;

  @override
  void initState() {
    super.initState();
    widget.controller.refreshStorageBackends();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _clientIdCtrl.dispose();
    _clientSecretCtrl.dispose();
    _refreshTokenCtrl.dispose();
    _accessTokenCtrl.dispose();
    _cookieCtrl.dispose();
    _urlCtrl.dispose();
    _pathCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _regionCtrl.dispose();
    _bucketCtrl.dispose();
    super.dispose();
  }

  void _selectKind(String k) {
    setState(() {
      _selectedKind = k;
      _feedback = null;
      switch (k) {
        case 'google_drive':
          _nameCtrl.text = 'Google Drive';
          _pathCtrl.text = 'root';
          break;
        case 'quark':
          _nameCtrl.text = '夸克网盘';
          _pathCtrl.text = '0';
          break;
        case 'baidu_netdisk':
          _nameCtrl.text = '百度网盘';
          _pathCtrl.text = '/apps/dropdrawer';
          break;
        case 's3':
          _nameCtrl.text = 'S3 / Cloudflare R2';
          _urlCtrl.text = 'https://<account>.r2.cloudflarestorage.com';
          _pathCtrl.text = 'dropdrawer';
          break;
        case 'web_dav':
          _nameCtrl.text = 'WebDAV 网盘';
          _urlCtrl.text = 'https://dav.example.com/dropdrawer';
          break;
        case 'local':
          _nameCtrl.text = '服务器本地盘';
          break;
      }
    });
  }

  Future<void> _launchGoogleOAuth() async {
    if (_clientIdCtrl.text.trim().isEmpty ||
        _clientSecretCtrl.text.trim().isEmpty) {
      setState(() {
        _feedbackOk = false;
        _feedback = '请先填写 Google OAuth Client ID 和 Client Secret';
      });
      return;
    }
    setState(() {
      _saving = true;
      _feedback = null;
    });
    try {
      final authUrl = await widget.controller.startGoogleDriveOAuth(
        name: _nameCtrl.text.trim().isEmpty ? 'Google Drive' : _nameCtrl.text.trim(),
        clientId: _clientIdCtrl.text.trim(),
        clientSecret: _clientSecretCtrl.text.trim(),
        folderId: _pathCtrl.text.trim().isEmpty ? 'root' : _pathCtrl.text.trim(),
        isDefault: _isDefault,
      );
      await widget.controller.windowService.openExternalUrl(authUrl);
      setState(() {
        _feedbackOk = true;
        _feedback = '已打开浏览器授权 Google Drive，同意后点下方「刷新列表」即可';
        _tab = 0;
      });
    } catch (e) {
      setState(() {
        _feedbackOk = false;
        _feedback = '发起授权失败: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addBackend() async {
    setState(() {
      _saving = true;
      _feedback = null;
    });
    try {
      late Map<String, dynamic> cfg;
      switch (_selectedKind) {
        case 'google_drive':
          if (_refreshTokenCtrl.text.trim().isEmpty) {
            throw StateError('请填写 Refresh Token，或点击上方「浏览器一键授权 Google」');
          }
          cfg = {
            'kind': 'google_drive',
            'client_id': _clientIdCtrl.text.trim(),
            'client_secret': _clientSecretCtrl.text.trim(),
            'refresh_token': _refreshTokenCtrl.text.trim(),
            'folder_id':
                _pathCtrl.text.trim().isEmpty ? 'root' : _pathCtrl.text.trim(),
          };
          break;
        case 'quark':
          if (_cookieCtrl.text.trim().isEmpty) {
            throw StateError('请粘贴 pan.quark.cn 的 Cookie');
          }
          cfg = {
            'kind': 'quark',
            'cookie': _cookieCtrl.text.trim(),
            'root_folder_id':
                _pathCtrl.text.trim().isEmpty ? '0' : _pathCtrl.text.trim(),
          };
          break;
        case 'baidu_netdisk':
          cfg = {
            'kind': 'baidu_netdisk',
            'client_id': _clientIdCtrl.text.trim(),
            'client_secret': _clientSecretCtrl.text.trim(),
            'refresh_token': _refreshTokenCtrl.text.trim(),
            'access_token': _accessTokenCtrl.text.trim(),
            'root_path': _pathCtrl.text.trim().isEmpty
                ? '/apps/dropdrawer'
                : _pathCtrl.text.trim(),
          };
          break;
        case 'web_dav':
          cfg = {
            'kind': 'web_dav',
            'base_url': _urlCtrl.text.trim(),
            'username': _userCtrl.text.trim(),
            'password': _passCtrl.text,
          };
          break;
        case 's3':
          cfg = {
            'kind': 's3',
            'endpoint': _urlCtrl.text.trim(),
            'region': _regionCtrl.text.trim(),
            'bucket': _bucketCtrl.text.trim(),
            'access_key_id': _userCtrl.text.trim(),
            'secret_access_key': _passCtrl.text,
            'prefix': _pathCtrl.text.trim(),
            'force_path_style': true,
          };
          break;
        default:
          // The server always places local storage in this account's own
          // directory under DROPDRAWER_LOCAL_STORAGE and ignores root_dir.
          cfg = {
            'kind': 'local',
            'root_dir': '',
          };
      }

      await widget.controller.addStorageBackend(
        name: _nameCtrl.text.trim(),
        config: cfg,
        isDefault: _isDefault,
      );
      setState(() {
        _feedback = '已保存原生云盘策略';
        _feedbackOk = true;
        _tab = 0;
      });
    } catch (e) {
      setState(() {
        _feedback = '保存失败: $e';
        _feedbackOk = false;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AdaptivePage(
      title: '云盘与存储',
      actions: [
        PageAction(
          icon: CupertinoIcons.refresh,
          tooltip: '刷新存储列表',
          onPressed: () => c.refreshStorageBackends(),
        ),
      ],
      desktopHeader: Padding(
          padding: c.windowService.needsMacTrafficLightPadding
              ? const EdgeInsets.fromLTRB(78, 1, 10, 3)
              : const EdgeInsets.fromLTRB(10, 10, 12, 9),
          child: SizedBox(
            height: UiDensity.headerHeight(context),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                MacIconButton(
                  icon: CupertinoIcons.chevron_left,
                  tooltip: '返回抽屉',
                  size: 15,
                  onPressed: widget.onBack,
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    '原生云盘与存储',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                MacIconButton(
                  icon: CupertinoIcons.refresh,
                  tooltip: '刷新存储列表',
                  size: 14,
                  onPressed: () => c.refreshStorageBackends(),
                ),
              ],
            ),
          ),
        ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: MacSegmentedControl<int>(
            selected: _tab,
            items: const [(0, '已配置云盘'), (1, '添加原生云盘')],
            onChanged: (v) => setState(() => _tab = v),
          ),
        ),
        if (_feedback != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              _feedback!,
              style: TextStyle(
                fontSize: 11,
                color: _feedbackOk ? MacPalette.green : MacPalette.red,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: _tab == 0 ? _buildBackendList() : _buildAddBackendForm(),
          ),
        ),
        ],
      ),
    );
  }

  Widget _buildBackendList() {
    final list = widget.controller.storageBackends;
    if (list.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 36),
        child: Text(
          '暂无存储策略，点击上方「添加原生云盘」直连配置',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: MacPalette.textTertiary),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: MacPalette.group(0.22),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: MacPalette.hairline, width: 0.7),
          ),
          child: Column(
            children: [
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) const Divider(height: 0.5, thickness: 0.5, indent: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    list[i].name,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (list[i].isDefault) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '默认',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: MacPalette.green,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${_kindLabel(list[i].kind)} · ${list[i].displayTarget}',
                              style: TextStyle(
                                fontSize: 11,
                                color: MacPalette.textTertiary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      MacIconButton(
                        icon: CupertinoIcons.waveform_path,
                        tooltip: '测试连通性',
                        size: 14,
                        onPressed: () async {
                          final (ok, msg) = await widget.controller
                              .testStorageBackend(list[i].id);
                          if (mounted) {
                            setState(() {
                              _feedbackOk = ok;
                              _feedback = ok ? '连通正常: $msg' : '连通失败: $msg';
                            });
                          }
                        },
                      ),
                      const SizedBox(width: 2),
                      MacIconButton(
                        icon: CupertinoIcons.trash,
                        tooltip: '删除',
                        size: 13.5,
                        onPressed: () =>
                            widget.controller.removeStorageBackend(list[i].id),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '全部云盘均由服务端原生直连，无需额外安装或部署 OpenList 等任何第三方服务。',
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: MacPalette.textTertiary,
          ),
        ),
      ],
    );
  }

  Widget _buildAddBackendForm() {
    final kinds = [
      ('google_drive', 'Google Drive'),
      ('quark', '夸克网盘'),
      ('baidu_netdisk', '百度网盘'),
      ('s3', 'S3 / R2'),
      ('web_dav', 'WebDAV'),
      ('local', '本地盘'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: kinds.map((item) {
            final selected = item.$1 == _selectedKind;
            return GestureDetector(
              onTap: () => _selectKind(item.$1),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: selected
                        ? MacPalette.fill(0.18)
                        : MacPalette.group(0.24),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: selected
                          ? MacPalette.strongHairline
                          : MacPalette.hairline,
                      width: 0.7,
                    ),
                  ),
                  child: Text(
                    item.$2,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: selected
                          ? MacPalette.textPrimary
                          : MacPalette.textSecondary,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: MacPalette.group(0.24),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: MacPalette.hairline, width: 0.7),
          ),
          child: Column(
            children: [
              MacFormField(controller: _nameCtrl, label: '名称'),
              if (_selectedKind == 'google_drive') ...[
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _clientIdCtrl,
                  label: 'Client ID',
                  placeholder: 'xxx.apps.googleusercontent.com',
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _clientSecretCtrl,
                  label: 'Secret',
                  placeholder: 'GOCSPX-...',
                  obscureText: true,
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _refreshTokenCtrl,
                  label: 'Refresh',
                  placeholder: '可留空，点下方一键授权自动获取',
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _pathCtrl,
                  label: '目录 ID',
                  placeholder: 'root (或指定文件夹 ID)',
                ),
              ],
              if (_selectedKind == 'quark') ...[
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _cookieCtrl,
                  label: 'Cookie',
                  placeholder: 'pan.quark.cn 完整 Cookie',
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _pathCtrl,
                  label: '目录 fid',
                  placeholder: '0 表示根目录',
                ),
              ],
              if (_selectedKind == 'baidu_netdisk') ...[
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _accessTokenCtrl,
                  label: 'Token',
                  placeholder: 'Access Token (或填下方 Refresh)',
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _clientIdCtrl,
                  label: 'App Key',
                  placeholder: '可选，用于自动刷新',
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _clientSecretCtrl,
                  label: 'Secret',
                  obscureText: true,
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _refreshTokenCtrl,
                  label: 'Refresh',
                  placeholder: '可选，10年长效刷新令牌',
                ),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _pathCtrl,
                  label: '路径',
                  placeholder: '/apps/dropdrawer',
                ),
              ],
              if (_selectedKind == 'web_dav') ...[
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(controller: _urlCtrl, label: '地址'),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(controller: _userCtrl, label: '用户名'),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _passCtrl,
                  label: '密码',
                  obscureText: true,
                ),
              ],
              if (_selectedKind == 's3') ...[
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(controller: _urlCtrl, label: 'Endpoint'),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(controller: _bucketCtrl, label: 'Bucket'),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(controller: _regionCtrl, label: 'Region'),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(controller: _userCtrl, label: 'AccessKey'),
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: _passCtrl,
                  label: 'SecretKey',
                  obscureText: true,
                ),
              ],
              if (_selectedKind == 'local') ...[
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    '文件保存在服务器数据目录中属于当前账号的文件夹（由服务端 DROPDRAWER_LOCAL_STORAGE 决定）。',
                    style: TextStyle(fontSize: 11, color: MacPalette.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                '设为默认中转存储',
                style: TextStyle(fontSize: 12, color: MacPalette.textSecondary),
              ),
            ),
            AdaptiveSwitch(
              value: _isDefault,
              activeColor: MacPalette.green,
              compactScale: 0.72,
              onChanged: (v) => setState(() => _isDefault = v),
            ),
          ],
        ),
        if (_selectedKind == 'google_drive') ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _launchGoogleOAuth,
              icon: const Icon(CupertinoIcons.globe, size: 15),
              label: const Text('浏览器一键授权 Google Drive'),
              style: ElevatedButton.styleFrom(
                backgroundColor: MacPalette.textPrimary,
                foregroundColor: MacPalette.onTextPrimary,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '回调地址请填：${widget.controller.serverUrl}/api/oauth/google/callback',
            style: TextStyle(
              fontSize: 10,
              color: MacPalette.textTertiary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: OutlinedButton(
              onPressed: _saving ? null : _addBackend,
              style: OutlinedButton.styleFrom(
                foregroundColor: MacPalette.textSecondary,
                side: BorderSide(color: MacPalette.hairline, width: 0.8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('已有 Refresh Token？直接保存'),
            ),
          ),
        ] else ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ElevatedButton(
              onPressed: _saving ? null : _addBackend,
              style: ElevatedButton.styleFrom(
                backgroundColor: MacPalette.textPrimary,
                foregroundColor: MacPalette.onTextPrimary,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: _saving
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: MacPalette.onTextPrimary,
                      ),
                    )
                  : const Text('保存原生云盘配置'),
            ),
          ),
        ],
      ],
    );
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'google_drive':
        return 'Google Drive';
      case 'quark':
        return '夸克网盘';
      case 'baidu_netdisk':
        return '百度网盘';
      case 's3':
        return 'S3 / R2';
      case 'web_dav':
        return 'WebDAV';
      case 'local':
        return '本地磁盘';
      default:
        return kind;
    }
  }
}
