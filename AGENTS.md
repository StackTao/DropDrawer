# AGENTS.md — DropDrawer 协作与工程指南

本文件为所有参与本仓库开发的 AI 智能体与开发者提供项目上下文、架构不变量、已知避坑点与验证标准。更完整的架构与协议细节见 [README.md](README.md) 与 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 1. 项目现状

- **已完成（v1.0 第一版）**：
  - Rust 服务端（`crates/server`：Axum + SQLite + WebSocket + 零 sidecar 原生多云盘 + 公网外链分享）
  - Rust P2P 核心（`crates/p2p-core`：`iroh` QUIC、断点续传、BLAKE3、实时路径、中继打洞重试、送达回执、双向取消）
  - Flutter **macOS 桌面端**（原生贴边抽屉、展开态/折叠态可拖拽停靠、`NSMenu`、`CGEventTap` 全局热键、签名与 DMG 打包）
  - Flutter **Windows 桌面端**（Win32 贴边抽屉、展开态/折叠态可拖拽停靠、托盘单实例、Inno Setup 覆盖升级/卸载清理、GitHub Actions 端到端烟测）
  - Flutter **移动端（iOS / Android）**：触控 UI 适配（`SafeArea`、快捷选文件/相册/粘贴、下拉刷新、系统分享与存相册）、Android `ACTION_SEND` + `FileProvider` + `MediaStore` + `android-apk.yml` CI、iOS `DropDrawerMobileBridge` + `DropDrawerP2P.xcframework`（`scripts/build_ios_p2p.sh`）
- **后续增强方向**：
  - iOS 独立 Share Extension target（需配置 Apple Developer App Group 签名）与真机 TestFlight / Android 正式 Release 签名密钥配置。

---

## 2. 必须遵守的架构与工程不变量

### 架构原则
1. **禁止引入外部云盘 Sidecar**：所有网盘存储后端必须在 `crates/server/src/storage/` 中原生实现（目前支持 `google_drive` / `quark` / `baidu` / `s3` / `webdav` / `local`），不要重新引入 OpenList / Alist 等外部容器。
2. **严禁泄露凭据与敏感配置**：不要在代码、文档、测试、日志或提交记录中写入真实域名密码、JWT Secret、OAuth Client Secret、网盘 Cookie、SSH 私钥或签名密码。
3. **保持锁文件与 CI 严格兼容**：Windows CI 使用 `flutter pub get --enforce-lockfile` 和 `cargo ... --locked`。如修改依赖，必须同步更新 `Cargo.lock` / `app/pubspec.lock`。

### P2P & 传输安全不变量
4. **C-ABI 符号变更需同步双端与文档**：修改 `crates/p2p-core/src/ffi.rs` 导出函数时，必须同步更新 `app/lib/services/p2p_ffi.dart`、重新编译本机动态库，并确认 CI 中的符号检查同步。
5. **`TransferCancelToken` 必须支持多监听器**：`app/lib/services/api_client.dart` 中的 `TransferCancelToken.attach()` 维护回调列表（严禁改回单回调覆盖）。
6. **取消原生 P2P 传输时不得提前丢弃任务 ID**：点击取消后应保持「正在取消」态并保留 `_p2pDownloadIds[itemId]` / `_cancellingSends` 直到原生返回终态事件，避免原生刚好落盘成功却被轮询过滤丢弃。
7. **禁止在覆盖下载失败时先删除已有目标文件**：云端下载写入同卷临时目录后再原子 `rename` 到目标路径；禁止在 `catch` 中先 `delete` 目标文件再重试，以免临时文件被占用时删丢用户原文件。
8. **发送端必须确认送达回执**：`crates/p2p-core/src/lib.rs` 中 `send.stopped().await` 仅 `Ok(None)` 代表流确认完毕，配合 `wants_receipt` / `DELIVERED_CODE (0x4444)` 确认接收方落盘；不要吞掉 `Ok(Some(_))` 或非取消断线错误。
9. **终态事件不可被进度刷新挤掉**：`crates/p2p-core/src/transfers.rs` 将 `live` 进度与 `finished` 终态分队列存储，并避免在 FFI 内对 `Mutex::lock()` 使用 `.unwrap()`。
10. **分片文件命名不能碰撞同名异后缀**：统一使用 `<dest_path>.dropdrawer.part`（`part_path_for`），不要使用 `with_extension("dropdrawer.part")`；对旧分片仅在校验前缀 BLAKE3 一致且无歧义时迁移。

### 桌面端平台避坑点
11. **Flutter `instantiateImageCodecWithSize` 所有权规则**：传入 `ui.instantiateImageCodecWithSize(buffer, ...)` 的 `ImmutableBuffer` 会由该方法自动释放，**严禁在外层 `finally` 中重复调用 `buffer.dispose()`**（会触发重复释放断言导致缩略图返回 `null`）。
12. **剪贴板缓存清理不得误删抽屉源文件**：`pruneClipboardFiles` 必须排除 `localFilePaths.values`（规范化路径比对），且仅清理过期截图文件。
13. **Windows 文件夹打包禁止裸调 PATH 中的 `tar.exe`**：优先调用 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` 的 `.NET ZipFile`（强制 UTF-8 编码），回退到绝对路径 `%SystemRoot%\System32\tar.exe`，防止被 Git Bash 的 GNU tar 劫持。
14. **Windows 安装/升级不要加 `AppMutex`**：Inno Setup 的 `AppMutex` 会阻断自动静默升级/卸载流程。当前 [deploy/windows/DropDrawer.iss](deploy/windows/DropDrawer.iss) 通过 `[Code]` 向窗口发送 `$8002`（`WM_APP + 2 = kQuitMessage`）优雅关闭托盘进程，并配合 `WM_QUERYENDSESSION`/`WM_ENDSESSION` 与卸载注册表清理；改动退出消息值时必须同步 `DropDrawer.iss` 与 `drawer_window.cpp`。
15. **Windows 边缘模式与拖拽守卫**：
    - 圆角优先用 Windows 11 的 `DWMWA_WINDOW_CORNER_PREFERENCE`（抗锯齿）；失败时（Windows 10）回退 `CreateRoundRectRgn`，其第 5/6 参数是椭圆**直径**（`2 * radius`），且 `WM_DPICHANGED` 需重排 `PlaceDrawer()`。
    - 资源管理器/桌面（`SHELLDLL_DefView`）里的文件拖动会**立即**弹引导条；其他 OLE 拖动（浏览器、编辑器、聊天软件里的文字等）只有靠近折叠手柄 `kHandleDragReach`（28 逻辑像素）以内才弹，避免选中或拖动网页文字时误触发。`OnTimer`、`WM_ACTIVATE`、`kOutsideClickMessage` 均需检查 `!IsOleDragActive()` 防止拖出文件时误收起。
    - 常规窗口顶部左侧 `78px` 留白仅用于 macOS 红绿灯（`windowService.needsMacTrafficLightPadding`），不要加在 Windows/移动端上。
16. **抽屉模式切换必须等 Flutter 画好再显示**：原生层切换 `collapsed` / `drag_pill` / `expanded` 时先隐藏窗口（macOS `alphaValue = 0`，Windows 空 `SetWindowRgn`），改尺寸后再发 `onDrawerStateChanged`，收到 Dart 回传的 `drawerFrameReady {mode}` 才显示（超时 160ms 兜底）。否则旧模式的布局会被拉伸进新尺寸的窗口里（"变形"）。改动该协议时必须同步 `drawer_window_service.dart`、`MainFlutterWindow.swift` 与 `drawer_window.cpp`；动画只用等比缩放与临界阻尼弹簧，不要再用 `sx ≠ sy` 的变换。
17. **界面配色只用 `MacPalette`，且它不是常量**：手机端跟随系统浅色/深色（`MacPalette.use` + `main.dart` 全量重建），桌面端固定深色（macOS 窗口强制 `darkAqua`）。`MacPalette.*` 是运行时 getter，不能放进 `const` 表达式或参数默认值；不要新增 `Colors.white/black.withValues(...)` 或深色十六进制字面量，改用 `MacPalette.fill()`（中性叠加）、`shade()`（凹陷区域）、`group()`（分组面板）、`background`、`onTextPrimary` 等语义色。Material 3 的分隔线和描边颜色取自 `colorScheme.outlineVariant` / `outline`，不是 `dividerColor`。
18. **Windows 毛玻璃需要 DWM 确认后才半透明**：`ApplyBackdrop()` 用 `DWMWA_SYSTEMBACKDROP_TYPE`（常规窗口 Mica、边缘抽屉 Acrylic，Windows 11 22H2+）并 `DwmExtendFrameIntoClientArea`；只有原生回报 `backdrop: true` 时 Flutter 才画半透明底色，否则保持不透明 `#202020`。偏好设置里可关闭（注册表 `Backdrop`）。
19. **macOS Release 构建要点**：
    - 使用 `./scripts/build_macos_release.sh`（已处理 `ARCHS=arm64`、`super_native_extensions` 预编译 `CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_PANIC=unwind` 与 Apple Development 证书签名，避免 TCC 辅助功能权限重建后失效）。
    - 若更改过项目目录路径，需先清理 `app/build/macos` 避免 Xcode stale file 报错。

---

## 3. 验证与测试要求

提交前务必按影响范围运行对应验证：

```bash
# Rust 全量编译与测试（含 server 集成测试 & p2p-core 单元测试）
cargo test --workspace

# Flutter 静态分析与全部测试
cd app && flutter analyze && flutter test
```

- 改动 Windows 原生代码、打包脚本或 CI 时，推送后应触发 `.github/workflows/windows-installer.yml` 验证编译、Rust/Flutter Windows 专属测试、以及托盘态覆盖升级与静默卸载烟测。
- 改动 macOS 原生代码、P2P FFI 或共享 Dart 代码并需更新本机客户端时，运行 `./scripts/build_macos_release.sh --install`。
