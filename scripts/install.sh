#!/usr/bin/env bash
#
# Installer for the ad-hoc (non-notarized) build.
#
# Copies SANUnlink.app into /Applications and clears the Gatekeeper quarantine so
# it opens without the "unidentified developer" warning. Run from the folder that
# contains SANUnlink.app (e.g. the mounted DMG), or pass the path to the .app:
#
#   ./install.sh                 # looks for ./SANUnlink.app
#   ./install.sh /path/SANUnlink.app
#
set -euo pipefail

APP_SRC="${1:-$(dirname "$0")/SANUnlink.app}"
DEST="/Applications/SANUnlink.app"

[ -d "$APP_SRC" ] || { echo "error: SANUnlink.app not found at: $APP_SRC"; exit 1; }

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$APP_SRC" "$DEST"

echo "==> Clearing Gatekeeper quarantine"
xattr -dr com.apple.quarantine "$DEST" || true

echo "==> Launching"
open "$DEST"

echo "Done. SAN-Unlink is now in the menu bar. Enable 'Launch at login' from its menu."
