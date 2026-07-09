#!/usr/bin/env bash
#
# Builds a universal (arm64 + x86_64) Release SANUnlink.app into ./dist.
#
# Usage:
#   ./scripts/build.sh                       # ad-hoc signed (personal / dev)
#   CODE_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" ./scripts/build.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SANUnlink.xcodeproj"
SCHEME="SANUnlink"
DERIVED="build"
DIST="dist"
IDENTITY="${CODE_SIGN_IDENTITY:--}"   # default: ad-hoc "-"

echo "==> Cleaning previous product"
# Also clear the derived-data folder: reusing it after package.sh re-signs the app
# triggers a spurious "Entitlements file was modified during the build" error.
rm -rf "$DIST" "$DERIVED"
mkdir -p "$DIST"

echo "==> Building universal Release (identity: $IDENTITY)"
xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-derivedDataPath "$DERIVED" \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	CODE_SIGN_IDENTITY="$IDENTITY" \
	build

APP_SRC="$DERIVED/Build/Products/Release/SANUnlink.app"
cp -R "$APP_SRC" "$DIST/"

echo "==> Built: $DIST/SANUnlink.app"
echo "    Architectures: $(lipo -archs "$DIST/SANUnlink.app/Contents/MacOS/SANUnlink")"
codesign -dv "$DIST/SANUnlink.app" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" || true
