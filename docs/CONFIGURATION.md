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
| `DROPDRAWER_TRUST_PROXY` | `false` | 设为 `true` 后，服务端才使用来自私有网络对端的 `X-Forwarded-For` 或 `X-Real-IP` 识别请求来源。只在后端端口仅对可信反向代理开放、且代理覆盖客户端传入的转发头时开启。 |
| `RUST_LOG` | `info` | 日志级别和过滤条件。 |

客户端选择「跟随服务器」时，服务端采用控制台配置的默认保留期，并遵守最长保留期。未配置默认值时采用 7 天。

## 登录与管理控制台

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DROPDRAWER_JWT_SECRET` | 自动生成并持久化 | 签发会话的随机密钥。自定义值至少 32 字符，空值使用数据库同目录的 `jwt_secret`。 |
| `DROPDRAWER_ADMIN_TOKEN` | 空 | 启用 `/admin` 并提供超级管理员登录密钥。推荐 Argon2 PHC 哈希，在 `.env` 中用单引号保留哈希中的 `$`。 |
| `DROPDRAWER_ALLOW_REGISTRATION` | `true` | 新部署默认允许注册。设为 `false` 可关闭。 |
| `DROPDRAWER_GOOGLE_CLIENT_ID` | 空 | 用于 Google 账号登录的 OAuth Web 客户端 ID。 |
| `DROPDRAWER_GOOGLE_CLIENT_SECRET` | 空 | 上述 OAuth Web 客户端的密钥。 |
| `DROPDRAWER_GOOGLE_REDIRECT_URI` | 空 | 上述客户端注册的完整回调地址，路径为 `/api/auth/google/callback`。 |

启用 Google 账号登录需要填齐三项。Google Drive 存储授权由用户在客户端单独配置。管理员在控制台保存运行时设置后，SQLite 中的设置会覆盖对应的环境变量默认值。[管理端架构](ARCHITECTURE.md#管理控制台-admin)

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
