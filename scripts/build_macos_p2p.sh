#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/2] Building libdropdrawer_p2p.dylib (release)..."
cargo build --release -p p2p-core

DYLIB="$ROOT_DIR/target/release/libdropdrawer_p2p.dylib"
DEST_DIR="$ROOT_DIR/app/macos/Runner/Frameworks"
mkdir -p "$DEST_DIR"
cp "$DYLIB" "$DEST_DIR/libdropdrawer_p2p.dylib"

echo "[2/2] Copied native P2P library to $DEST_DIR/libdropdrawer_p2p.dylib"
echo "Done! You can now run: cd app && flutter run -d macos"
