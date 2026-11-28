# AGENTS.md — DropDrawer 协作与工程指南

本文件为所有参与本仓库开发的 AI 智能体与开发者提供项目上下文、架构不变量、已知避坑点与验证标准。更完整的架构与协议细节见 [README.md](README.md) 与 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 1. 项目现状

- **已完成（v1.0 第一版）**：
  - Rust 服务端（`crates/server`：Axum + SQLite + WebSocket + 零 sidecar 原生多云盘 + 公网外链分享）
  - Rust P2P 核心（`crates/p2p-core`：`iroh` QUIC、断点续传、BLAKE3、实时路径、中继打洞重试、送达回执、双向取消）
  - Flutter **macOS 桌面端**（原生贴边抽屉、展开态/折叠态可拖拽停靠、`NSMenu`、`CGEventTap` 全局热键、签名与 DMG 打包）
  - Flutter **Windows 桌面端**（Win32 贴边抽屉、展开态/折叠态可拖拽停靠、托盘单实例、Inno Setup 覆盖升级/卸载清理、GitHub Actions 端到端烟测）
  - Flutter **桌面端（macOS / Windows）与 Android 移动端**：macOS/Windows 原生贴边抽屉、展开态/折叠态可拖拽停靠、托盘与安装包；Android 触控 UI（Material 3）、`ACTION_SEND` + `FileProvider` + `MediaStore` + `android-apk.yml` CI
  - **原生 Swift / SwiftUI iOS 客户端（`apple/`）**：`DropDrawerCore`（REST / WebSocket / `DropDrawerP2P.xcframework` / Keychain + App Group 存储）、`DropDrawerIOS`（iOS 18+/26 Liquid Glass 原生导航、QuickLook、相册流式导入、降采样缩略图缓存、本地缓存清理）与 `DropDrawerShareExtension`（`group.com.dropdrawer.shared`），由 `apple/project.yml` + `scripts/build_apple_p2p.sh` 构建
- **后续增强方向**：
  - iOS 真机 Apple Developer App Group 签名 / TestFlight 与 Android 正式 Release 签名密钥配置。

---

## 2. 必须遵守的架构与工程不变量

### 架构原则
1. **禁止引入外部云盘 Sidecar**：所有网盘存储后端必须在 `crates/server/src/storage/` 中原生实现（目前支持 `google_drive` / `quark` / `baidu` / `s3` / `webdav` / `local`），不要重新引入 OpenList / Alist 等外部容器。
2. **严禁泄露凭据与敏感配置**：不要在代码、文档、测试、日志或提交记录中写入真实域名密码、JWT Secret、OAuth Client Secret、网盘 Cookie、SSH 私钥或签名密码。
3. **保持锁文件与 CI 严格兼容**：Windows CI 使用 `flutter pub get --enforce-lockfile` 和 `cargo ... --locked`。如修改依赖，必须同步更新 `Cargo.lock` / `app/pubspec.lock`。

4a. **凭据加密存储不能绕过**：`storage_backends.config_json`、`system_settings` 的值和管理员 `totp_secret` 只能经 `Database` 的方法读写（`crate::secret_box` 加密，附加认证数据绑定表名与行 ID），不要再写直接读这些列的 SQL（统计用明文 `kind` 列）。密钥来自 `DROPDRAWER_SECRET_KEY` 或数据库同目录的 `secret_key`；密钥缺失或不匹配时必须拒绝启动，不能悄悄生成新密钥。
4b. **推送通知不带正文**：`crate::push` 只推给同账号下处于后台或没有 WebSocket 连接、且不是来源设备的其他设备；通知只含设备名和文件名，文字条目不能带内容。`disconnect_user_except`（改密码、强制下线、停用）会删除被下线设备的推送令牌，客户端退出登录时注销自己的令牌。Android 不打包 `google-services.json`，Firebase 选项由 `/api/client/config` 的 `push.fcm` 下发（`PushRegistrar.kt`）。
4c. **百度网盘的 refresh_token 只能用一次**：每次刷新返回的新令牌对都要经 `BaiduTokenSink` 写回存储配置，同一后端的刷新在 `TOKEN_SESSIONS` 里串行；不要恢复成每个请求各自刷新。WebDAV 上传前要逐级 `MKCOL` 父目录（`405` 表示已存在）。

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
    - 外部应用的 OLE 拖放（`IsExternalOleDragActive()`：检测其他进程的 `CLIPBRDWNDCLASS` 捕获，覆盖资源管理器/第三方软件拖文件以及浏览器/编辑器/聊天软件拖文字；纯框选文字不会触发 OLE 拖放）会**立即**弹出边缘引导条，松手后自动收起，与 macOS 保持一致。`OnTimer`、`WM_ACTIVATE`、`kOutsideClickMessage` 仍需检查 `!IsOleDragActive()` 防止从抽屉拖出文件时误收起。
    - 常规窗口顶部左侧 `78px` 留白仅用于 macOS 红绿灯（`windowService.needsMacTrafficLightPadding`），不要加在 Windows/移动端上。
16. **抽屉模式切换必须等 Flutter 画好再显示**：原生层切换 `collapsed` / `drag_pill` / `expanded` 时先隐藏窗口（macOS `alphaValue = 0`，Windows 空 `SetWindowRgn`），改尺寸后再发 `onDrawerStateChanged`，收到 Dart 回传的 `drawerFrameReady {mode}` 才显示（超时 160ms 兜底）。否则旧模式的布局会被拉伸进新尺寸的窗口里（"变形"）。改动该协议时必须同步 `drawer_window_service.dart`、`MainFlutterWindow.swift` 与 `drawer_window.cpp`；动画只用等比缩放与临界阻尼弹簧，不要再用 `sx ≠ sy` 的变换。
16a. **`drawer_screen.dart` 按 part 拆分**：手机端和桌面端的构建方法分别在 `drawer_screen_phone.dart` / `drawer_screen_desktop.dart` 的 `extension` 里，小组件在 `drawer_screen_widgets.dart`。extension 里不能调用 `setState`（protected），需要 `setState` 的方法留在 `_DrawerScreenState` 本体；extension 里引用类的静态成员要写 `_DrawerScreenState.xxx`。服务端路由同理按领域拆在 `crates/server/src/routes/{account,devices,storage_backends,items,shares,ws}.rs`，子模块 `use super::*`，供路由表使用的函数标 `pub(super)`。
17. **界面配色只用 `MacPalette`，且它不是常量**：手机端跟随系统浅色/深色（`MacPalette.use` + `main.dart` 全量重建），桌面端固定深色（macOS 窗口强制 `darkAqua`）。`MacPalette.*` 是运行时 getter，不能放进 `const` 表达式或参数默认值；不要新增 `Colors.white/black.withValues(...)` 或深色十六进制字面量，改用 `MacPalette.fill()`（中性叠加）、`shade()`（凹陷区域）、`group()`（分组面板）、`background`、`onTextPrimary` 等语义色。Material 3 的分隔线和描边颜色取自 `colorScheme.outlineVariant` / `outline`，不是 `dividerColor`。
18. **Windows 毛玻璃需要 DWM 确认后才半透明**：`ApplyBackdrop()` 用 `DWMWA_SYSTEMBACKDROP_TYPE`（常规窗口 Mica、边缘抽屉 Acrylic，Windows 11 22H2+）并 `DwmExtendFrameIntoClientArea`；只有原生回报 `backdrop: true` 时 Flutter 才画半透明底色，否则保持不透明 `#202020`。偏好设置里可关闭（注册表 `Backdrop`）。
19. **应用内更新只给打了发布标签的构建**：`DROPDRAWER_RELEASE_TAG` 必须与 `app/pubspec.yaml` 版本一致（`scripts/check_release_tag.sh`，macOS 打包脚本和两个 CI 工作流都会调用）；未打标签的构建是开发版，不检查更新。原生安装入口 `installUpdate` 需同步 `drawer_window_service.dart`、`MainFlutterWindow.swift`（挂载 DMG、校验新包满足当前应用的指定签名要求后退出替换并重启）、`drawer_files.cpp`（`/SILENT /UPDATE=1` 运行安装器，`DropDrawer.iss` 据此重启应用）与 `MainActivity.kt`（比对签名证书）。macOS 发布版必须始终用同一张证书签名，不要给 Windows 更新包加 Mark-of-the-Web。
20. **macOS Release 构建要点**：
    - 使用 `./scripts/build_macos_release.sh`（已处理 `ARCHS=arm64`、`super_native_extensions` 预编译 `CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_PANIC=unwind` 与 Apple Development 证书签名，避免 TCC 辅助功能权限重建后失效）。
    - 若更改过项目目录路径，需先清理 `app/build/macos` 避免 Xcode stale file 报错。

21. **手机端二级页面是路由，不是原地切换**：手机上偏好设置、设备、外链、预览、云盘由 `DrawerScreen._pushPhonePage` 推入（iOS `CupertinoPageRoute` 支持边缘右滑返回，Android `MaterialPageRoute`），页面用 `AdaptivePage`（`app/lib/ui/phone_page.dart`）：桌面保留原紧凑标题行，手机换成 iOS 导航栏 / Material 3 顶栏，正文套 `PhoneTypeScaler` 把桌面字号映射到系统字号阶梯。桌面端仍是 `_page` 原地切换。iOS/Android 外观按 `Theme.of(context).platform` 区分（`usesMaterialChrome`）。
    - 手机首页：iOS 是大标题导航栏 +「+」/「…」下拉菜单、内嵌分组列表、左滑「移出」（无撤销）、长按 `CupertinoContextMenu`、顶部胶囊提示；Android 参照 Files by Google：浮动搜索栏充当顶栏（「更多」菜单在栏内，搜索时出现筛选 chip）、下方设备在线 `ActionChip` + 项目数、悬浮「添加」按钮 + 底部面板、全宽列表项（色调底图标）、滑动删除带撤销 Snackbar、长按进入多选（顶栏换成「已选 N 项」）。
    - iOS 下拉菜单用 `showPullDownMenu`（弹出路由），**不要换回 `CupertinoMenuAnchor`**：它的 `OverlayPortal` 在大标题导航栏收起/转场重排按钮时会触发布局断言。
    - 已按手机尺寸写的组件（`PhoneSection` / `PhoneRow` / `PhoneButton`）用 `NativeTypeScale` 退出 `PhoneTypeScaler`，避免字号被映射两次。
    - iOS 深色用 `MacPalette.use(..., trueBlack: true)`：纯黑底 + `#1C1C1E` 分组行；桌面深色不变。
    - Android 用 `MacPalette.use(..., material: true)`：浅色/深色都取自 `materialScheme()`（蓝色种子生成的 Material 3 色调角色），`buildAppTheme` 的 `colorScheme` 也用它；Android 上不要写死 iOS 系统色，图标底板用 `MacPalette.tonal` / `onTonal`。
    - 手机文件预览走原生 `openFile`（iOS QuickLook / Android `ACTION_VIEW`），打不开时退回系统分享；改动需同步 `drawer_window_service.dart`、`AppDelegate.swift`、`MainActivity.kt`。

### 多语言（中文 / English）
22. **界面文字一律走翻译表，中文是源语言**：新增或修改用户可见文字时，五处都要同时给出中文和英文。
    - **Flutter**：文案写在 `app/lib/l10n/app_zh.arb`（模板）和 `app_en.arb`，改完运行 `flutter gen-l10n`（生成的 `app_localizations*.dart` 已提交）。代码里用 `l10n.xxx`，它和 `MacPalette` 一样是运行时 getter，不能放进 `const` 或参数默认值。日期用 `AppLocale.shortDate` / `dateTime` / `time`，不要手写「M月d日」。语言选择存在 `app_language`，切换后由 `main.dart` 全量重建；macOS / Windows 原生菜单、托盘和对话框的文字由 `AppLocale.nativeStrings()` 经 `setNativeStrings` 下发（`NativeStrings` / `DrawerWindow::Text`），新增原生文字要同步这三处。Android 原生文字放 `res/values`（英文）和 `res/values-zh`。
    - **服务端**：返回给用户的消息用 `t!("中文", "English")`，带格式用 `tf!`。语言来自请求的 `Accept-Language`（`crate::i18n` 中间件）；没有该请求头时返回中文，兼容旧客户端。浏览器页面要设置 `<html lang>`。
    - **管理端**：`admin.js` 里的中文文案包在 `t("…")` 里，英文写进 `admin-i18n.js` 的 `EN` 字典；`index.html` 的静态文字按同一字典自动翻译。
    - **官网**（`website/index.html`）：同样以中文为键，英文写进页面里第一个 `<script>` 的 `EN` 字典；静态文字自动翻译，脚本里的文字用 `t("…")`。同一个中文词在不同位置英文不同时，给元素加 `data-en="…"`。`?lang=en` / `?lang=zh` 可直接指定语言。
    - **iOS**：Swift 里的中文一律写成 `String(localized: "…")`（`DropDrawerCore` 里加 `bundle: Bundle.module`），英文写进对应的 `Localizable.xcstrings`。键里的占位符由插值类型决定：`Int` 是 `%lld`，`String` 是 `%@`，写错会退回中文。
    - **测试**：Flutter 测试默认用中文运行（`test/flutter_test_config.dart`），英文布局在 `drawer_ui_polish_test.dart` 的 `English layout` 组里验证。`DROPDRAWER_TEST_LANGUAGE=en flutter test` 可以用英文跑全部测试，专门找溢出（文字断言失败属于预期）。

---

## 3. 验证与测试要求

提交前务必按影响范围运行对应验证：

```bash
# Rust 全量编译与测试（含 server 集成测试 & p2p-core 单元测试）
cargo test --workspace

# Flutter 静态分析与全部测试
cd app && flutter analyze && flutter test

# 原生 Swift DropDrawerCore 单元测试（macOS）
cd apple/DropDrawerCore && swift test
```

- 改动 Windows 原生代码、打包脚本或 CI 时，推送后应触发 `.github/workflows/windows-installer.yml` 验证编译、Rust/Flutter Windows 专属测试、以及托盘态覆盖升级与静默卸载烟测。
- 改动 macOS 原生代码、P2P FFI 或共享 Dart 代码并需更新本机客户端时，运行 `./scripts/build_macos_release.sh --install`。
