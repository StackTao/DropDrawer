#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SKIP_CARGO=0
SIM_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-cargo) SKIP_CARGO=1 ;;
    --sim-only) SIM_ONLY=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--skip-cargo] [--sim-only]" >&2
      exit 1
      ;;
  esac
done

IOS_DEV_LIB="$ROOT_DIR/target/aarch64-apple-ios/release/libdropdrawer_p2p.a"
IOS_SIM_LIB="$ROOT_DIR/target/aarch64-apple-ios-sim/release/libdropdrawer_p2p.a"
MAC_LIB="$ROOT_DIR/target/aarch64-apple-darwin/release/libdropdrawer_p2p.a"
HOST_MAC_LIB="$ROOT_DIR/target/release/libdropdrawer_p2p.a"

if [[ "$SKIP_CARGO" -eq 0 ]]; then
  echo "[1/4] Ensuring Apple Rust targets are installed..."
  if [[ "$SIM_ONLY" -eq 1 ]]; then
    rustup target add aarch64-apple-ios-sim aarch64-apple-darwin >/dev/null
  else
    rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin >/dev/null
  fi

  if [[ "$SIM_ONLY" -eq 0 ]]; then
    echo "[2/4] Building p2p-core staticlib for iOS device (aarch64-apple-ios)..."
    IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo build --locked --release -p p2p-core --target aarch64-apple-ios
  fi

  echo "[3/4] Building p2p-core staticlib for iOS Simulator & macOS Apple Silicon..."
  IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo build --locked --release -p p2p-core --target aarch64-apple-ios-sim
  MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --locked --release -p p2p-core --target aarch64-apple-darwin
fi

if [[ ! -f "$MAC_LIB" && -f "$HOST_MAC_LIB" ]]; then
  MAC_LIB="$HOST_MAC_LIB"
fi

OUT_DIR="$ROOT_DIR/apple/Frameworks"
HEADERS_DIR="$ROOT_DIR/target/apple_p2p_headers"
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
XCF_ARGS=()
if [[ -f "$IOS_DEV_LIB" && "$SIM_ONLY" -eq 0 ]]; then
  XCF_ARGS+=(-library "$IOS_DEV_LIB" -headers "$HEADERS_DIR")
fi
if [[ -f "$IOS_SIM_LIB" ]]; then
  XCF_ARGS+=(-library "$IOS_SIM_LIB" -headers "$HEADERS_DIR")
fi
if [[ -f "$MAC_LIB" ]]; then
  XCF_ARGS+=(-library "$MAC_LIB" -headers "$HEADERS_DIR")
fi

xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$XCFRAMEWORK"

rm -rf "$HEADERS_DIR"
echo "Done: $XCFRAMEWORK"
