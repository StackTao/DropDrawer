#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

INSTALL_TO_APPS=false
for arg in "$@"; do
  if [[ "$arg" == "--install" ]]; then
    INSTALL_TO_APPS=true
  fi
done

echo "[1/5] Building native Rust P2P engine (release)..."
cargo build --release -p p2p-core --offline
DYLIB="$ROOT_DIR/target/release/libdropdrawer_p2p.dylib"

echo "[2/5] Building Flutter macOS Release app..."
SNE_MANIFEST="$(ls -d "$HOME/.pub-cache/hosted/pub.dev"/super_native_extensions-*/rust/Cargo.toml 2>/dev/null | head -n 1 || true)"
SNE_TARGET_DIR="$ROOT_DIR/app/build/macos/Build/Intermediates.noindex/Pods.build/Release/super_native_extensions.build"
if [[ -n "$SNE_MANIFEST" ]]; then
  echo "  Pre-building super_native_extensions (arm64 release)..."
  CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_PANIC=unwind \
    cargo build --manifest-path "$SNE_MANIFEST" -p super_native_extensions --release \
    --target aarch64-apple-darwin --target-dir "$SNE_TARGET_DIR"
fi
(cd "$ROOT_DIR/app" && flutter analyze && CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_PANIC=unwind flutter build macos --release)

RAW_APP="$ROOT_DIR/app/build/macos/Build/Products/Release/dropdrawer_app.app"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg_staging"
APP_BUNDLE="$DIST_DIR/DropDrawer.app"
DMG_PATH="$DIST_DIR/DropDrawer-macOS.dmg"

echo "[3/5] Preparing DropDrawer.app and embedding libdropdrawer_p2p.dylib..."
rm -rf "$APP_BUNDLE" "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$DIST_DIR"
cp -R "$RAW_APP" "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp "$DYLIB" "$APP_BUNDLE/Contents/Frameworks/libdropdrawer_p2p.dylib"

echo "[4/5] Signing DropDrawer.app..."
SIGN_ID="${DROPDRAWER_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/{print $2; exit}')"
fi

if [[ -n "$SIGN_ID" ]]; then
  echo "  Using certificate: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/libdropdrawer_p2p.dylib"
  codesign --force --deep --sign "$SIGN_ID" \
    --entitlements "$ROOT_DIR/app/macos/Runner/Release.entitlements" \
    "$APP_BUNDLE"
else
  echo "  No signing certificate found; using ad-hoc signature"
  codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/app/macos/Runner/Release.entitlements" \
    "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

echo "[5/5] Creating distributable DMG: $DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/DropDrawer.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "DropDrawer" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING_DIR"

echo "Built Release app: $APP_BUNDLE"
echo "Built DMG installer: $DMG_PATH"

if [[ "$INSTALL_TO_APPS" == true ]]; then
  echo "Installing to /Applications/DropDrawer.app..."
  pkill -x dropdrawer_app || true
  sleep 0.4
  rm -rf "/Applications/DropDrawer.app"
  cp -R "$APP_BUNDLE" "/Applications/DropDrawer.app"
  echo "Installed! Launching /Applications/DropDrawer.app..."
  open "/Applications/DropDrawer.app"
fi
