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

# Install the ad-hoc build (clears Gatekeeper quarantine, copies to /Applications)
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
  `diskutil list -plist`, then keeps those whose `BusProtocol` **begins with** `"Fibre Channel"`
  (real SANlink/Xsan hardware reports `"Fibre Channel Interface"`, not `"Fibre Channel"` — match
  by prefix, not equality). APFS containers are resolved through their physical store. Collects
  mountable volumes from partitions, APFS volumes, **and whole-disk filesystems** — an Xsan
  volume *is* the whole disk (`acfs`, no partition map). Raw `Apple_Xsan_Component` LUNs (the
  bare FC devices backing an Xsan volume) are excluded. Performs `mount` / `unmount` (with
  `force` retry) / `eject` (skipped for non-ejectable Xsan volumes — unmount is the complete
  safe-disconnect action there). All methods are synchronous, must run off the main thread, and
  memoise each disk's `diskutil info` per scan (a SAN can expose dozens of LUNs). **Every
  `diskutil` call has a hard timeout** (`runDiskutil(_:timeout:)`, 60s default, 180s for
  mount/unmount): on expiry the process is SIGTERM'd then SIGKILL'd, so a wedged `diskutil`
  can never starve the serial work queue or the shutdown guard.
- **[SANUnlink/Models/VolumeStore.swift](SANUnlink/Models/VolumeStore.swift)** — `@MainActor`
  `ObservableObject`, the single source of truth for the UI. Runs `DiskService` off a background
  queue; refreshes on Disk Arbitration events plus a 5s backup timer. Exposes
  `toggle` / `mountAll` / `ejectAll` / `setLaunchAtLogin`, and tracks in-flight
  `operations` (per-volume mounting/unmounting) that drive the status UI. Two robustness
  measures matter: **refreshes are coalesced** (only one enumeration at a time; event bursts
  collapse into a single follow-up, so a mount's DA storm can't back up minutes of scans), and
  **`applyRefresh` is flicker-resistant** (a transient empty result never blanks the list — it
  re-checks after 3s — and a volume with an operation in flight is kept visible even if
  `diskutil` momentarily drops it).
- **[SANUnlink/Services/DiskArbitrationWatcher.swift](SANUnlink/Services/DiskArbitrationWatcher.swift)**
  — wraps Disk Arbitration C callbacks (appeared / disappeared / changed) on a dedicated
  background run-loop thread and calls back on the main queue for live updates.
- **[SANUnlink/AppDelegate.swift](SANUnlink/AppDelegate.swift)** — the **shutdown/logout guard**.
  `applicationShouldTerminate` unmounts/ejects all FC volumes via `.terminateLater` + a hard
  timeout, then replies. **Crucially it only fires for a genuine system logout / restart /
  shutdown** — it treats the *presence* of a `kAEQuitReason` on the terminating Apple Event as a
  power event (biasing toward running the guard even on an unrecognised reason code), while a
  manual "Quit" — which carries no reason — returns `.terminateNow` and never touches the (often
  production) mounted volumes. `NSWorkspace.willPowerOffNotification` is a second, independent
  trigger for the same unmount.
- **[SANUnlink/Services/LoginItem.swift](SANUnlink/Services/LoginItem.swift)** — `SMAppService`
  wrapper for the "Launch at login" toggle (required so the guard is running at shutdown).
- **[SANUnlink/Views/MenuContentView.swift](SANUnlink/Views/MenuContentView.swift)** — the
  window-style popover: per-volume mount toggles with a **live status line** (`Mounting… 12s`,
  spinner) while an operation runs, a context-aware bulk button (**Unmount All** when anything is
  mounted, **Mount All** when nothing is), error row, launch-at-login, quit.

## Key constraints & gotchas

- **Swift language mode is 5.0** (`SWIFT_VERSION = 5.0` in the pbxproj), deliberately, to keep
  the Disk Arbitration C-callback bridging and `@MainActor` plumbing simple. Raising to Swift 6
  strict concurrency would require reworking `DiskArbitrationWatcher` and `VolumeStore`.
- **No privileged helper — verified against a real Xsan SAN.** `diskutil` mount/unmount of the
  Xsan volumes works as the logged-in user without root (even though `xsanctl` itself requires
  superuser). So the app deliberately does **not** ship an `SMAppService` daemon or use `xsanctl`.
  If some future force-unmount genuinely needs elevation, that daemon is the place to add it.
- **Xsan mounts are inherently slow (~60s).** That latency is StorNext/`acfs`, not the app; the
  UI surfaces it with the live per-volume status counter rather than trying to speed it up.
- **Detection is verified against real SANlink/Xsan hardware** (Fibre Channel Interface, whole-disk
  `acfs` volumes; the raw component LUNs are correctly hidden). With no FC hardware attached the
  app shows the empty state (the internal disk reports `BusProtocol = Apple Fabric`). When
  testing on non-Xsan FC drives, still confirm only FC volumes appear (a USB drive plugged in at
  the same time must **not** show up).
