<p align="center">
  <img src="app/assets/dropdrawer-icon.png" alt="DropDrawer app icon" width="112" />
</p>

<h1 align="center">DropDrawer</h1>

<p align="center"><strong>Drop files into a drawer at the edge of your screen and pick them up on another device.</strong></p>

<p align="center">
  English |
  <a href="README.zh-CN.md">简体中文</a> |
  <a href="README.zh-TW.md">繁體中文</a> |
  <a href="README.ja.md">日本語</a> |
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://github.com/StackTao/DropDrawer/releases"><img src="https://img.shields.io/github/v/release/StackTao/DropDrawer?include_prereleases&amp;display_name=tag&amp;sort=semver" alt="Latest release" /></a>
  <a href="https://github.com/StackTao/DropDrawer/actions/workflows/windows-installer.yml"><img src="https://github.com/StackTao/DropDrawer/actions/workflows/windows-installer.yml/badge.svg?branch=main" alt="Windows build status" /></a>
  <a href="https://github.com/StackTao/DropDrawer/actions/workflows/android-apk.yml"><img src="https://github.com/StackTao/DropDrawer/actions/workflows/android-apk.yml/badge.svg?branch=main" alt="Android build status" /></a>
  <a href="https://github.com/StackTao/DropDrawer/releases"><img src="https://img.shields.io/github/downloads/StackTao/DropDrawer/total" alt="Total release downloads" /></a>
  <a href="https://github.com/StackTao/DropDrawer/stargazers"><img src="https://img.shields.io/github/stars/StackTao/DropDrawer?style=flat&amp;logo=github" alt="GitHub stars" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="#see-dropdrawer-in-action">Demo</a> ·
  <a href="https://github.com/StackTao/DropDrawer/releases">Download</a> ·
  <a href="#install-the-client">Install</a> ·
  <a href="#self-host-the-server">Self-host</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture (Chinese)</a> ·
  <a href="https://github.com/StackTao/DropDrawer/issues">Issues</a> ·
  <a href="LICENSE">MIT License</a>
</p>

DropDrawer is a self-hostable, cross-platform app for transferring and temporarily storing files. The desktop app gives you a drawer at the edge of your screen, and the mobile app can send and receive files, photos, and text. When both devices are online, DropDrawer tries a direct peer-to-peer connection first. Cached files stay available through your configured storage even when the source device is offline. You can also create a download link that works in a browser.

## See DropDrawer in action

**Drag a file in.** Drag a file from Finder toward the screen edge. When the drawer opens, drop it in the highlighted area. With cloud caching enabled, the uploaded file becomes available to your other devices.

![A Finder file is dragged to the screen edge, dropped into the drawer, and uploaded](docs/images/macos-drag-upload.gif)

**Pick it up on another device.** Sign in with the same account and click the download button beside the synced file. The GIF shows the file appearing in the receiving device’s Finder folder.

![The receiving DropDrawer client downloads the synced file and displays it in Finder](docs/images/macos-receive-download.gif)

<details>
<summary>Step-by-step desktop screenshots</summary>

1. The edge hint appears as you drag a file.

   ![The edge hint appears as you drag a file.](docs/images/macos-drag-hint.png)

2. The expanded drawer shows where to drop it.

   ![The expanded drawer shows where to drop it.](docs/images/macos-drop-target.png)

3. The new file appears in the drawer after uploading.

   ![The new file appears in the drawer after uploading.](docs/images/macos-upload-complete.png)

4. The downloaded file appears in the receiving folder.

   ![The downloaded file appears in the receiving folder.](docs/images/macos-download-complete.png)

**Expanded desktop drawer**

<p align="center">
  <img src="docs/images/macos-drawer.png" alt="DropDrawer’s expanded macOS edge drawer showing a synced image, PDF, and text snippet" width="368" />
</p>

</details>

### On iPhone

The iPhone drawer offers quick access to files, photos, and the clipboard. Synced items appear below, ready to download or share.

<p align="center">
  <img src="docs/images/ios-drawer.png" alt="DropDrawer on iPhone showing the file, photo, and paste buttons above synced items" width="280" />
</p>

## Features

- **Desktop edge drawer**. On macOS and Windows, drag files in and out of the drawer, move it between displays, open it with a global shortcut, paste from the clipboard, and preview images. You can also switch to a standard window.
- **Mobile transfers**. Pick files or photos, paste content, use the system share sheet, and save images to your photo library on Android and iOS. Import from the Android share menu or use “Open in DropDrawer” on iOS.
- **P2P first**. iroh QUIC tries a direct connection over the local network or the internet, with an encrypted relay when needed. Transfers support resuming, BLAKE3 integrity checks, delivery receipts, and cancellation from either device.
- **Self-hosting and offline access**. The Rust server handles accounts, device presence, and drawer sync. It supports Google Drive, Quark Drive, Baidu Netdisk, S3-compatible storage (including Cloudflare R2), WebDAV, and local server storage.
- **Share links**. Share one file or bundle several files into a single download. Recipients download in their browser. You can set a passcode, an expiration time, and a download limit, and revoke the link at any time.

## Install the client

| Platform | Installer or build option |
| --- | --- |
| macOS (Apple silicon) | Run the [macOS packaging script](scripts/build_macos_release.sh) to create `dist/DropDrawer-macOS.dmg`. Open the DMG and drag DropDrawer to Applications. |
| Windows (x64) | Download the `DropDrawer-Windows-x64` artifact from a successful [Windows installer](https://github.com/StackTao/DropDrawer/actions/workflows/windows-installer.yml) run. Unzip it and run the installer. |
| Android | Download the `DropDrawer-Android-APK` artifact from a successful [Android APK](https://github.com/StackTao/DropDrawer/actions/workflows/android-apk.yml) run. Unzip it and install the appropriate APK. |
| iOS | [Build from source](#build-from-source) on macOS with Flutter and Xcode. Installing on a physical device requires code signing. |

Release builds of DropDrawer check for updates once a day and update with one click; on macOS and Windows the app relaunches as the new version. See the [app update guide](docs/APP_UPDATES.md) for platform details and release packaging.

Windows and Android build artifacts are kept for 30 days. Repository members with the required permissions can run the workflows manually to generate fresh installers.

### Your first transfer

1. Start a [DropDrawer server](#self-host-the-server) that both devices can reach.
2. Enter the same server address on both devices, create an account, and sign in to it on both.
3. Drag a file into the desktop drawer or pick one on mobile. Open the drawer on the other device and download it.

To make a file available while the source device is offline, enable cloud caching and let the file finish uploading to your chosen storage.

## Self-host the server

Run Docker Compose or Cargo from the repository root. Docker Compose stores data in `deploy/data/server` by default. Running the server directly uses `./data`.

```bash
cp -n .env.example .env
docker compose --env-file .env -f deploy/docker-compose.yml up -d --build

curl -fsS http://localhost:8080/health
```

For local development, you can also run `cargo run --bin dropdrawer-server`. On other devices on the same network, enter the server host’s address, such as `http://192.168.1.10:8080`.

If `DROPDRAWER_JWT_SECRET` is not set, the server generates a random secret on first start and keeps it in `jwt_secret` next to the database. You can also set your own long random value. Once every account you need exists, set `DROPDRAWER_ALLOW_REGISTRATION=false` to stop new sign-ups. In production, use an HTTPS reverse proxy that supports WebSocket upgrades. For large transfers, disable proxy buffering and set the upload size limit to suit your deployment. Share link recipients need to be able to reach the server. [Production Compose template](deploy/compose.baota.yml) · [Architecture (Chinese)](docs/ARCHITECTURE.md)

To enable Google sign-in, follow the [Google sign-in setup](docs/GOOGLE_SIGN_IN.md). Use the same Google account on each device to access the same drawer.

## Build from source

Install stable Rust and Flutter. macOS and iOS builds require Xcode. For Windows and Android, you can use the GitHub Actions workflows listed above.

### macOS

```bash
./scripts/build_macos_p2p.sh
(cd app && flutter pub get --enforce-lockfile && flutter run -d macos)
```

Run `./scripts/build_macos_release.sh` to create a DMG, or add `--install` to update DropDrawer in Applications. To use the global shortcut, grant Accessibility and Input Monitoring permissions when prompted.

### iOS

```bash
./scripts/build_ios_p2p.sh
(cd app && flutter pub get --enforce-lockfile && flutter build ios --simulator --no-codesign)
```

To run on a physical device, open `app/ios/Runner.xcworkspace` in Xcode and configure signing.

## Project structure and contributing

| Path | Purpose |
| --- | --- |
| [app](app) | Flutter client and native integrations for macOS, Windows, iOS, and Android |
| [crates/server](crates/server) | Axum, SQLite, WebSocket, storage adapters, and share link downloads |
| [crates/p2p-core](crates/p2p-core) | iroh QUIC transfer engine and native FFI |
| [crates/protocol](crates/protocol) · [crates/p2p-cli](crates/p2p-cli) | Shared protocol and P2P debugging tool |
| [deploy](deploy) · [scripts](scripts) | Container deployment, installers, and platform build scripts |

Report bugs and suggest features in [GitHub Issues](https://github.com/StackTao/DropDrawer/issues). For bug reports, include your platform, version, and reproduction steps. Before submitting code, run the relevant checks from the [engineering guide (Chinese)](AGENTS.md).

```bash
cargo test --workspace
(cd app && flutter analyze && flutter test)
```

To test P2P independently, run `cargo run --bin dropdrawer-p2p-cli -- seed ./sample.zip` to generate a transfer ticket. On the receiving device, run `cargo run --bin dropdrawer-p2p-cli -- pull '<TICKET_JSON>' ./received.zip`.

## Star history

<a href="https://www.star-history.com/?repos=StackTao%2FDropDrawer&amp;type=date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=StackTao/DropDrawer&amp;type=Date&amp;theme=dark" />
    <img src="https://api.star-history.com/svg?repos=StackTao/DropDrawer&amp;type=Date" alt="Star history" />
  </picture>
</a>

## License

DropDrawer is licensed under the [MIT License](LICENSE).
