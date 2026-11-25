# DropDrawer app updates

Open **偏好设置 → 软件更新 → 检查更新** to check the public [GitHub Releases](https://github.com/StackTao/DropDrawer/releases) feed. Desktop and Android downloads are size- and SHA-256-checked before DropDrawer opens the system installer. Installation is user-confirmed. iOS opens the matching Apple distribution channel.

## Publishing an update

Keep the numeric release tag and the version in `app/pubspec.yaml` aligned. Increase the build number for each Android and iOS build intended to supersede a previous build. For prereleases, use the same numeric version with a prerelease tag such as `v0.2.0-preview.1`. Embed the exact tag so that preview clients can distinguish newer previews and the final release.

| Platform | Build | GitHub release asset |
| --- | --- | --- |
| macOS (Apple silicon) | Run `DROPDRAWER_RELEASE_TAG=v0.2.0 ./scripts/build_macos_release.sh`. | `DropDrawer-macOS.dmg` or `DropDrawer-macOS-arm64.dmg` |
| Windows (x64) | Run the Windows installer workflow and fill in `release_tag`. | `DropDrawer-Windows-x64-Setup.exe` |
| Android (ARM/ARM64) | Run the Android APK workflow and fill in `release_tag` to build with the distribution key. | `DropDrawer-Android-universal.apk` and `DropDrawer-Android-arm64.apk` |
| iOS/iPadOS | Upload a signed build to App Store Connect. Use `--dart-define=DROPDRAWER_RELEASE_TAG=v0.2.0` when building. | `DropDrawer-iOS-update.json`, once the build is available in App Store or TestFlight |

Attach the individual assets to the matching public GitHub release. GitHub computes each asset's SHA-256 digest. Drafts, incompatible packages and assets without a digest are skipped.

For iOS, include one or both distribution links in the JSON asset. Use the actual links of the published build.

```json
{
  "appStoreUrl": "https://apps.apple.com/app/id1234567890",
  "testFlightUrl": "https://testflight.apple.com/join/ExampleCode"
}
```

App Store installs use the App Store link. TestFlight installs use the TestFlight link. Until a matching link is published, the app shows that the update is unavailable in its distribution channel.

### Android distribution key

Set the following repository Actions secrets for tagged Android builds:

- `DROPDRAWER_ANDROID_KEYSTORE_BASE64` — base64-encoded release keystore
- `DROPDRAWER_ANDROID_STORE_PASSWORD`
- `DROPDRAWER_ANDROID_KEY_ALIAS`
- `DROPDRAWER_ANDROID_KEY_PASSWORD`

Publish both Android APKs so ARM64 clients that were installed from the split APK can keep using its version-code series. Keep the distribution keystore backed up and reuse it across releases. Local distribution builds use the same variables, with `DROPDRAWER_ANDROID_KEYSTORE` pointing to the keystore path. Untagged CI builds continue to use the debug key. An installed debug APK signed with a different key cannot be upgraded in place by a release APK.
