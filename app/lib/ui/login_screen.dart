import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../state/drawer_controller.dart';
import 'theme.dart';

class LoginScreen extends StatefulWidget {
  final DropDrawerController controller;

  const LoginScreen({super.key, required this.controller});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _serverCtrl;
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isRegister = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.controller.serverUrl);
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.controller.authenticate(
        url: _serverCtrl.text,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
        isRegister: _isRegister,
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('HttpException: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: MacPalette.surfaceTint,
          border: Border.all(color: MacPalette.hairline, width: 0.8),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 44, 32, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16),
                          width: 0.8,
                        ),
                      ),
                      child: const Icon(
                        CupertinoIcons.tray_arrow_down_fill,
                        size: 24,
                        color: MacPalette.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'DropDrawer',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                      color: MacPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '跨端文件暂存抽屉',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: MacPalette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 28),
                  // macOS System Settings grouped form
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: MacPalette.hairline, width: 0.8),
                    ),
                    child: Column(
                      children: [
                        MacFormField(
                          controller: _serverCtrl,
                          label: '服务器',
                          placeholder: 'http://127.0.0.1:8080',
                        ),
                        const Divider(height: 0.5, thickness: 0.5, indent: 12),
                        MacFormField(
                          controller: _userCtrl,
                          label: '账号',
                          placeholder: '输入用户名',
                        ),
                        const Divider(height: 0.5, thickness: 0.5, indent: 12),
                        MacFormField(
                          controller: _passCtrl,
                          label: '密码',
                          placeholder: '至少 6 位',
                          obscureText: true,
                          onSubmitted: (_) => _submit(),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: MacPalette.red,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 36,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MacPalette.textPrimary,
                        foregroundColor: const Color(0xFF111113),
                        disabledBackgroundColor:
                            Colors.white.withValues(alpha: 0.25),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: _loading
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: Color(0xFF111113),
                              ),
                            )
                          : Text(_isRegister ? '创建账号并连接' : '继续'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _isRegister = !_isRegister;
                        _error = null;
                      }),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            _isRegister ? '已有账号，返回登录' : '还没有账号？创建一个',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: MacPalette.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
