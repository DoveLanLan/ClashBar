#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build -c debug
BUILD_DIR="$(swift build -c debug --show-bin-path)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ClashBarSyncRegression.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Link the app implementation into a separate entry point. This also works with
# Command Line Tools, without XCTest or third-party dependencies.
OBJECTS=()
for object in "$BUILD_DIR"/ClashBar.build/*.swift.o "$BUILD_DIR"/ProxyHelperShared.build/*.swift.o; do
  case "$object" in
    */ClashBarApp.swift.o) continue ;;
  esac
  OBJECTS+=("$object")
done
swiftc -swift-version 6 -parse-as-library \
  -I "$BUILD_DIR/Modules" \
  "$ROOT/Tests/ClashBarTests/SyncTests.swift" \
  "${OBJECTS[@]}" \
  -o "$TEST_DIR/sync-regression"
"$TEST_DIR/sync-regression"
