# DropDrawer — 跨端文件暂存抽屉

DropDrawer 是一款跨平台文件传输与暂存助手，采用 **Rust（Axum + SQLite + iroh QUIC P2P）+ Flutter（macOS / Windows 原生边缘抽屉，移动端规划中）** 架构。

核心理念：**像系统抽屉一样贴在屏幕边缘，拖入即跨端可见；同网/直连优先走 P2P 不耗服务器流量，离线或大场景无缝衔接多云盘中转与公网外链分享。**

---

## 功能现状（v1.0）

| 模块 | 状态 | 核心能力 |
|---|---|---|
| **服务端 (`crates/server`)** | 已上线 | 账号注册/登录（JWT）、设备在线状态与 WebSocket 实时同步、智能下载路由（P2P 优先 + 云端回退）、TTL 过期自动清理、单文件/多选打包公网外链分享（`/s/{code}`，支持提取码、有效期、次数上限与撤销） |
| **原生多云盘中转（零 Sidecar）** | 已完成 | 内置原生适配器，无需任何第三方 sidecar：Google Drive（内置 OAuth2）、夸克网盘、百度网盘、S3 / Cloudflare R2（Presigned URL 直传直下）、WebDAV、服务器本地磁盘 |
| **P2P 内核 (`crates/p2p-core`)** | 已完成 | 基于 `iroh` QUIC（局域网直连 → 公网打洞 → 加密中继）、实时传输路径显示、中继自动打洞重试（`RelayProbe`）、断点续传（`.dropdrawer.part` + `PartialLease`）、BLAKE3 完整性校验、送达回执确认、收发双向独立取消 |
| **macOS 桌面端** | 第一版完成 | 贴边悬浮抽屉与常规窗口切换、折叠手柄与展开态抽屉均可拖拽停靠（左右切边/跨屏）、拖入文件自动弹出引导条、卡片直接拖出到其他应用、原生 `NSMenu`、状态栏常驻、`CGEventTap` 全局快捷键与录制、图片缩略图与抽屉内快捷预览、剪贴板智能粘贴（文件/截图/文本）与复制文件、搜索筛选、开机自启、Apple Development 签名与 DMG 打包 |
| **Windows 桌面端** | 第一版完成 | Win32 原生边缘抽屉与常规窗口切换、折叠手柄与展开态拖拽移动/跨屏切边、资源管理器/桌面文件拖动自动弹引导条、单实例互斥与系统托盘常驻、全局热键与录制、剪贴板文件/截图/文本读写、文件夹 UTF-8 ZIP 打包、Inno Setup 静默安装/托盘态自动覆盖升级/卸载清理、GitHub Actions 自动构建与端到端烟测 |
| **移动端（iOS / Android）** | 规划中 | 当前为 Flutter 初始骨架（已更新应用图标），待补移动端触控 UI、系统分享入口（iOS Share Extension / Android Intent）、原生 P2P 交叉编译与相册/系统分享闭环 |

---

## 目录结构

```text
├── crates/
│   ├── protocol/               # 服务端、P2P 与客户端共享协议类型
│   ├── p2p-core/               # iroh QUIC P2P 核心 (rlib + C-ABI cdylib/staticlib)
│   │   └── src/
│   │       ├── lib.rs          # P2pNode、断点续传、BLAKE3 校验、送达回执
│   │       ├── ffi.rs          # C-ABI FFI 导出接口
│   │       ├── transfers.rs    # 双向取消与活进度/终态分离事件队列
│   │       └── relay_probe.rs  # 中继连接自动辅助打洞重试
│   ├── p2p-cli/                # P2P 双节点独立命令行调试工具
│   └── server/                 # Axum + SQLite 服务端
│       └── src/
│           ├── routes.rs       # REST API、WebSocket /ws、外链分享页 /s/{code}
│           ├── db.rs           # SQLite Schema 与数据访问
│           ├── auth.rs         # JWT 与密码哈希
│           └── storage/        # 原生多云盘适配器 (google_drive/quark/baidu/s3/webdav/local)
├── app/                        # Flutter 跨端客户端
│   ├── lib/                    # 共享状态管理、API 客户端、P2P FFI 桥与 UI
│   ├── macos/Runner/           # macOS 原生窗口、状态栏、热键、NSMenu、缩略图
│   ├── windows/runner/         # Windows Win32 抽屉窗口、托盘、热键、剪贴板/文件操作
│   ├── ios/ & android/         # 移动端工程骨架（待完善）
│   └── test/                   # Flutter 单元测试与传输/拖拽回归测试
├── deploy/
│   ├── Dockerfile              # 服务端多阶段构建镜像（非 root 运行）
│   ├── docker-compose.yml      # 本地/通用 Docker 部署模板
│   ├── compose.baota.yml       # 生产环境（宝塔 + Nginx 反代）Docker Compose
│   └── windows/DropDrawer.iss  # Windows Inno Setup 安装包脚本
├── scripts/
│   ├── build_macos_p2p.sh      # 编译 macOS 本地调试用 libdropdrawer_p2p.dylib
│   └── build_macos_release.sh  # 一键编译、签名、打 DMG 并可选安装 macOS Release
├── .github/workflows/
│   └── windows-installer.yml   # Windows Release 构建、单测、Inno Setup 打包与升级/卸载烟测
├── docs/ARCHITECTURE.md        # 详细架构、协议、原生桥与部署说明
└── AGENTS.md                   # AI 编程智能体协作与工程约束手册
```

---

## 快速开发与构建

### 1. 启动服务端（本地开发）

```bash
cargo run --bin dropdrawer-server
# 默认监听 http://0.0.0.0:8080，数据保存在 ./data
```

或使用 Docker Compose：

```bash
cd deploy
DROPDRAWER_JWT_SECRET="replace-with-a-long-random-secret" docker compose up -d --build
```

### 2. 运行与打包 macOS 客户端

```bash
# 本地开发运行
./scripts/build_macos_p2p.sh
cd app && flutter run -d macos

# 构建正式签名版并生成 dist/DropDrawer-macOS.dmg（加 --install 自动装入 /Applications）
./scripts/build_macos_release.sh --install
```

### 3. 构建 Windows 客户端与安装包

在 GitHub Actions 中手动触发 [windows-installer.yml](.github/workflows/windows-installer.yml) 即可在 `windows-2025` runner 上自动完成：
1. `flutter pub get --enforce-lockfile` + `flutter test` + `flutter build windows --release`
2. `cargo build --locked --release -p p2p-core` + `cargo test --locked --release -p p2p-core`
3. 打包 MSVC CRT + `dropdrawer_p2p.dll` 生成 `dist/DropDrawer-Windows-x64-Setup.exe`
4. 端到端烟测：托盘驻留态静默覆盖升级 → 验证 DLL 导出与单实例 → 托盘驻留态静默卸载并验证自启清理

### 4. 运行全量自动化测试

```bash
# Rust 服务端集成测试 + P2P 单元测试
cargo test --workspace

# Flutter 静态分析与单元测试
cd app && flutter analyze && flutter test
```

### 5. 命令行独立测试 P2P 直传

```bash
# 做种端
cargo run --bin dropdrawer-p2p-cli -- seed ./sample.zip

# 拉取端（粘贴做种端输出的 Ticket JSON）
cargo run --bin dropdrawer-p2p-cli -- pull '<TICKET_JSON>' ./received.zip
```

---

## 生产部署要点

服务端使用 [deploy/compose.baota.yml](deploy/compose.baota.yml) 监听本机回环端口（默认 `127.0.0.1:18088:8080`），前置于 Nginx HTTPS 反向代理。Nginx 反代需确保：
- 支持 `/ws` 的 `Upgrade` / `Connection` WebSocket 升级头；
- 关闭缓冲（`proxy_request_buffering off;`、`proxy_buffering off;`）并放宽 `client_max_body_size`（如 `2g`）以支持大文件流式传输；
- 保留 `/.well-known/acme-challenge/` 以确保 Let's Encrypt 证书自动续签。

更多架构细节、通信协议与移动端路线图见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。
