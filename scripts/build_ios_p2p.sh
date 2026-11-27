#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/4] Ensuring iOS Rust targets are installed..."
rustup target add aarch64-apple-ios aarch64-apple-ios-sim >/dev/null

echo "[2/4] Building p2p-core staticlib for iOS device (aarch64-apple-ios)..."
IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release -p p2p-core --target aarch64-apple-ios

echo "[3/4] Building p2p-core staticlib for iOS Simulator (aarch64-apple-ios-sim)..."
IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release -p p2p-core --target aarch64-apple-ios-sim

OUT_DIR="$ROOT_DIR/app/ios/DropDrawerP2P/Frameworks"
HEADERS_DIR="$ROOT_DIR/target/ios_p2p_headers"
XCFRAMEWORK="$OUT_DIR/DropDrawerP2P.xcframework"

rm -rf "$HEADERS_DIR" "$XCFRAMEWORK"
mkdir -p "$OUT_DIR" "$HEADERS_DIR"

cat > "$HEADERS_DIR/dropdrawer_p2p.h" <<'EOF'
#ifndef DROPDRAWER_P2P_H
#define DROPDRAWER_P2P_H

#ifdef __cplusplus
extern "C" {
#endif

char *dropdrawer_p2p_start(const char *config_json);
char *dropdrawer_p2p_node_info(void);
char *dropdrawer_p2p_register_file(const char *req_json);
char *dropdrawer_p2p_authorize_token(const char *req_json);
char *dropdrawer_p2p_prepare_browser_share(const char *req_json);
char *dropdrawer_p2p_unregister_file(const char *item_id);
char *dropdrawer_p2p_download_file(const char *req_json);
char *dropdrawer_p2p_cancel_transfer(const char *transfer_id);
char *dropdrawer_p2p_poll_events(void);
char *dropdrawer_p2p_shutdown(void);
void dropdrawer_p2p_free_string(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
EOF

cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module DropDrawerP2P {
    header "dropdrawer_p2p.h"
    export *
}
EOF

echo "[4/4] Packaging DropDrawerP2P.xcframework..."
xcodebuild -create-xcframework \
  -library "$ROOT_DIR/target/aarch64-apple-ios/release/libdropdrawer_p2p.a" \
  -headers "$HEADERS_DIR" \
  -library "$ROOT_DIR/target/aarch64-apple-ios-sim/release/libdropdrawer_p2p.a" \
  -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK"

rm -rf "$HEADERS_DIR"
echo "Done: $XCFRAMEWORK"
