import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/drawer_controller.dart';
import 'phone_page.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

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

  static Map<String, Map<String, String>> get _credentialFields => {
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
    'web_dav': {'password': l10n.password},
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
          _nameCtrl.text = l10n.quarkDrive;
          _pathCtrl.text = '0';
          break;
        case 'baidu_netdisk':
          _nameCtrl.text = l10n.baiduNetdisk;
          _pathCtrl.text = '/apps/dropdrawer';
          break;
        case 's3':
          _nameCtrl.text = 'S3 / Cloudflare R2';
          _urlCtrl.text = 'https://<account>.r2.cloudflarestorage.com';
          _pathCtrl.text = 'dropdrawer';
          break;
        case 'web_dav':
          _nameCtrl.text = l10n.webdavStorage;
          _urlCtrl.text = 'https://dav.example.com/dropdrawer';
          break;
        case 'local':
          _nameCtrl.text = l10n.serverLocalStorage;
          break;
      }
    });
  }

  Future<void> _launchGoogleOAuth() async {
    if (_clientIdCtrl.text.trim().isEmpty ||
        _clientSecretCtrl.text.trim().isEmpty) {
      setState(() {
        _feedbackOk = false;
        _feedback = l10n.enterTheGoogleOauthClientId;
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
        _feedback = l10n.googleDriveAuthorizationOpenedInYour;
        _tab = 0;
      });
    } catch (e) {
      setState(() {
        _feedbackOk = false;
        _feedback = l10n.authorizationFailedToStart(e);
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
            throw StateError(l10n.enterARefreshTokenOrUse);
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
            throw StateError(l10n.pasteTheCookieFromPanQuark);
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
        _feedback = l10n.storageSaved;
        _feedbackOk = true;
        _tab = 0;
      });
    } catch (e) {
      setState(() {
        _feedback = l10n.saveFailedColon(e);
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
        title: l10n.cloudStorage,
        actions: [
          PageAction(
            icon: CupertinoIcons.refresh,
            tooltip: l10n.refreshStorageList,
            onPressed: () => c.refreshStorageBackends(),
          ),
        ],
        body: NativeTypeScale(child: _buildPhoneBody()),
      );
    }
    return AdaptivePage(
      title: l10n.cloudStorage,
      actions: [
        PageAction(
          icon: CupertinoIcons.refresh,
          tooltip: l10n.refreshStorageList,
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
                tooltip: l10n.backToDrawer,
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
                  _editingBackend == null ? l10n.cloudStorage2 : l10n.editStorage,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              MacIconButton(
                icon: CupertinoIcons.refresh,
                tooltip: l10n.refreshStorageList,
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
                items: [(0, l10n.configured), (1, l10n.addStorage)],
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

  static String get _disabledAllKindsNotice => l10n.theServerAdministratorHasDisabledEvery;

  /// Quark and Baidu only serve users in mainland China, so other languages
  /// list the international providers first.
  static List<(String, String)> get _kinds {
    final kinds = _kindsInChineseOrder;
    if (AppLocale.isChinese) return kinds;
    const regional = {'quark', 'baidu_netdisk'};
    return [
      ...kinds.where((k) => !regional.contains(k.$1)),
      ...kinds.where((k) => regional.contains(k.$1)),
    ];
  }

  static List<(String, String)> get _kindsInChineseOrder => [
    ('google_drive', 'Google Drive'),
    ('quark', l10n.quarkDrive),
    ('baidu_netdisk', l10n.baiduNetdisk),
    ('s3', 'S3 / R2'),
    ('web_dav', 'WebDAV'),
    ('local', l10n.localDisk),
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
      f(_nameCtrl, l10n.name),
      ...switch (_selectedKind) {
        'google_drive' => [
            f(_clientIdCtrl, 'Client ID', placeholder: 'xxx.apps.googleusercontent.com'),
            f(_clientSecretCtrl, 'Secret', placeholder: 'GOCSPX-...', obscure: true),
            f(_refreshTokenCtrl, 'Refresh', placeholder: l10n.optionalUseOneClickAuthorizationBelow),
            f(_pathCtrl, l10n.folderId, placeholder: l10n.rootOrAFolderId),
          ],
        'quark' => [
            f(_cookieCtrl, 'Cookie', placeholder: l10n.fullCookieFromPanQuarkCn),
            f(_pathCtrl, l10n.folderFid, placeholder: l10n.n0IsTheRootFolder),
          ],
        'baidu_netdisk' => [
            f(_accessTokenCtrl, 'Token', placeholder: l10n.accessTokenOrFillInRefresh),
            f(_clientIdCtrl, 'App Key', placeholder: l10n.optionalUsedForAutomaticRefresh),
            f(_clientSecretCtrl, 'Secret', obscure: true),
            f(_refreshTokenCtrl, 'Refresh', placeholder: l10n.optionalLongLivedRefreshToken10),
            f(_pathCtrl, l10n.path, placeholder: '/apps/dropdrawer'),
          ],
        'web_dav' => [
            f(_urlCtrl, l10n.url),
            f(_userCtrl, l10n.username),
            f(_passCtrl, l10n.password, obscure: true),
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

  static String get _localNote =>
      l10n.filesAreSavedInThisAccount;
  static String get _defaultNote => l10n.newCloudUploadsUseTheDefault;

  Future<void> _testBackend(String id) async {
    final (ok, msg) = await widget.controller.testStorageBackend(id);
    if (mounted) {
      setState(() {
        _feedbackOk = ok;
        _feedback = ok ? l10n.connectionOk(msg) : l10n.connectionFailed(msg);
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
        _feedback = l10n.defaultStorageUpdated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedback = l10n.switchDefaultStorageFailed(e);
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
            options: [(0, l10n.configuredShort), (1, l10n.addStorageShort)],
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
                ? l10n.noStorageYetSwitchToAdd
                : l10n.tapToEditNote(_defaultNote),
            children: [
              if (list.isEmpty)
                PhoneRow(title: l10n.noStorage, dimmed: true)
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
                    value: backend.isDefault ? l10n.defaultLabel : null,
                    trailing: backend.isDefault
                        ? null
                        : TextButton(
                            onPressed: _switchingDefault
                                ? null
                                : () => _setDefaultBackend(backend.id),
                            child: Text(l10n.setAsDefault),
                          ),
                    onTap: () => showPhoneActions(
                      context,
                      title: backend.name,
                      entries: [
                        PhoneMenuEntry(
                          label: l10n.edit,
                          icon: CupertinoIcons.pencil,
                          materialIcon: Icons.edit_outlined,
                          onSelected: () => _openEdit(backend),
                        ),
                        PhoneMenuEntry(
                          label: l10n.testConnection,
                          icon: CupertinoIcons.waveform_path,
                          materialIcon: Icons.network_check,
                          onSelected: () => _testBackend(backend.id),
                        ),
                        PhoneMenuEntry(
                          label: l10n.delete,
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
                title: l10n.typeLabel,
                value: (_allowedKinds.where((k) => k.$1 == _selectedKind).firstOrNull ??
                        _allowedKinds.first)
                    .$2,
                onTap: () async {
                  final kind = await showPhoneChoice<String>(
                    context,
                    title: l10n.storageType,
                    options: _allowedKinds,
                    selected: _selectedKind,
                    previousTitle: l10n.storageBack,
                  );
                  if (kind != null && mounted) _selectKind(kind);
                },
              ),
            ],
          ),
          PhoneSection(
            header: l10n.connection,
            footer: switch (_selectedKind) {
              'local' => _localNote,
              'google_drive' =>
                l10n.callbackUrlHint(c.serverUrl),
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
                title: l10n.useAsDefaultTransferStorage,
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
              label: l10n.authorizeGoogleDriveInBrowser,
              onPressed: _saving ? null : _launchGoogleOAuth,
            ),
            const SizedBox(height: 10),
            PhoneButton(
              kind: PhoneButtonKind.secondary,
              label: l10n.iAlreadyHaveARefreshToken,
              onPressed: _saving ? null : _addBackend,
            ),
          ] else
            PhoneButton(
              label: _saving ? l10n.saving : l10n.save,
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
          l10n.noStorageYetUseAddStorage,
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
                                    l10n.defaultLabel,
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
                          child: Text(l10n.setAsDefault),
                        ),
                      MacIconButton(
                        icon: CupertinoIcons.pencil,
                        tooltip: l10n.edit,
                        size: 14,
                        onPressed: () => _openEdit(list[i]),
                      ),
                      MacIconButton(
                        icon: CupertinoIcons.waveform_path,
                        tooltip: l10n.testConnection,
                        size: 14,
                        onPressed: () => _testBackend(list[i].id),
                      ),
                      const SizedBox(width: 2),
                      MacIconButton(
                        icon: CupertinoIcons.trash,
                        tooltip: l10n.delete,
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
        _feedback = l10n.cantReadStorage(e);
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
        _feedback = name.isEmpty ? l10n.storageNameCanTBeEmpty : l10n.theCapacityLimitMustBeA;
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
        _feedback = l10n.storageSettingsSaved;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedback = l10n.saveFailedFull(e);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildEditForm({required bool phone}) {
    final backend = _editingBackend!;
    final local = backend.kind == 'local';
    final target = '${_kindLabel(backend.kind)} · ${backend.displayTarget}';
    final note = local ? l10n.leaveTheCapacityLimitEmptyFor : l10n.leaveFieldsEmptyToKeepThe;

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
      field(l10n.name, _editNameCtrl),
      if (local)
        field(
          l10n.limitBytes,
          _capacityCtrl,
          placeholder: l10n.unlimited,
          inputType: TextInputType.number,
        ),
      for (final entry
          in (_credentialFields[backend.kind] ?? const <String, String>{})
              .entries)
        field(entry.value, _credentials[entry.key]!, obscure: true),
    ];
    final saveLabel = _saving ? l10n.saving : l10n.saveChanges;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (phone)
          PhoneSection(
            header: l10n.editStorage,
            footer: note,
            children: [
              PhoneRow(title: l10n.storageLocation, subtitle: target),
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
            label: l10n.cancel,
            onPressed: _saving ? null : _closeEdit,
          ),
        ] else
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : _closeEdit,
                child: Text(l10n.cancel),
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
                l10n.useAsDefaultTransferStorage,
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
              label: Text(l10n.authorizeGoogleDriveInBrowserOne),
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
            l10n.callbackUrlHint(widget.controller.serverUrl),
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
              child: Text(l10n.alreadyHaveARefreshTokenSave),
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
                  : Text(l10n.saveStorage),
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
        return l10n.quarkDrive;
      case 'baidu_netdisk':
        return l10n.baiduNetdisk;
      case 's3':
        return 'S3 / R2';
      case 'web_dav':
        return 'WebDAV';
      case 'local':
        return l10n.localDiskFull;
      default:
        return kind;
    }
  }
}
