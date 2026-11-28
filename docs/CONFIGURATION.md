# 服务端环境变量

直接运行服务端时，进程环境变量优先于工作目录下的 `.env`。设置 `DROPDRAWER_ENV_FILE` 可指定其他文件。[配置示例](../.env.example)可作为起点。生产 Compose 通过 `env_file` 读取共享配置文件，并为容器设置监听地址和数据目录。[生产 Compose 模板](../deploy/compose.baota.yml)

## 服务、存储与代理

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DROPDRAWER_ENV_FILE` | `.env` | 服务端读取的配置文件路径。 |
| `DROPDRAWER_BIND` | `0.0.0.0:8080` | 服务端监听地址。 |
| `DROPDRAWER_DB_PATH` | `./data/dropdrawer.db` | SQLite 数据库文件。 |
| `DROPDRAWER_LOCAL_STORAGE` | `./data/blobs` | 服务端本地盘目录。 |
| `DROPDRAWER_LOCAL_MAX_FILE_BYTES` | 空 | 本地盘单文件上限，单位为字节。空表示未配置上限，`10485760` 表示 10 MiB。 |
| `DROPDRAWER_LOCAL_USER_QUOTA_BYTES` | 空 | 默认每用户本地盘配额，单位为字节。空表示未配置默认配额。可在控制台设置用户上限。 |
| `DROPDRAWER_TTL_CLEANUP_SECS` | `300` | 过期条目、云端缓存和临时 Drive 授权会话的清理间隔，单位为秒，最小为 10。 |
| `DROPDRAWER_CORS_ORIGINS` | 空 | 允许的 API 来源，以逗号分隔。空或 `*` 允许任意来源。管理端 API 仅供同源页面使用。 |
| `DROPDRAWER_TRUST_PROXY` | `false` | 设为 `true` 后，服务端才使用来自私有网络对端的 `X-Forwarded-For` 或 `X-Real-IP` 识别请求来源。只在后端端口仅对可信反向代理开放时开启。`X-Forwarded-For` 只取最后一项（即代理自己追加的地址），前面的项可由客户端伪造，一律忽略；没有该请求头时才读 `X-Real-IP`。代理前面还有 CDN 时，要在代理上把 CDN 传来的真实 IP 还原出来（例如 nginx `real_ip_header`），否则限流会按 CDN 节点的 IP 计算。 |
| `RUST_LOG` | `info` | 日志级别和过滤条件。 |

客户端选择「跟随服务器」时，服务端采用控制台配置的默认保留期，并遵守最长保留期。未配置默认值时采用 7 天。

## 登录与管理控制台

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DROPDRAWER_JWT_SECRET` | 自动生成并持久化 | 签发会话的随机密钥。自定义值至少 32 字符，空值使用数据库同目录的 `jwt_secret`。 |
| `DROPDRAWER_SECRET_KEY` | 自动生成并持久化 | 加密数据库里的网盘凭据、控制台保存的 SMTP / OAuth / Turnstile 密钥和管理员两步验证密钥。值为 32 字节（64 位十六进制或 base64，可用 `openssl rand -hex 32` 生成）。空值使用数据库同目录的 `secret_key` 文件。**密钥丢失后这些凭据无法恢复**：备份数据库时要一起备份这个文件（或环境变量），设置后不要更改。 |
| `DROPDRAWER_ADMIN_ENABLED` | `false` | 设为 `true` 启用 `/admin`。旧配置中的 `DROPDRAWER_ADMIN_TOKEN` 仅在未显式配置此开关时作为启用兼容标志，密钥登录已移除。 |
| `DROPDRAWER_ALLOW_REGISTRATION` | `true` | 新部署默认允许注册。设为 `false` 可关闭。 |
| `DROPDRAWER_GOOGLE_CLIENT_ID` | 空 | 用于 Google 账号登录的 OAuth Web 客户端 ID。 |
| `DROPDRAWER_GOOGLE_CLIENT_SECRET` | 空 | 上述 OAuth Web 客户端的密钥。 |
| `DROPDRAWER_GOOGLE_REDIRECT_URI` | 空 | 上述客户端注册的完整回调地址，路径为 `/api/auth/google/callback`。 |

### 管理员账号与恢复

使用服务器本机命令创建第一个超级管理员。密码通过标准输入读取：

```bash
IFS= read -r -s admin_password
printf '%s\n' "$admin_password" | dropdrawer-server admin-account 'admin@example.com'
unset admin_password
```

使用相同的服务端环境与数据库路径。Docker 部署可将命令替换为
`docker compose -f deploy/docker-compose.yml run --rm --no-deps -T dropdrawer-server dropdrawer-server admin-account 'admin@example.com'`。
如果账号已存在，命令会更新密码并吊销该账号的旧会话。原角色与两步验证设置继续有效。

### 回滚到凭据加密之前的版本

停止应用写入并备份当前数据库、原密钥和环境配置。使用支持加密的服务端生成旧版数据库。

```bash
dropdrawer-server db-export-for-downgrade /private-data/dropdrawer-legacy.db
```

命令沿用 `DROPDRAWER_DB_PATH` 和原密钥，把当前数据导出到一个旧版可读的新 SQLite 文件。目标目录应只对部署管理员和服务账号开放。导出文件以 `0600` 权限创建，包含明文凭据。将旧版服务指向这份新文件后，验证管理端登录及网盘访问，并保留当前加密库及密钥用于恢复。如需保留已登录会话，旧版服务也要继续使用原 JWT 密钥。使用 Docker 时，在停止写入后用原镜像和原数据卷执行导出命令。

### Google 登录与 Turnstile

超级管理员在 `/admin` 的登录设置中维护同一组 Google OAuth Web Client ID、密钥和回调地址。客户端和管理端可分别开启 Google 登录。两者复用 `/api/auth/google/callback`，Google Cloud Console 中的原回调地址继续有效。

管理端只允许已有管理员使用与用户名相同的已验证 Gmail 或 Google Workspace 邮箱登录，首次成功匹配后绑定 Google 账号的唯一标识。账号密码可继续使用，开启了两步验证的管理员仍要输入验证码。

超级管理员可在管理端设置 Turnstile 站点密钥、服务端密钥和允许的主机名。验证覆盖管理端的密码和 Google 登录入口。Cloudflare 不可用或配置有误时，可以在服务器本机运行 `dropdrawer-server admin-disable-turnstile` 后重启服务恢复登录。Docker 部署使用与上文相同的 `docker compose run` 方式执行该命令。

兼容旧部署的 Google 环境变量仅作为首次配置的默认值。确认配置已保存到管理台后，可以移除这些环境变量。Google Drive 存储授权由用户在客户端单独配置。管理台保存的运行时设置存放在 SQLite。[管理端架构](ARCHITECTURE.md#管理控制台-admin)

## SMTP

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DROPDRAWER_SMTP_HOST` | 空 | SMTP 服务器。空值停用环境变量配置的邮件发送。 |
| `DROPDRAWER_SMTP_PORT` | `587` | SMTP 服务端口。 |
| `DROPDRAWER_SMTP_SECURITY` | `start_tls` | 传输方式。支持 `start_tls`、`tls` 和 `none`。 |
| `DROPDRAWER_SMTP_USERNAME` | 空 | SMTP 用户名。 |
| `DROPDRAWER_SMTP_PASSWORD` | 空 | SMTP 密码或应用专用密码。 |
| `DROPDRAWER_SMTP_FROM` | SMTP 用户名 | 发件人邮箱。用户名并非邮箱时需要显式填写。 |
| `DROPDRAWER_SMTP_FROM_NAME` | `DropDrawer` | 发件人显示名称。 |

## 推送通知

配置推送后，有设备往抽屉里放入内容时，服务端会给同一账号下**处于后台或离线**的其他设备发通知（放入内容的那台不发）。退到后台时，进行中的传输可以继续使用实时连接。通知只包含来源设备名和文件名；文字内容只显示「一段文字」，不经过苹果或谷歌的服务器。两种推送都是可选的，没有配置时客户端不会申请通知权限。

改密码、管理员强制下线或停用账号时，被下线设备的推送令牌会一并删除；客户端退出登录时也会注销自己的令牌。

### iOS（APNs）

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DROPDRAWER_APNS_KEY_PATH` | 空 | Apple Developer →「Certificates, Identifiers & Profiles」→ Keys 里创建的 APNs 密钥文件（`AuthKey_XXXXXXXXXX.p8`）。也可以用 `DROPDRAWER_APNS_KEY` 直接填文件内容（换行写成 `\n`）。 |
| `DROPDRAWER_APNS_KEY_ID` | 空 | 该密钥的 Key ID（10 位）。 |
| `DROPDRAWER_APNS_TEAM_ID` | 空 | 开发者账号的 Team ID。 |
| `DROPDRAWER_APNS_TOPIC` | `com.dropdrawer.ios` | iOS App 的 Bundle ID，用自己的 Bundle ID 重新打包时要改。 |

App 需要在 Apple Developer 里给该 App ID 开启 Push Notifications 能力。App 根据签名描述文件里的 `aps-environment` 选择环境。开发签名的 Release 包也使用沙盒，TestFlight 和 App Store 使用正式环境。App 注册令牌时会把环境告诉服务端。

### Android（FCM）

Android App 不内置 Firebase 项目，而是使用服务端下发的 Firebase 配置，所以每个部署可以用自己的 Firebase 项目：

1. 在 [Firebase 控制台](https://console.firebase.google.com/) 新建项目，添加 Android 应用，包名填 `com.dropdrawer.dropdrawer_app`（不需要下载 `google-services.json`）。
2. 在「项目设置 → 常规」里找到该 Android 应用的 **App ID**（`1:...:android:...`）和 **Web API Key**，在「Cloud Messaging」里找到 **发送者 ID**。
3. 在「项目设置 → 服务账号」里生成新的私钥，得到服务账号 JSON 文件。

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DROPDRAWER_FCM_SERVICE_ACCOUNT_PATH` | 空 | 服务账号 JSON 文件路径。也可以用 `DROPDRAWER_FCM_SERVICE_ACCOUNT` 直接填 JSON 内容。 |
| `DROPDRAWER_FCM_APP_ID` | 空 | Android 应用的 Firebase App ID。 |
| `DROPDRAWER_FCM_API_KEY` | 空 | Web API Key。 |
| `DROPDRAWER_FCM_SENDER_ID` | 空 | 发送者 ID（项目编号）。 |

只配置了一部分变量时服务端拒绝启动，避免拼写错误导致推送悄悄失效。Docker 部署把密钥文件放进数据目录，路径写成 `/data/<文件名>`。没有 Google Play 服务的手机收不到推送，仍可在打开 App 后正常同步。
