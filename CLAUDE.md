# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SAN-Unlink is a macOS **menu bar app** (SwiftUI, `MenuBarExtra`) that safely unmounts/ejects
SANlink Fibre Channel (FC) drives. The problem it solves: disconnecting FC volumes can freeze
macOS, and shutting down while they're connected can hang the machine. The app unmounts/ejects
them cleanly on demand and automatically on logout/shutdown.

- **Deployment target:** macOS 14+. Built as a **universal binary** (arm64 + x86_64).
- **App type:** menu-bar-only agent (`LSUIElement = true`, no Dock icon).
- **Not sandboxed** (see [SANUnlink/SANUnlink.entitlements](SANUnlink/SANUnlink.entitlements)):
  it shells out to `diskutil` and uses Disk Arbitration, which the App Sandbox would block.
  Ships with the hardened runtime for notarization.

## Commands

```sh
# Build & run from the command line (Debug)
xcodebuild -project SANUnlink.xcodeproj -scheme SANUnlink -configuration Debug build
open build/Build/Products/Debug/SANUnlink.app     # if -derivedDataPath build was used

# Universal Release build into ./dist
./scripts/build.sh
# Optionally sign with Developer ID:
CODE_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" ./scripts/build.sh

# Package dist/SANUnlink.app into a DMG (add NOTARY_PROFILE to notarize — see script header)
./scripts/package.sh

# Coworker install for the ad-hoc build (clears Gatekeeper quarantine)
./scripts/install.sh
```

There is no test target yet. The project (`SANUnlink.xcodeproj/project.pbxproj`) is
**hand-maintained** — when adding a source file, add both a `PBXFileReference` and a
`PBXBuildFile` (in the Sources phase) using the existing 24-hex-digit ID scheme
(`1…` = file refs, `2…` = build files), or open the project in Xcode which will rewrite it.

## Architecture

Data flows: `diskutil` / Disk Arbitration → `DiskService` → `VolumeStore` → SwiftUI views.

- **[SANUnlink/Services/DiskService.swift](SANUnlink/Services/DiskService.swift)** — the core.
  Stateless enum that shells out to `/usr/sbin/diskutil`. Enumerates disks via
  `diskutil list -plist`, then filters to FC by reading `BusProtocol == "Fibre Channel"` from
  `diskutil info -plist` (APFS containers are resolved through their physical store). Also
  performs `mount` / `unmount` (with `force` retry) / `eject`. All methods are synchronous and
  must be called off the main thread.
- **[SANUnlink/Models/VolumeStore.swift](SANUnlink/Models/VolumeStore.swift)** — `@MainActor`
  `ObservableObject` that is the single source of truth for the UI. Runs `DiskService` work on
  a background queue, refreshes on Disk Arbitration events plus a 5s backup timer, and exposes
  `toggle` / `eject` / `ejectAll` / `setLaunchAtLogin`.
- **[SANUnlink/Services/DiskArbitrationWatcher.swift](SANUnlink/Services/DiskArbitrationWatcher.swift)**
  — wraps Disk Arbitration C callbacks (appeared / disappeared / changed) on a dedicated
  background run-loop thread and calls back on the main queue for live updates.
- **[SANUnlink/AppDelegate.swift](SANUnlink/AppDelegate.swift)** — the **shutdown/logout guard**.
  `applicationShouldTerminate` returns `.terminateLater`, ejects all FC disks on a background
  queue, then replies `true` — with a hard timeout so it can never hang shutdown itself. Also
  observes `NSWorkspace.willPowerOffNotification`.
- **[SANUnlink/Services/LoginItem.swift](SANUnlink/Services/LoginItem.swift)** — `SMAppService`
  wrapper for the "Launch at login" toggle (required so the guard is running at shutdown).
- **[SANUnlink/Views/MenuContentView.swift](SANUnlink/Views/MenuContentView.swift)** — the
  window-style popover: per-volume mount toggles, "Eject All", error row, launch-at-login, quit.

## Key constraints & gotchas

- **Swift language mode is 5.0** (`SWIFT_VERSION = 5.0` in the pbxproj), deliberately, to keep
  the Disk Arbitration C-callback bridging and `@MainActor` plumbing simple. Raising to Swift 6
  strict concurrency would require reworking `DiskArbitrationWatcher` and `VolumeStore`.
- **No privileged helper.** User-owned external FC volumes unmount/eject without root. If
  force-unmount of a busy volume ever needs elevation, that's the point to add an `SMAppService`
  daemon — it is intentionally not there yet.
- **FC detection can only be fully verified with real SANlink hardware.** With none attached the
  app correctly shows the empty state (the internal disk reports `BusProtocol = Apple Fabric`).
  Before shipping, run the real-device pass: confirm only FC volumes appear (a USB drive plugged
  in at the same time must **not** show up).
