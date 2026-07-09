#!/usr/bin/env bash
#
# Packages dist/SANUnlink.app into a distributable DMG.
#
# Two modes, chosen automatically by whether notarization credentials are set:
#
#   1. Notarized (recommended for coworkers). Requires a Developer ID and a
#      notarytool keychain profile:
#        CODE_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
#        NOTARY_PROFILE="sanunlink-notary" \
#        ./scripts/build.sh && ./scripts/package.sh
#      (Create the profile once with:
#         xcrun notarytool store-credentials sanunlink-notary \
#           --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW)
#
#   2. Ad-hoc (no Apple Developer account). Just run build.sh then package.sh;
#      coworkers install with scripts/install.sh to clear the Gatekeeper quarantine.
#
set -euo pipefail

cd "$(dirname "$0")/.."

DIST="dist"
APP="$DIST/SANUnlink.app"
DMG="$DIST/SANUnlink.dmg"
IDENTITY="${CODE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

[ -d "$APP" ] || { echo "error: $APP not found. Run ./scripts/build.sh first."; exit 1; }

if [ -n "$IDENTITY" ]; then
	echo "==> Re-signing with hardened runtime: $IDENTITY"
	codesign --force --options runtime \
		--entitlements SANUnlink/SANUnlink.entitlements \
		--sign "$IDENTITY" --timestamp "$APP"
fi

echo "==> Creating DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "SAN-Unlink" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ -n "$NOTARY_PROFILE" ]; then
	echo "==> Submitting DMG for notarization (profile: $NOTARY_PROFILE)"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	echo "==> Stapling ticket"
	xcrun stapler staple "$DMG"
	xcrun stapler staple "$APP"
else
	echo "==> Skipping notarization (NOTARY_PROFILE not set)."
	echo "    Coworkers must install via scripts/install.sh to clear quarantine."
fi

echo "==> Packaged: $DMG"
