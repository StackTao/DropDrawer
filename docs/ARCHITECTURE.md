# DropDrawer 技术架构文档

本文档记录 DropDrawer 的系统架构、通信协议、P2P 传输细节、桌面原生桥接规范与移动端后续规划。

---

## 1. 总体架构

DropDrawer 将**控制面**与**数据面**解耦：

- **控制面（`crates/server`，Axum + SQLite）**：
  - 负责用户认证（JWT）、设备注册与在线心跳、抽屉条目元数据同步（WebSocket `/ws`）、下载计划调度（`DownloadPlan`）、多云盘凭据管理、TTL 定期清理与外链分享管理。
- **数据面 A — 端到端 P2P（`crates/p2p-core`，`iroh` QUIC）**：
  - 双方在线时优先直连传输，客户端通过 C-ABI FFI 加载本地 `libdropdrawer_p2p.dylib` / `dropdrawer_p2p.dll` / `libdropdrawer_p2p.so`。
  - 源文件按路径引用做种（零磁盘冗余拷贝），经控制面下发短时一次性 `transfer_token` 授权拉取：token 10 分钟有效、校验通过即作废，并绑定请求方设备的 iroh 节点 ID（`requester_node_id`）；源端收到早于 token 推送到达的请求时最多等待 5 秒；服务端仅在 token 成功推送到源设备后才在下载计划中提供 P2P。
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
  - 分片旁的 `<dest_path>.dropdrawer.part.owner` 记录所属条目 ID：同名但属于其他条目的分片不会被续传（删除后从 0 开始）；无 owner 文件的旧分片按原逻辑续传。接收方写入超过对端声明大小的数据时立即中止。
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
- `dropdrawer_p2p_node_info()` — WebSocket 连接时上报，此后仅在中继或直连候选变化时重发。Android 在 Application 启动时通过 JNI 提供系统 DNS 上下文，并将默认网络变化通知现有 iroh 节点。
  - 安卓和 iOS 共用节点地址更新机制。iOS 通过 iroh 的 BSD 路由监听感知换网。原设备首次 QUIC 握手超时后，客户端重新发现同一节点并重试一次。
  - 原设备上报 BLAKE3 后，服务端可为同账号在线设备上报的匹配副本签发单次令牌。下载方最多用 3 秒确认候选局域网地址上的 QUIC 直连，接收时核对原文件摘要。副本失败时重新请求原设备的授权，已取消的任务不会自动重试。
- `dropdrawer_p2p_register_file(req_json)`：只做 `stat` 并按路径登记后立即返回（`blake3_hash` 为空字符串），BLAKE3 在后台计算（最多 2 个并发），首个拉取请求会等待其完成。
- `dropdrawer_p2p_unregister_file(item_id)`
- `dropdrawer_p2p_authorize_token(req_json)`：可选字段 `requester_node_id` 将 token 绑定到请求方节点；每次登记时顺带清理过期 token。
- `dropdrawer_p2p_download_file(req_json)` → 返回 `transfer_id`
- `dropdrawer_p2p_cancel_transfer(transfer_id)`
- `dropdrawer_p2p_poll_events()`
- `dropdrawer_p2p_shutdown()`
- `dropdrawer_p2p_free_string(ptr)`

---

## 3. 服务端 API 与外链分享 (`crates/server`)

### 安全约束
- **服务器本地存储沙箱**：用户创建的 `local` 存储一律落在 `DROPDRAWER_LOCAL_STORAGE/<user_id>`，忽略客户端提交的 `root_dir`；使用时还会校验根目录位于存储区内，且对象 key 必须以 `<user_id>/` 开头。
- **对象 key 由服务端生成**：`confirm-upload` 只接受与上传计划一致的 `remote_key`（`<user_id>/<item_id>_<name>`），且不适用于 `local` 存储。
- **注册开关**：`DROPDRAWER_ALLOW_REGISTRATION=false` 关闭新用户注册（默认开启）。
- **JWT 密钥**：未设置或使用旧占位值时自动生成随机密钥并以 `0600` 权限保存到数据库同目录的 `jwt_secret`。
- **暴力破解限流**：同一用户名 15 分钟内登录失败 10 次、同一分享码 15 分钟内提取码错误 10 次后返回 `429`，Argon2 校验在 `spawn_blocking` 中执行。
- **CORS 与优雅停机**：服务端默认允许跨域（可通过 `DROPDRAWER_CORS_ORIGINS` 逗号分隔收紧），收到 `SIGINT`/`SIGTERM` 时通过 `with_graceful_shutdown` 排空在途请求；SQLite 启用 WAL、`synchronous = NORMAL` 与 `busy_timeout = 5000`。
- **WebSocket 鉴权**：客户端通过 `Authorization: Bearer` 头传 JWT；`?token=` 查询参数仅为兼容旧客户端保留。

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

### 管理控制台 (`/admin`)
- **启用与登录**：设置 `DROPDRAWER_ADMIN_TOKEN`（推荐 Argon2 PHC 哈希，也接受明文）后访问 `/admin`；未设置时 `/admin` 与 `/api/admin/*` 一律 `404`。可以用这个密钥登录（拥有超级管理员权限，作为应急入口），也可以用超级管理员创建的**管理员账号**登录（`admin_accounts` 表，密码至少 10 位，可开启 RFC 6238 **TOTP 两步验证**，验证码一次性使用）。会话为 12 小时 JWT（`HttpOnly`、`SameSite=Strict` cookie）：账号会话随 `token_version` 失效（退出、改密、停用、改角色），密钥会话在退出或服务重启时全部失效。同一 IP 15 分钟内失败 8 次锁定，全站另有 60 次上限。
- **角色**：`super`（全部权限，含管理员账号与数据库备份）、`admin`（设置与用户治理）、`viewer`（只读：所有非 GET 请求被拒，`/api/admin/me/*` 与退出除外）。
- **代码结构**：`src/admin/`（`auth` 认证/角色/限流、`accounts` 管理员账号/个人设置/备份、`totp`、`assets` 页面与 CSP、`dashboard` 概览/系统/版本分布/审计/维护、`settings` 运行时设置、`users` 用户及其设备/存储/条目、`invites`、`shares`），页面在 `src/admin/ui/`（`index.html` + `admin.css` + `admin.js`，编译进二进制）。页面只用 DOM API 渲染、不使用 `innerHTML`，并带 `script-src 'self'` 的 CSP，不要加内联脚本或样式。
- **运行时设置**：保存在 SQLite `system_settings`，首次保存后覆盖对应环境变量的默认值，热生效并通过 WebSocket `config_changed` 通知在线客户端。除注册/登录/SMTP 外还包括 `features`（Google 自动建号、邮箱找回密码、云端中转上传、创建外链、外链访问）、`share_policy`（强制提取码、最长有效期、最大下载次数）、`storage_policy`（停用的存储类型、拦截内网地址）、`limits`（设备数、条目数、条目默认/最长保留时长）、`announcement`（全站公告）与 `client_policy.min_version`（最低客户端版本）。所有开关默认开启、限额默认不限，与引入前的行为一致。
- **客户端配置**：`GET /api/client/config`（需登录）返回该用户生效的开关（全局开关与个人限制合并）、公告与最低版本，Flutter 与 iOS 客户端据此隐藏外链/云端上传入口与已停用的存储类型、把外链有效期与下载次数选项限制在上限内、在要求时把提取码标为必填，并显示公告横幅；旧服务器没有该接口时客户端按全部开启处理。设备登记时上报 `app_version`，低于最低版本（或未上报）返回 `426`。
- **策略执行**：统一在 `src/policy.rs`，用户侧路由只调用其中的检查函数。每个用户还可单独设置本地配额、禁止上传、禁止外链（`users` 表的 `local_quota_bytes` / `upload_blocked` / `share_blocked`）；本地配额以管理员上限为准，用户自己在存储上设置的值只能更小。「拦截内网地址」除了在创建与使用存储时检查 URL，还由 `src/net_guard.rs` 在共享 HTTP 客户端的 DNS 解析和重定向环节过滤内网地址，防止 DNS rebinding 与重定向绕过。
- **会话吊销与设备移除**：用户 JWT 带 `ver`（需与 `users.token_version` 一致）与 `iat`；强制下线、管理员重置密码、邮箱找回密码都会递增版本并断开 WebSocket。管理员移除设备会记入 `removed_devices`，移除之前签发的会话不能再以相同设备 ID 或 iroh 节点重新登记，用户重新登录后即可。客户端在 WebSocket 断开时会带 `device_id` 请求 `/api/client/config`，收到 `401`（会话被吊销或设备被移除）即回到登录页，无需重启。旧版本签发的 token 没有 `ver`/`iat`（分别视为 0 和 `exp - 30 天`）。
- **审计与备份**：`admin_audit_log` 记录管理员登录（含失败）、设置变更（只记录变更的分区名，不记录密钥）与所有治理操作及操作者，保留最近 5000 条。超级管理员可下载 `VACUUM INTO` 生成的数据库快照（含账号与存储凭据，不含文件本体）。

---

## 4. 桌面原生层 (`com.dropdrawer/drawer_window`)

Dart 侧通过 [drawer_window_service.dart](../app/lib/services/drawer_window_service.dart) 统一与 macOS / Windows 原生窗口通信。

### 4.1 macOS (`app/macos/Runner/`)
- **窗口管理 (`MainFlutterWindow.swift`)**：无标题栏毛玻璃贴边悬浮窗，支持 `collapsed` / `drag_pill` / `expanded` 三态（切换时先隐藏，等 Dart 回传 `drawerFrameReady` 再以等比缩放 + 临界阻尼弹簧显示，Windows 同理），折叠手柄与展开态顶部拖条均可拖拽调整垂直位置及跨屏左右停靠（持久化到 `UserDefaults`）。
- **菜单与状态栏 (`AppDelegate.swift`)**：原生 `NSMenu`（含 SF Symbols），状态栏左键菜单常驻，支持可选 Dock 图标与 `⌘Q` 退出。
- **全局快捷键**：基于 `CGEvent.tapCreate`（辅助功能）+ `NSEvent.addGlobalMonitorForEvents`（输入监控）+ 本地监听，支持实时录制与权限状态检测。
- **文件与媒体**：原生 `ImageIO` 缩略图生成、剪贴板读写（文件/截图/文本）、`/usr/bin/ditto` 文件夹无损 ZIP 打包。
- **签名与打包**：`scripts/build_macos_release.sh` 固定 `arm64` Release，预编译 `super_native_extensions`（`LTO=false`、`panic=unwind`），嵌入 `libdropdrawer_p2p.dylib` 并使用 Apple Development 证书签名（保证重新打包后 macOS 辅助功能 TCC 权限不失效）。

### 4.2 Windows (`app/windows/runner/` + `deploy/windows/`)
- **窗口与托盘 (`drawer_window.cpp`)**：单实例互斥锁 `Local\DropDrawer`、系统托盘图标与右键菜单、`WS_POPUP` 贴边抽屉、Windows 11 用 `DWMWA_WINDOW_CORNER_PREFERENCE` 系统圆角（Windows 10 回退 `CreateRoundRectRgn` 按 DPI 缩放裁剪，响应 `WM_DPICHANGED` 与 `WM_DISPLAYCHANGE`）、折叠手柄与展开态顶部拖条支持上下滑动与跨屏左右停靠。
- **毛玻璃背景**：Windows 11 22H2+ 上常规窗口用 Mica、边缘抽屉用 Acrylic（`DWMWA_SYSTEMBACKDROP_TYPE` + `DwmExtendFrameIntoClientArea`），原生回报 `backdrop` 后 Flutter 才改用半透明底色；偏好设置可关闭。
- **拖拽唤出与防误触**：通过 `IsExternalOleDragActive()`（检测其他进程的 `CLIPBRDWNDCLASS` OLE 拖放捕获，纯框选文字不会触发）在拖动文件或选中文字时**立即**弹出边缘引导条，靠近引导条后自动展开抽屉，松手即收起（与 macOS 体验一致）；`OnTimer`、`WM_ACTIVATE`、`kOutsideClickMessage` 均带 `!IsOleDragActive()` 守卫，防止从抽屉拖出文件时中途收起。
- **剪贴板与文件 (`drawer_files.cpp`)**：`CF_HDROP` + `Preferred DropEffect` 多文件复制（跳过失效路径）、WIC 截图保存（由启动阶段 `pruneClipboardFiles` 排除抽屉保留路径后清理超 24h 旧缓存）、`SHOpenFolderAndSelectItems` 定位文件、PowerShell `.NET ZipFile`（UTF-8 编码，回退绝对路径 `%SystemRoot%\System32\tar.exe`）打包文件夹。
- **安装、升级与卸载 (`DropDrawer.iss`)**：
  - 处理 `WM_QUERYENDSESSION` / `WM_ENDSESSION` 及自定义退出消息 `kQuitMessage (WM_APP + 2 = 0x8002)`。
  - 安装器在 `PrepareToInstall` 与卸载 `usUninstall` 中主动向 `FLUTTER_RUNNER_WIN32_WINDOW` / `DropDrawer` 发送 `$8002` 并等待互斥体释放，彻底解决托盘驻留态覆盖升级/卸载文件占用问题；卸载后清理 `HKCU\...\Run\DropDrawer` 与 `HKCU\Software\DropDrawer`。

---

## 5. 移动端原生层 (`com.dropdrawer/mobile`)

界面层面：手机端跟随系统浅色/深色模式（`MacPalette.use`），按钮、标题栏、分段控件等使用触控尺寸（`UiDensity`）；Android 上开关、确认对话框、加载指示和点击水波纹使用 Material 风格，系统返回键会先退出二级页面、多选和搜索。

Dart 侧通过 [drawer_window_service.dart](../app/lib/services/drawer_window_service.dart) 在 iOS / Android 上接入 `com.dropdrawer/mobile` MethodChannel：

- **Android (`app/android/`)**：
  - `AndroidManifest.xml` 注册 `ACTION_SEND` / `ACTION_SEND_MULTIPLE` Intent 接收其他 App 分享的文件、图片、视频与文本，并配置 `FileProvider`（`res/xml/file_paths.xml`）和网络/局域网组播权限。
  - `MainActivity.kt` 实现 `consumePendingShares` / `onSharedPayload`、`shareFiles` / `shareText`、`saveToGallery`（Android 10+ `MediaStore` 零存储权限写入 `Pictures/DropDrawer` 或 `Movies/DropDrawer`）、`openExternalUrl`（支持 Google Drive OAuth）与 `readClipboard`（支持图片 URI 与文本）。
  - `.github/workflows/android-apk.yml` 使用 `cargo-ndk` 编译 `arm64-v8a` & `armeabi-v7a` 的 `libdropdrawer_p2p.so` 打包进 APK。
- **原生 Swift iOS (`apple/`)**：
  - `apple/DropDrawerCore`：Swift Package，封装 REST 流式上传/分块下载（带真实底层取消与原子替换）、WebSocket 指数退避重连、Keychain + App Group (`group.com.dropdrawer.shared`) 持久化与同步会话恢复（冷启动无登录页闪烁），以及 `DropDrawerP2P.xcframework`（`scripts/build_apple_p2p.sh`）C-ABI 桥接。
  - `apple/DropDrawerIOS` & `apple/DropDrawerShareExtension`：由 `apple/project.yml`（XcodeGen）生成，支持系统 QuickLook、相册 `FileRepresentation` 零全量内存导入、`CGImageSource` 异步降采样缩略图缓存、发送进度/取消与本地缓存清理。
- **旧版 Flutter iOS 兼容层 (`app/ios/`)**：保留 `DropDrawerMobileBridge` 与 `scripts/build_ios_p2p.sh` 作为兼容参考。
