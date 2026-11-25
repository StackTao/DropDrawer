# DropDrawer app updates

Release builds check the public [GitHub Releases](https://github.com/StackTao/DropDrawer/releases) once a day. When a newer version has a package for the platform, the drawer shows a bar with **更新**. **偏好设置 → 关于与更新** shows the version, turns automatic checks on or off and checks on demand.

| Platform | What **更新** does |
| --- | --- |
| macOS (Apple silicon) | Downloads the DMG, checks its size and SHA-256, and mounts it. If the app inside is signed by the same certificate as the running app, DropDrawer quits, replaces itself and relaunches. Otherwise it offers to open the DMG for a manual install. |
| Windows (x64) | Downloads the installer, checks its size and SHA-256, and runs it with `/SILENT /UPDATE=1`. The installer closes DropDrawer, upgrades it and starts the new version. |
| Android | Downloads the APK, checks its size and SHA-256, and opens the system installer. If the APK is signed with a different key than the installed app, DropDrawer explains that the old version must be uninstalled first. |
| iOS | No in-app updates. App Store and TestFlight deliver updates themselves. |

Only **release builds** take part. A release build embeds its tag with `--dart-define=DROPDRAWER_RELEASE_TAG=vX.Y.Z[-prerelease]`. A build without a tag is a development build: it shows its version and never checks, because `0.1.0` would otherwise rank above every `0.1.0-preview.N` and never be offered one.

## Publishing an update

1. Set `version:` in `app/pubspec.yaml`. Increase the build number (`+N`) for every Android build that should replace an earlier one.
2. Pick the tag: `vX.Y.Z` for a final release or `vX.Y.Z-preview.N` for a preview. `scripts/check_release_tag.sh` rejects a tag that does not match `pubspec.yaml`, and every build path runs it.
3. Build each platform with that tag:

   | Platform | Build | Release asset |
   | --- | --- | --- |
   | macOS | `DROPDRAWER_RELEASE_TAG=v0.2.0 ./scripts/build_macos_release.sh`. A release build must be signed with a certificate (set `DROPDRAWER_SIGN_IDENTITY` if needed); always use the same one, or installed apps cannot update themselves. | `DropDrawer-macOS-arm64.dmg`, or the script's own output name `DropDrawer-macOS.dmg` |
   | Windows | Run the **Windows installer** workflow with `release_tag`. | `DropDrawer-Windows-x64-Setup.exe` |
   | Android | Run the **Android APK** workflow with `release_tag`. It signs with the distribution key from the repository secrets below. | `DropDrawer-Android-arm64.apk` and `DropDrawer-Android-universal.apk` |

4. Create a public, non-draft GitHub release for the tag and attach the assets under exactly these names. GitHub records each asset's SHA-256 digest, which clients check after downloading. Assets without a digest are ignored.

### Android distribution key

Set these repository Actions secrets for tagged Android builds:

- `DROPDRAWER_ANDROID_KEYSTORE_BASE64`: base64-encoded release keystore
- `DROPDRAWER_ANDROID_STORE_PASSWORD`
- `DROPDRAWER_ANDROID_KEY_ALIAS`
- `DROPDRAWER_ANDROID_KEY_PASSWORD`

Keep the keystore backed up and reuse it for every release. Untagged CI builds use the debug key, and Android does not install an update signed with a different key over an existing install. Publish both APKs: an install from the split arm64 APK has a higher version code than the universal APK, so it keeps updating from the arm64 APK.

## Limits

- The SHA-256 digest comes from GitHub, so it detects damaged downloads, not a tampered release. On macOS the code-signature check also rejects a bundle signed by anyone else. The Windows installer is not Authenticode-signed yet, so Windows relies on the digest alone.
- Clients reach `api.github.com` and GitHub's download hosts directly. Where GitHub is slow or blocked, checks fail with a network message and the release page link still works.
