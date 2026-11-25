# DropDrawer 技术架构文档

本文档记录 DropDrawer 的系统架构、通信协议、P2P 传输细节、桌面原生桥接规范与移动端后续规划。

---

## 1. 总体架构

DropDrawer 将**控制面**与**数据面**解耦：

- **控制面（`crates/server`，Axum + SQLite）**：
  - 负责用户认证（JWT）、设备注册与在线心跳、抽屉条目元数据同步（WebSocket `/ws`）、下载计划调度（`DownloadPlan`）、多云盘凭据管理、TTL 定期清理与外链分享管理。
- **数据面 A — 端到端 P2P（`crates/p2p-core`，`iroh` QUIC）**：
  - 双方在线时优先直连传输，客户端通过 C-ABI FFI 加载本地 `libdropdrawer_p2p.dylib` / `dropdrawer_p2p.dll` / `libdropdrawer_p2p.so`。
  - 源文件按路径引用做种（零磁盘冗余拷贝），经控制面下发短时一次性 `transfer_token` 授权拉取。
- **数据面 B — 原生多云盘中转（零外部 Sidecar）**：
  - 按策略（`smart` 小于阈值自动上云 / `cloud_cached` 全部上云 / `p2p_only` 仅 P2P）或在 P2P 不可达/失败时自动回退云端。
  - 所有存储后端均在 `crates/server/src/storage/` 内原生实现：
    - `google_drive.rs`：Google Drive OAuth2（内置授权跳转与回调）+ Resumable Upload
    - `quark.rs`：夸克网盘原生接口
    - `baidu.rs`：百度网盘原生接口
    - `s3.rs`：S3 / Cloudflare R2 / OSS（Presigned URL 支持直传直下）
    - `webdav.rs`：标准 WebDAV
    - `local.rs`：服务端本地目录（`/data/blobs`）

---

## 2. P2P 传输核心 (`crates/p2p-core`)

### 2.1 协议与连接流程
- **ALPN**：`/dropdrawer/file/1`
- **连接与路径迁移**：
  - `P2pNode` 在收到远端 `EndpointId`、`relay_url` 与 `direct_addrs` 后通过 `iroh::Endpoint` 建立 QUIC 连接。
  - 在 macOS / Windows 上，传输循环每 200ms 轮询 `detect_path_kind(&conn)` 实时上报 `p2p_connecting` / `p2p_direct` / `p2p_relay`。
  - 若连接 6 秒后仍停留在中继路径，仅由下载发起方触发 `RelayProbe`（[relay_probe.rs](../crates/p2p-core/src/relay_probe.rs)），携带完整 `EndpointAddr` 发起一次辅助 QUIC 握手促使 `iroh` 重新打洞；完成后以 `PROBE_CODE (0x4450)` 关闭，接收端静默忽略该辅助连接。
- **断点续传与防冲突**：
  - 分片临时文件命名为 `<dest_path>.dropdrawer.part`（追加后缀而非替换扩展名），彻底避免 `a.png` 与 `a.jpg` 冲突。
  - 本地通过 `PartialLease` (`DashSet<PathBuf>`) 防止并发写入同一目标路径。
  - 对升级前遗留的旧命名 `a.dropdrawer.part`：仅在无同名异后缀歧义（`!skip_legacy_resume`）且对端校验前缀 BLAKE3 一致时才安全迁入续传，否则保留原文件不误删。
- **完整性与送达回执**：
  - 接收方写完分片后计算全文件 BLAKE3 校验和，通过后原子 `rename` 到目标路径。
  - 若协商支持回执（`wants_receipt` / `supports_receipt`，向后兼容旧版），接收方落盘后发送应用关闭码 `DELIVERED_CODE (0x4444)`；发送方先通过 `send.stopped().await` 确认对端读完流（`Ok(None)`），再等待 `DELIVERED_CODE` 确认送达，真实断线或 `STOP_SENDING` 会如实报错。
- **双向取消与事件队列 (`transfers.rs`)**：
  - 每条下载与发送任务拥有独立 `transfer_id` 与 `oneshot` 取消通道；任意一端取消时发送 `CANCEL_CODE (0x4443)` 立即终止连接，且不触发云端回退。
  - `Transfers` 将事件拆分为 `live: VecDeque`（按 `transfer_id` 去重、上限 256）与 `finished: Vec`（无上限），确保终态事件永不被进度刷新挤掉。

### 2.2 C-ABI FFI 接口 (`crates/p2p-core/src/ffi.rs`)
所有函数返回堆分配的 UTF-8 JSON 字符串（`{"ok": bool, "data": ..., "error": ...}`），调用方必须通过 `dropdrawer_p2p_free_string` 释放：
- `dropdrawer_p2p_start(config_json)`
- `dropdrawer_p2p_node_info()`
- `dropdrawer_p2p_register_file(req_json)`
- `dropdrawer_p2p_unregister_file(item_id)`
- `dropdrawer_p2p_authorize_token(req_json)`
- `dropdrawer_p2p_download_file(req_json)` → 返回 `transfer_id`
- `dropdrawer_p2p_cancel_transfer(transfer_id)`
- `dropdrawer_p2p_poll_events()`
- `dropdrawer_p2p_shutdown()`
- `dropdrawer_p2p_free_string(ptr)`

---

## 3. 服务端 API 与外链分享 (`crates/server`)

### 核心路由
- **健康检查**：`GET /health`
- **认证**：`POST /api/auth/register`、`POST /api/auth/login`
- **设备**：`POST /api/devices`、`GET /api/devices`
- **实时同步**：`GET /ws`（推送条目变更、设备上下线、P2P 授权 token）
- **抽屉条目**：`GET /api/drawer/items`、`POST /api/drawer/items`、`DELETE /api/drawer/items/{id}`、`PUT /api/drawer/items/{id}/file`、`GET /api/drawer/items/{id}/download-plan`、`GET /api/drawer/items/{id}/download`
- **存储后端**：`GET /api/storage/backends`、`POST /api/storage/backends`、`DELETE /api/storage/backends/{id}`、`POST /api/storage/backends/{id}/health`、`POST /api/storage/google/oauth/start`、`GET /api/storage/google/oauth/callback`
- **公网外链分享**：
  - 管理接口：`POST /api/drawer/items/{id}/share`（单文件）、`POST /api/shares`（多选打包）、`GET /api/shares`、`DELETE /api/shares/{code}`
  - 公开访问：`GET /s/{code}`（内置响应式下载页，支持单文件与多文件打包）、`GET /api/s/{code}/meta`、`GET /api/s/{code}/download?item_id=&passcode=`

---

## 4. 桌面原生层 (`com.dropdrawer/drawer_window`)

Dart 侧通过 [drawer_window_service.dart](../app/lib/services/drawer_window_service.dart) 统一与 macOS / Windows 原生窗口通信。

### 4.1 macOS (`app/macos/Runner/`)
- **窗口管理 (`MainFlutterWindow.swift`)**：无标题栏毛玻璃贴边悬浮窗，支持 `collapsed` / `drag_pill` / `expanded` 三态，折叠手柄与展开态顶部拖条均可拖拽调整垂直位置及跨屏左右停靠（持久化到 `UserDefaults`）。
- **菜单与状态栏 (`AppDelegate.swift`)**：原生 `NSMenu`（含 SF Symbols），状态栏左键菜单常驻，支持可选 Dock 图标与 `⌘Q` 退出。
- **全局快捷键**：基于 `CGEvent.tapCreate`（辅助功能）+ `NSEvent.addGlobalMonitorForEvents`（输入监控）+ 本地监听，支持实时录制与权限状态检测。
- **文件与媒体**：原生 `ImageIO` 缩略图生成、剪贴板读写（文件/截图/文本）、`/usr/bin/ditto` 文件夹无损 ZIP 打包。
- **签名与打包**：`scripts/build_macos_release.sh` 固定 `arm64` Release，预编译 `super_native_extensions`（`LTO=false`、`panic=unwind`），嵌入 `libdropdrawer_p2p.dylib` 并使用 Apple Development 证书签名（保证重新打包后 macOS 辅助功能 TCC 权限不失效）。

### 4.2 Windows (`app/windows/runner/` + `deploy/windows/`)
- **窗口与托盘 (`drawer_window.cpp`)**：单实例互斥锁 `Local\DropDrawer`、系统托盘图标与右键菜单、`WS_POPUP` 贴边抽屉、`CreateRoundRectRgn` 按 DPI 缩放裁剪圆角（响应 `WM_DPICHANGED` 与 `WM_DISPLAYCHANGE`）、折叠手柄与展开态顶部拖条支持上下滑动与跨屏左右停靠。
- **拖拽唤出与防误触**：通过 `CLIPBRDWNDCLASS` + `SHELLDLL_DefView` 祖先链识别资源管理器/桌面文件拖动自动弹引导条（避免网页文本/标签页误触发）；`OnTimer`、`WM_ACTIVATE`、`kOutsideClickMessage` 均带 `!IsOleDragActive()` 守卫，防止从抽屉拖出文件时中途收起。
- **剪贴板与文件 (`drawer_files.cpp`)**：`CF_HDROP` + `Preferred DropEffect` 多文件复制（跳过失效路径）、WIC 截图保存（由启动阶段 `pruneClipboardFiles` 排除抽屉保留路径后清理超 24h 旧缓存）、`SHOpenFolderAndSelectItems` 定位文件、PowerShell `.NET ZipFile`（UTF-8 编码，回退绝对路径 `%SystemRoot%\System32\tar.exe`）打包文件夹。
- **安装、升级与卸载 (`DropDrawer.iss`)**：
  - 处理 `WM_QUERYENDSESSION` / `WM_ENDSESSION` 及自定义退出消息 `kQuitMessage (WM_APP + 2 = 0x8002)`。
  - 安装器在 `PrepareToInstall` 与卸载 `usUninstall` 中主动向 `FLUTTER_RUNNER_WIN32_WINDOW` / `DropDrawer` 发送 `$8002` 并等待互斥体释放，彻底解决托盘驻留态覆盖升级/卸载文件占用问题；卸载后清理 `HKCU\...\Run\DropDrawer` 与 `HKCU\Software\DropDrawer`。

---

## 5. 移动端原生层 (`com.dropdrawer/mobile`)

Dart 侧通过 [drawer_window_service.dart](../app/lib/services/drawer_window_service.dart) 在 iOS / Android 上接入 `com.dropdrawer/mobile` MethodChannel：

- **Android (`app/android/`)**：
  - `AndroidManifest.xml` 注册 `ACTION_SEND` / `ACTION_SEND_MULTIPLE` Intent 接收其他 App 分享的文件、图片、视频与文本，并配置 `FileProvider`（`res/xml/file_paths.xml`）和网络/局域网组播权限。
  - `MainActivity.kt` 实现 `consumePendingShares` / `onSharedPayload`、`shareFiles` / `shareText`、`saveToGallery`（Android 10+ `MediaStore` 零存储权限写入 `Pictures/DropDrawer` 或 `Movies/DropDrawer`）、`openExternalUrl`（支持 Google Drive OAuth）与 `readClipboard`（支持图片 URI 与文本）。
  - `.github/workflows/android-apk.yml` 使用 `cargo-ndk` 编译 `arm64-v8a` & `armeabi-v7a` 的 `libdropdrawer_p2p.so` 打包进 APK。
- **iOS (`app/ios/`)**：
  - `Info.plist` 配置 `CFBundleDocumentTypes`（支持其他 App「用 DropDrawer 打开」）、`dropdrawer://` URL Scheme、`UIFileSharingEnabled`（下载文件在 iOS「文件」App 可见）以及局域网与相册权限说明。
  - `AppDelegate.swift` + `SceneDelegate.swift` 实现 `DropDrawerMobileBridge`（`UIActivityViewController` 分享、`PHPhotoLibrary` 存相册、`UIPasteboard` 图片/文本粘贴、`Documents/Inbox` + App Group `group.com.dropdrawer.shared` 分享队列）。
  - `scripts/build_ios_p2p.sh` 交叉编译 `aarch64-apple-ios` 与 `aarch64-apple-ios-sim` 静态库并打包 `DropDrawerP2P.xcframework`，经本地 CocoaPod `app/ios/DropDrawerP2P/DropDrawerP2P.podspec` 使用 `-Wl,-u,_dropdrawer_p2p_*` 强制保留全部 10 个 C-ABI 符号供 `DynamicLibrary.process()` 调用。
