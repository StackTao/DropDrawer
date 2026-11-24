# DropDrawer — 跨端文件传输抽屉

跨平台文件传输助手（macOS / Windows / Linux / Android / iOS），核心特性：
- **同账号实时同步抽屉**：拖入文件或粘贴文本，所有登录同一账号的设备秒级可见。
- **桌面边缘拖拽弹出抽屉**：macOS 端采用原生无焦点置顶悬浮窗，拖动任意文件时屏幕右侧自动滑出抽屉，支持双向拖入与**直接从抽屉拖出到其他应用**。
- **端到端 P2P 优先（不走服务器流量）**：内置基于 **`iroh` (QUIC + NAT 打洞 + BLAKE3 分块校验)** 的共享 Rust 传输核心，自动择优 `局域网直连 → 公网 P2P 打洞 → Relay 加密中继`，零磁盘拷贝外链做种，支持断点续传。
- **可插拔多云盘中转与离线暂存**：解决小硬盘 VPS 痛点，支持自由配置 **服务器本地磁盘**、**OpenList Sidecar（夸克、百度网盘、Google Drive、OneDrive 等几十种云盘，零落盘流式上传 + 302 直链下载）**、**WebDAV** 与 **S3 / R2 / OSS（Presigned URL 客户端直传直下）**，并支持 TTL 过期自动清理。

---

## 目录结构

```text
├── crates/
│   ├── protocol/      # 服务端与五端共享协议模型
│   ├── p2p-core/      # iroh QUIC P2P 传输内核 (Rust rlib + C-ABI cdylib/staticlib)
│   ├── p2p-cli/       # P2P 双节点独立调试 CLI
│   └── server/        # Axum + SQLite 服务端 (账号/WS同步/Local/OpenList/WebDAV/S3/TTL)
├── app/               # Flutter 五端客户端 (macOS 原生边缘抽屉 + super_drag_and_drop)
├── deploy/            # Docker Compose (Server + OpenList Sidecar)
└── scripts/           # 原生库构建脚本
```

---

## 快速启动

### 1. 启动服务端（本地开发）
```bash
cargo run --bin dropdrawer-server
# 默认监听 http://0.0.0.0:8080
```

或使用 Docker Compose 一键拉起 **DropDrawer Server + OpenList Sidecar**（用于挂载夸克、百度、Google Drive 等网盘）：
```bash
cd deploy
docker compose up -d --build
# DropDrawer Server: http://127.0.0.1:8080
# OpenList 管理面板:  http://127.0.0.1:5244
```

### 2. 编译 Rust P2P 原生库并运行 macOS 抽屉客户端
```bash
./scripts/build_macos_p2p.sh
cd app && flutter run -d macos
```

### 3. 命令行测试纯 P2P 端到端直传
```bash
# 终端 A（做种端）
cargo run --bin dropdrawer-p2p-cli -- seed ./some_large_file.zip

# 终端 B（拉取端，粘贴终端 A 输出的 Ticket JSON）
cargo run --bin dropdrawer-p2p-cli -- pull '<TICKET_JSON>' ./received.zip
```

### 4. 运行自动化测试
```bash
cargo test --workspace
```
