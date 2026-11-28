# Security Policy

[中文](#安全策略)

## Supported versions

Security fixes go into the latest release only. Update the server and every client to the newest [release](https://github.com/StackTao/DropDrawer/releases) before reporting a problem.

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** ([direct link](https://github.com/StackTao/DropDrawer/security/advisories/new)).

Include, if you can:

- the affected component (server, P2P core, macOS / Windows / Android / iOS client, admin console, share page) and version;
- how the problem can be reproduced, and what an attacker gains;
- whether it needs a signed-in account, an administrator, the same network, or nothing at all.

You will get an answer in the advisory thread. Please keep the details private until a fixed release is out.

## Scope notes

- The server is meant to be self-hosted. When registration is open to people you don't trust, turn on **Block private storage addresses** in the admin console (see [docs/CONFIGURATION.md](docs/CONFIGURATION.md)).
- Never include real passwords, tokens, cookies or keys in a report; use test accounts.

---

# 安全策略

## 支持的版本

安全修复只进入最新版本。报告问题前，请先把服务端和各客户端更新到最新的 [Release](https://github.com/StackTao/DropDrawer/releases)。

## 报告漏洞

请不要为安全问题开公开 Issue。请通过 GitHub 私下报告：打开仓库的 **Security** 标签页，选择 **Report a vulnerability**（[直接链接](https://github.com/StackTao/DropDrawer/security/advisories/new)）。

请尽量说明：

- 受影响的组件（服务端、P2P 核心、macOS / Windows / Android / iOS 客户端、管理控制台、外链页面）和版本；
- 复现步骤，以及攻击者能得到什么；
- 是否需要已登录账号、管理员权限、同一网络，或者什么都不需要。

我们会在该安全公告的讨论里回复。修复版本发布前，请不要公开细节。

## 范围说明

- 服务端面向自托管。对不受信任的人开放注册时，请在管理控制台打开「拦截内网存储地址」（见 [docs/CONFIGURATION.md](docs/CONFIGURATION.md)）。
- 报告中不要包含真实的密码、令牌、Cookie 或密钥，请使用测试账号。
