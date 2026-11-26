import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
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
  bool _loadingEdit = false;
  StorageBackendSummary? _editingBackend;
  final _editNameCtrl = TextEditingController();
  final _capacityCtrl = TextEditingController();
  int? _initialCapacity;
  final _credentials = <String, TextEditingController>{};

  static const _credentialFields = {
    'google_drive': {
      'client_secret': 'Client Secret',
      'refresh_token': 'Refresh Token',
    },
    'quark': {'cookie': 'Cookie'},
    'baidu_netdisk': {
      'client_secret': 'App Secret',
      'refresh_token': 'Refresh Token',
      'access_token': 'Access Token',
    },
    'web_dav': {'password': '密码'},
    's3': {'access_key_id': 'Access Key', 'secret_access_key': 'Secret Key'},
  };
  bool _switchingDefault = false;
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
    _editNameCtrl.dispose();
    _capacityCtrl.dispose();
    for (final controller in _credentials.values) {
      controller.dispose();
    }
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
    if (UiDensity.isTouch(context)) {
      return PhonePage(
        title: '云盘与存储',
        actions: [
          PageAction(
            icon: CupertinoIcons.refresh,
            tooltip: '刷新存储列表',
            onPressed: () => c.refreshStorageBackends(),
          ),
        ],
        body: NativeTypeScale(child: _buildPhoneBody()),
      );
    }
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
                onPressed: _editingBackend == null
                    ? widget.onBack
                    : _saving
                    ? null
                    : _closeEdit,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _editingBackend == null ? '原生云盘与存储' : '编辑存储',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
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
          if (_editingBackend == null)
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
              child: _editingBackend != null
                  ? _buildEditForm(phone: false)
                  : _tab == 0
                  ? _buildBackendList()
                  : _buildAddBackendForm(),
            ),
          ),
        ],
      ),
    );
  }

  /// Kinds the server still allows adding (admin console storage policy).
  List<(String, String)> get _allowedKinds =>
      _kinds.where((k) => widget.controller.isStorageKindAllowed(k.$1)).toList();

  /// Moves the add form off a kind the administrator has just disabled.
  void _ensureAllowedKind(List<(String, String)> allowed) {
    if (allowed.isEmpty || allowed.any((k) => k.$1 == _selectedKind)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_allowedKinds.any((k) => k.$1 == _selectedKind)) {
        final remaining = _allowedKinds;
        if (remaining.isNotEmpty) _selectKind(remaining.first.$1);
      }
    });
  }

  static const _disabledAllKindsNotice = '服务器管理员已停用所有可添加的存储类型，暂时无法添加新的云盘。';

  static const _kinds = [
    ('google_drive', 'Google Drive'),
    ('quark', '夸克网盘'),
    ('baidu_netdisk', '百度网盘'),
    ('s3', 'S3 / R2'),
    ('web_dav', 'WebDAV'),
    ('local', '本地盘'),
  ];

  /// The connection fields of the selected kind, name first.
  List<({TextEditingController controller, String label, String? placeholder, bool obscure})>
      _fields() {
    ({TextEditingController controller, String label, String? placeholder, bool obscure}) f(
      TextEditingController controller,
      String label, {
      String? placeholder,
      bool obscure = false,
    }) =>
        (controller: controller, label: label, placeholder: placeholder, obscure: obscure);
    return [
      f(_nameCtrl, '名称'),
      ...switch (_selectedKind) {
        'google_drive' => [
            f(_clientIdCtrl, 'Client ID', placeholder: 'xxx.apps.googleusercontent.com'),
            f(_clientSecretCtrl, 'Secret', placeholder: 'GOCSPX-...', obscure: true),
            f(_refreshTokenCtrl, 'Refresh', placeholder: '可留空，点下方一键授权自动获取'),
            f(_pathCtrl, '目录 ID', placeholder: 'root (或指定文件夹 ID)'),
          ],
        'quark' => [
            f(_cookieCtrl, 'Cookie', placeholder: 'pan.quark.cn 完整 Cookie'),
            f(_pathCtrl, '目录 fid', placeholder: '0 表示根目录'),
          ],
        'baidu_netdisk' => [
            f(_accessTokenCtrl, 'Token', placeholder: 'Access Token (或填下方 Refresh)'),
            f(_clientIdCtrl, 'App Key', placeholder: '可选，用于自动刷新'),
            f(_clientSecretCtrl, 'Secret', obscure: true),
            f(_refreshTokenCtrl, 'Refresh', placeholder: '可选，10年长效刷新令牌'),
            f(_pathCtrl, '路径', placeholder: '/apps/dropdrawer'),
          ],
        'web_dav' => [
            f(_urlCtrl, '地址'),
            f(_userCtrl, '用户名'),
            f(_passCtrl, '密码', obscure: true),
          ],
        's3' => [
            f(_urlCtrl, 'Endpoint'),
            f(_bucketCtrl, 'Bucket'),
            f(_regionCtrl, 'Region'),
            f(_userCtrl, 'AccessKey'),
            f(_passCtrl, 'SecretKey', obscure: true),
          ],
        _ => const [],
      },
    ];
  }

  static const _localNote =
      '文件保存在服务器数据目录中属于当前账号的文件夹（由服务端 DROPDRAWER_LOCAL_STORAGE 决定）。';
  static const _defaultNote = '新上传至云端的文件会使用默认存储。';

  Future<void> _testBackend(String id) async {
    final (ok, msg) = await widget.controller.testStorageBackend(id);
    if (mounted) {
      setState(() {
        _feedbackOk = ok;
        _feedback = ok ? '连通正常: $msg' : '连通失败: $msg';
      });
    }
  }

  Future<void> _setDefaultBackend(String id) async {
    if (_switchingDefault) return;
    setState(() {
      _switchingDefault = true;
      _feedback = null;
    });
    try {
      await widget.controller.setDefaultStorageBackend(id);
      if (!mounted) return;
      setState(() {
        _feedbackOk = true;
        _feedback = '已更新默认存储';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedback = '切换默认存储失败：$e';
      });
    } finally {
      if (mounted) setState(() => _switchingDefault = false);
    }
  }

  /// Phones: the configured backends and add form as settings groups.
  Widget _buildPhoneBody() {
    if (_tab == 1 && _editingBackend == null) _ensureAllowedKind(_allowedKinds);
    final c = widget.controller;
    final material = usesMaterialChrome(context);
    final list = c.storageBackends;
    final feedback = _feedback;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (_editingBackend == null)
          PhoneSegmented<int>(
            options: const [(0, '已配置'), (1, '添加云盘')],
            selected: _tab,
            onChanged: (v) => setState(() => _tab = v),
          ),
        if (feedback != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              feedback,
              style: TextStyle(
                fontSize: 13,
                color: _feedbackOk ? MacPalette.green : MacPalette.red,
              ),
            ),
          ),
        const SizedBox(height: 20),
        if (_editingBackend != null)
          _buildEditForm(phone: true)
        else if (_tab == 0)
          PhoneSection(
            footer: list.isEmpty
                ? '还没有存储策略，切换到「添加云盘」直连配置。'
                : '点按存储项可编辑。$_defaultNote',
            children: [
              if (list.isEmpty)
                const PhoneRow(title: '暂无云盘', dimmed: true)
              else
                for (final backend in list)
                  PhoneRow(
                    leading: Icon(
                      material ? Icons.cloud_outlined : CupertinoIcons.cloud,
                      size: 22,
                      color: MacPalette.accent,
                    ),
                    title: backend.name,
                    subtitle:
                        '${_kindLabel(backend.kind)} · ${backend.displayTarget}',
                    value: backend.isDefault ? '默认' : null,
                    trailing: backend.isDefault
                        ? null
                        : TextButton(
                            onPressed: _switchingDefault
                                ? null
                                : () => _setDefaultBackend(backend.id),
                            child: const Text('设为默认'),
                          ),
                    onTap: () => showPhoneActions(
                      context,
                      title: backend.name,
                      entries: [
                        PhoneMenuEntry(
                          label: '编辑',
                          icon: CupertinoIcons.pencil,
                          materialIcon: Icons.edit_outlined,
                          onSelected: () => _openEdit(backend),
                        ),
                        PhoneMenuEntry(
                          label: '测试连通性',
                          icon: CupertinoIcons.waveform_path,
                          materialIcon: Icons.network_check,
                          onSelected: () => _testBackend(backend.id),
                        ),
                        PhoneMenuEntry(
                          label: '删除',
                          icon: CupertinoIcons.trash,
                          materialIcon: Icons.delete_outline,
                          destructive: true,
                          onSelected: () => c.removeStorageBackend(backend.id),
                        ),
                      ],
                    ),
                  ),
            ],
          )
        else if (_allowedKinds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              _disabledAllKindsNotice,
              style: TextStyle(fontSize: 14, color: MacPalette.textSecondary),
            ),
          )
        else ...[
          PhoneSection(
            children: [
              PhoneRow(
                title: '类型',
                value: (_allowedKinds.where((k) => k.$1 == _selectedKind).firstOrNull ??
                        _allowedKinds.first)
                    .$2,
                onTap: () async {
                  final kind = await showPhoneChoice<String>(
                    context,
                    title: '云盘类型',
                    options: _allowedKinds,
                    selected: _selectedKind,
                    previousTitle: '云盘',
                  );
                  if (kind != null && mounted) _selectKind(kind);
                },
              ),
            ],
          ),
          PhoneSection(
            header: '连接信息',
            footer: switch (_selectedKind) {
              'local' => _localNote,
              'google_drive' =>
                '回调地址请填：${c.serverUrl}/api/oauth/google/callback',
              _ => null,
            },
            children: [
              for (final field in _fields())
                PhoneFieldRow(
                  controller: field.controller,
                  label: field.label,
                  placeholder: field.placeholder,
                  obscureText: field.obscure,
                ),
            ],
          ),
          PhoneSection(
            children: [
              PhoneRow(
                title: '设为默认中转存储',
                trailing: AdaptiveSwitch(
                  value: _isDefault,
                  onChanged: (v) => setState(() => _isDefault = v),
                ),
              ),
            ],
          ),
          if (_selectedKind == 'google_drive') ...[
            PhoneButton(
              icon: material ? Icons.open_in_browser : CupertinoIcons.globe,
              label: '在浏览器中授权 Google Drive',
              onPressed: _saving ? null : _launchGoogleOAuth,
            ),
            const SizedBox(height: 10),
            PhoneButton(
              kind: PhoneButtonKind.secondary,
              label: '已有 Refresh Token，直接保存',
              onPressed: _saving ? null : _addBackend,
            ),
          ] else
            PhoneButton(
              label: _saving ? '正在保存…' : '保存',
              onPressed: _saving ? null : _addBackend,
            ),
        ],
      ],
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
                if (i > 0)
                  const Divider(height: 0.5, thickness: 0.5, indent: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
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
                      if (!list[i].isDefault)
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: MacPalette.accent,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 32),
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          onPressed: _switchingDefault
                              ? null
                              : () => _setDefaultBackend(list[i].id),
                          child: const Text('设为默认'),
                        ),
                      MacIconButton(
                        icon: CupertinoIcons.pencil,
                        tooltip: '编辑',
                        size: 14,
                        onPressed: () => _openEdit(list[i]),
                      ),
                      MacIconButton(
                        icon: CupertinoIcons.waveform_path,
                        tooltip: '测试连通性',
                        size: 14,
                        onPressed: () => _testBackend(list[i].id),
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
          _defaultNote,
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: MacPalette.textTertiary,
          ),
        ),
      ],
    );
  }

  Future<void> _openEdit(StorageBackendSummary backend) async {
    if (_loadingEdit || _saving || _switchingDefault) return;
    _loadingEdit = true;
    try {
      final capacity = backend.kind == 'local'
          ? await widget.controller.getStorageCapacity(backend.id)
          : null;
      if (!mounted || _tab != 0) return;
      _editNameCtrl.text = backend.name;
      _initialCapacity = capacity;
      _capacityCtrl.text = capacity?.toString() ?? '';
      for (final controller in _credentials.values) {
        controller.clear();
      }
      for (final key in (_credentialFields[backend.kind] ?? {}).keys) {
        _credentials.putIfAbsent(key, TextEditingController.new);
      }
      setState(() {
        _editingBackend = backend;
        _feedback = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedback = '无法读取存储配置：$e';
      });
    } finally {
      _loadingEdit = false;
    }
  }

  void _closeEdit() {
    for (final controller in _credentials.values) {
      controller.clear();
    }
    setState(() {
      _editingBackend = null;
      _feedback = null;
    });
  }

  Future<void> _saveEdit() async {
    final backend = _editingBackend;
    if (backend == null || _saving) return;
    final name = _editNameCtrl.text.trim();
    final rawCapacity = _capacityCtrl.text.trim();
    final capacity = int.tryParse(rawCapacity, radix: 10);
    final local = backend.kind == 'local';
    if (name.isEmpty ||
        (local &&
            rawCapacity.isNotEmpty &&
            (capacity == null || capacity <= 0))) {
      setState(() {
        _feedbackOk = false;
        _feedback = name.isEmpty ? '存储名称不能为空' : '容量上限必须为正整数';
      });
      return;
    }
    final config = <String, dynamic>{
      if (local && capacity != _initialCapacity) 'max_bytes': capacity,
      for (final key in (_credentialFields[backend.kind] ?? {}).keys)
        if (_credentials[key]!.text.trim().isNotEmpty)
          key: key == 'password'
              ? _credentials[key]!.text
              : _credentials[key]!.text.trim(),
    };
    setState(() {
      _saving = true;
      _feedback = null;
    });
    try {
      await widget.controller.updateStorageBackend(
        backend.id,
        name: name,
        config: config,
      );
      if (!mounted) return;
      _closeEdit();
      setState(() {
        _feedbackOk = true;
        _feedback = '已保存存储配置';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedback = '保存失败：$e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildEditForm({required bool phone}) {
    final backend = _editingBackend!;
    final local = backend.kind == 'local';
    final target = '${_kindLabel(backend.kind)} · ${backend.displayTarget}';
    final note = local ? '容量上限留空表示不限。' : '留空保留现有凭据。更换存储位置可使用「添加云盘」。';

    Widget field(
      String label,
      TextEditingController controller, {
      String? placeholder,
      bool obscure = false,
      TextInputType? inputType,
    }) => phone
        ? PhoneFieldRow(
            controller: controller,
            label: label,
            placeholder: placeholder,
            obscureText: obscure,
            keyboardType: inputType,
          )
        : MacFormField(
            controller: controller,
            label: label,
            placeholder: placeholder,
            obscureText: obscure,
          );

    final fields = [
      field('名称', _editNameCtrl),
      if (local)
        field(
          '上限（字节）',
          _capacityCtrl,
          placeholder: '不限',
          inputType: TextInputType.number,
        ),
      for (final entry
          in (_credentialFields[backend.kind] ?? const <String, String>{})
              .entries)
        field(entry.value, _credentials[entry.key]!, obscure: true),
    ];
    final saveLabel = _saving ? '正在保存…' : '保存修改';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (phone)
          PhoneSection(
            header: '编辑存储',
            footer: note,
            children: [
              PhoneRow(title: '存储位置', subtitle: target),
              ...fields,
            ],
          )
        else ...[
          Text(
            target,
            style: TextStyle(fontSize: 12, color: MacPalette.textSecondary),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: MacPalette.group(0.24),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: MacPalette.hairline, width: 0.7),
            ),
            child: Column(
              children: [
                for (final (index, field) in fields.indexed) ...[
                  if (index > 0)
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                  field,
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            note,
            style: TextStyle(fontSize: 11, color: MacPalette.textSecondary),
          ),
        ],
        const SizedBox(height: 12),
        if (phone) ...[
          PhoneButton(label: saveLabel, onPressed: _saving ? null : _saveEdit),
          const SizedBox(height: 8),
          PhoneButton(
            kind: PhoneButtonKind.secondary,
            label: '取消',
            onPressed: _saving ? null : _closeEdit,
          ),
        ] else
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : _closeEdit,
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _saving ? null : _saveEdit,
                child: Text(saveLabel),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildAddBackendForm() {
    final kinds = _allowedKinds;
    if (kinds.isEmpty) {
      return Text(
        _disabledAllKindsNotice,
        style: TextStyle(fontSize: 12, color: MacPalette.textSecondary),
      );
    }
    _ensureAllowedKind(kinds);

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
              for (final (index, field) in _fields().indexed) ...[
                if (index > 0)
                  const Divider(height: 0.5, thickness: 0.5, indent: 12),
                MacFormField(
                  controller: field.controller,
                  label: field.label,
                  placeholder: field.placeholder,
                  obscureText: field.obscure,
                ),
              ],
              if (_selectedKind == 'local') ...[
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    _localNote,
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
