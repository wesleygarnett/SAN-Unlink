# SAN-Unlink

A macOS menu bar app that safely disconnects SANlink / Fibre Channel (FC) drives.

Disconnecting FC volumes attached via SANlink can freeze macOS, and shutting down or
logging out while they're still connected can hang the machine. SAN-Unlink lets you unmount
and eject those drives cleanly with one click — and automatically ejects them on logout /
shutdown so the Mac never hangs.

## Features

- **Auto-detects Fibre Channel drives**, including **Xsan** SAN volumes — only FC volumes appear;
  internal, USB, and SD media (and the raw Xsan component LUNs) are ignored.
- **One-click mount / unmount** per volume, with a **live status** counter while it works, plus
  context-aware **Mount All** / **Unmount All (safe to disconnect)**.
- **Shutdown / logout guard** — unmounts all FC volumes before the Mac powers off. It fires
  *only* on a real logout/restart/shutdown; a manual **Quit** never unmounts your volumes.
- **Launch at login** so the guard is always active.
- Native menu bar app, no Dock icon.

> **Note:** Xsan volume mounts are inherently slow (~60s — that's StorNext, not the app). The
> app shows a live `Mounting… Ns` status so you can see it's working.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel.
- Xcode 16+ to build from source.

## Install (coworkers)

Open `SANUnlink.dmg` and drag **SANUnlink** to Applications.

- **Notarized build:** it just opens. Enable *Launch at login* from the menu.
- **Ad-hoc build (unsigned):** macOS will block it as "unidentified developer." Run the
  bundled installer from the DMG to clear the quarantine and launch it:

  ```sh
  ./install.sh
  ```

  (Or right-click the app → **Open** → **Open** the first time.)

## Build from source

```sh
./scripts/build.sh      # universal (arm64 + x86_64) app into ./dist
./scripts/package.sh    # wrap dist/SANUnlink.app into dist/SANUnlink.dmg
```

For a signed + notarized DMG (recommended for sharing), see the header comments in
[`scripts/package.sh`](scripts/package.sh).

## How it works

The app shells out to `/usr/sbin/diskutil` to enumerate disks and mount / unmount / eject
them, identifying FC devices by their `BusProtocol` (which begins with `Fibre Channel`). Xsan
volumes are whole-disk `acfs` filesystems and are handled as such; the raw component LUNs are
hidden. `diskutil` performs the mount/unmount without root. It listens for live attach/detach
via the Disk Arbitration framework, and hooks `applicationShouldTerminate` (gated to genuine
logout/shutdown) to run the guard. See [CLAUDE.md](CLAUDE.md) for architecture details.
