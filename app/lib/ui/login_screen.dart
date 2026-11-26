import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/drawer_controller.dart';
import 'phone_page.dart';
import 'theme.dart';

enum _AuthMode { login, register, resetPassword }

class LoginScreen extends StatefulWidget {
  final DropDrawerController controller;

  const LoginScreen({super.key, required this.controller});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _serverCtrl;
  final _userCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  _AuthMode _mode = _AuthMode.login;
  AuthPublicConfig? _serverConfig;
  Timer? _configDebounce;
  Timer? _cooldownTimer;
  int _codeCooldown = 0;
  bool _sendingCode = false;
  bool _loading = false;
  bool _waitingForGoogle = false;
  bool _cancelGoogle = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.controller.serverUrl);
    _serverCtrl.addListener(_onServerUrlChanged);
    unawaited(_loadServerAuthConfig());
  }

  @override
  void dispose() {
    _configDebounce?.cancel();
    _cooldownTimer?.cancel();
    _serverCtrl.removeListener(_onServerUrlChanged);
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _inviteCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _onServerUrlChanged() {
    _configDebounce?.cancel();
    _configDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_loadServerAuthConfig());
    });
  }

  Future<void> _loadServerAuthConfig() async {
    final target = _serverCtrl.text.trim();
    final cfg = await widget.controller.fetchServerAuthConfig(target);
    if (!mounted || _serverCtrl.text.trim() != target) return;
    setState(() {
      _serverConfig = cfg;
      if (cfg != null) {
        if (!cfg.registrationAllowed && _mode == _AuthMode.register) {
          _mode = _AuthMode.login;
        }
        if (!cfg.emailPasswordResetEnabled &&
            _mode == _AuthMode.resetPassword) {
          _mode = _AuthMode.login;
        }
      }
    });
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _codeCooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_codeCooldown <= 1) {
        timer.cancel();
        setState(() => _codeCooldown = 0);
      } else {
        setState(() => _codeCooldown -= 1);
      }
    });
  }

  Future<void> _sendCode() async {
    if (_sendingCode || _codeCooldown > 0) return;
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _error = '请先填写有效的邮箱地址';
        _info = null;
      });
      return;
    }
    setState(() {
      _sendingCode = true;
      _error = null;
      _info = null;
    });
    try {
      await widget.controller.sendEmailVerificationCode(
        url: _serverCtrl.text,
        email: email,
        purpose: _mode == _AuthMode.resetPassword ? 'reset_password' : 'register',
      );
      if (mounted) {
        _startCooldown();
        setState(() => _info = '验证码已发送，请查收邮件（10 分钟内有效）');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = describeError(e),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _submit() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      if (_mode == _AuthMode.resetPassword) {
        await widget.controller.resetPasswordWithEmail(
          url: _serverCtrl.text,
          email: _emailCtrl.text.trim(),
          code: _codeCtrl.text.trim(),
          newPassword: _passCtrl.text,
        );
        if (mounted) {
          setState(() {
            _mode = _AuthMode.login;
            _userCtrl.text = _emailCtrl.text.trim();
            _codeCtrl.clear();
            _passCtrl.clear();
            _info = '密码已重置，请使用新密码登录';
          });
        }
        return;
      }

      await widget.controller.authenticate(
        url: _serverCtrl.text,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
        isRegister: _mode == _AuthMode.register,
        email: _mode == _AuthMode.register ? _emailCtrl.text.trim() : null,
        emailCode: _mode == _AuthMode.register ? _codeCtrl.text.trim() : null,
        inviteCode: _mode == _AuthMode.register ? _inviteCtrl.text.trim() : null,
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = describeError(e),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _cancelGoogle = false;
      _error = null;
      _info = null;
    });
    try {
      await widget.controller.authenticateWithGoogle(
        url: _serverCtrl.text,
        isCancelled: () => !mounted || _cancelGoogle,
        onBrowserOpened: () => setState(() => _waitingForGoogle = true),
      );
    } catch (e) {
      if (mounted && !_cancelGoogle) {
        setState(
          () => _error = describeError(e),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _waitingForGoogle = false;
        });
      }
    }
  }

  Future<void> _openPrivacyNotice() async {
    final base = _serverCtrl.text.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/privacy');
    if (uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        await widget.controller.windowService.openExternalUrl(uri.toString())) {
      return;
    }
    if (mounted) setState(() => _error = '请先填写有效的服务器地址。');
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = widget.controller.windowService.isMobile;
    final cfg = _serverConfig;
    final showPasswordForm =
        _mode != _AuthMode.login || (cfg?.passwordLoginEnabled ?? true);
    final showRegisterToggle = cfg?.registrationAllowed ?? true;
    final requireEmail =
        _mode == _AuthMode.register && (cfg?.emailVerificationRequired ?? false);
    final requireInvite =
        _mode == _AuthMode.register && (cfg?.inviteCodeRequired ?? false);
    final showResetEntry =
        _mode == _AuthMode.login && (cfg?.emailPasswordResetEnabled ?? false);
    final showGoogleBtn = cfg == null || cfg.googleEnabled;

    final submitLabel = switch (_mode) {
      _AuthMode.login => '继续',
      _AuthMode.register => '创建账号并连接',
      _AuthMode.resetPassword => '确认重置密码',
    };

    final screen = Scaffold(
      backgroundColor: isMobile ? MacPalette.background : Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: isMobile ? MacPalette.background : MacPalette.surfaceTint,
          border: isMobile
              ? null
              : Border.all(color: MacPalette.hairline, width: 0.8),
        ),
        child: SafeArea(
          top: isMobile,
          bottom: isMobile,
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                isMobile ? 24 : 32,
                isMobile ? 28 : 44,
                isMobile ? 24 : 32,
                28,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isMobile ? 360 : 300),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Image.asset(
                        'assets/dropdrawer-icon.png',
                        width: isMobile ? 76 : 60,
                        height: isMobile ? 76 : 60,
                        excludeFromSemantics: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'DropDrawer',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: isMobile ? 25 : 19,
                        fontWeight:
                            isMobile ? FontWeight.w700 : FontWeight.w600,
                        letterSpacing: -0.3,
                        color: MacPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _mode == _AuthMode.resetPassword
                          ? '通过邮箱验证码重置密码'
                          : '跨端文件暂存抽屉',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: MacPalette.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Grouped form
                    Container(
                      decoration: BoxDecoration(
                        color: MacPalette.group(0.24),
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: MacPalette.hairline, width: 0.8),
                      ),
                      child: Column(
                        children: [
                          MacFormField(
                            controller: _serverCtrl,
                            label: '服务器',
                            placeholder: 'http://127.0.0.1:8080',
                          ),
                          if (showPasswordForm &&
                              _mode != _AuthMode.resetPassword) ...[
                            const Divider(
                                height: 0.5, thickness: 0.5, indent: 12),
                            MacFormField(
                              controller: _userCtrl,
                              label: '账号',
                              placeholder: _mode == _AuthMode.login
                                  ? '用户名或已验证邮箱'
                                  : '输入用户名',
                            ),
                          ],
                          if (requireEmail ||
                              _mode == _AuthMode.resetPassword) ...[
                            const Divider(
                                height: 0.5, thickness: 0.5, indent: 12),
                            MacFormField(
                              controller: _emailCtrl,
                              label: '邮箱',
                              placeholder: 'you@example.com',
                            ),
                            const Divider(
                                height: 0.5, thickness: 0.5, indent: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: MacFormField(
                                    controller: _codeCtrl,
                                    label: '验证码',
                                    placeholder: '6 位数字',
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: TextButton(
                                    onPressed: (_sendingCode ||
                                            _codeCooldown > 0 ||
                                            _loading)
                                        ? null
                                        : _sendCode,
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: Text(
                                      _sendingCode
                                          ? '发送中…'
                                          : (_codeCooldown > 0
                                              ? '${_codeCooldown}s'
                                              : '获取验证码'),
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: _codeCooldown > 0
                                            ? MacPalette.textTertiary
                                            : MacPalette.accent,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (requireInvite) ...[
                            const Divider(
                                height: 0.5, thickness: 0.5, indent: 12),
                            MacFormField(
                              controller: _inviteCtrl,
                              label: '邀请码',
                              placeholder: '输入管理员发放的邀请码',
                            ),
                          ],
                          if (showPasswordForm) ...[
                            const Divider(
                                height: 0.5, thickness: 0.5, indent: 12),
                            MacFormField(
                              controller: _passCtrl,
                              label: _mode == _AuthMode.resetPassword
                                  ? '新密码'
                                  : '密码',
                              placeholder: '至少 6 位',
                              obscureText: true,
                              onSubmitted: (_) => _submit(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_info != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _info!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: MacPalette.green,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: MacPalette.red,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (showPasswordForm)
                      SizedBox(
                        height: isMobile ? 50 : 36,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isMobile
                                ? MacPalette.accent
                                : MacPalette.textPrimary,
                            foregroundColor: isMobile
                                ? MacPalette.onAccent
                                : MacPalette.onTextPrimary,
                            disabledBackgroundColor: MacPalette.fill(0.25),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(isMobile ? 12 : 9),
                            ),
                            textStyle: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          child: _loading
                              ? SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: isMobile
                                        ? MacPalette.onAccent
                                        : MacPalette.onTextPrimary,
                                  ),
                                )
                              : Text(submitLabel),
                        ),
                      ),
                    if (showGoogleBtn && _mode != _AuthMode.resetPassword) ...[
                      if (showPasswordForm) const SizedBox(height: 8),
                      if (_waitingForGoogle) ...[
                        Text(
                          '请在系统浏览器完成 Google 授权，然后返回 DropDrawer。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: MacPalette.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        TextButton(
                          onPressed: _cancelGoogle
                              ? null
                              : () => setState(() => _cancelGoogle = true),
                          child: const Text('取消等待'),
                        ),
                      ] else
                        SizedBox(
                          height: isMobile ? 50 : 36,
                          child: OutlinedButton(
                            style: isMobile
                                ? OutlinedButton.styleFrom(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  )
                                : null,
                            onPressed: _loading ? null : _signInWithGoogle,
                            child: const Text('使用 Google 登录'),
                          ),
                        ),
                    ],
                    if (!_loading)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (showResetEntry)
                            TextButton(
                              onPressed: () => setState(() {
                                _mode = _AuthMode.resetPassword;
                                _error = null;
                                _info = null;
                              }),
                              child: Text(
                                '忘记密码？',
                                style: TextStyle(
                                  color: MacPalette.textSecondary,
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                          TextButton(
                            onPressed: _openPrivacyNotice,
                            child: Text(
                              '隐私说明',
                              style: TextStyle(
                                color: MacPalette.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (showRegisterToggle || _mode != _AuthMode.login) ...[
                      const SizedBox(height: 4),
                      Center(
                        child: GestureDetector(
                          onTap: _loading
                              ? null
                              : () => setState(() {
                                    _mode = _mode == _AuthMode.login
                                        ? _AuthMode.register
                                        : _AuthMode.login;
                                    _error = null;
                                    _info = null;
                                  }),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                _mode == _AuthMode.login
                                    ? '还没有账号？创建一个'
                                    : '已有账号，返回登录',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: MacPalette.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!isMobile) return screen;
    return UiDensity(touch: true, child: PhoneTypeScale(child: screen));
  }
}
