# SAN-Unlink

A macOS menu bar app that safely disconnects SANlink / Fibre Channel (FC) and Xsan drives.

Disconnecting FC volumes attached via SANlink can freeze macOS, and shutting down or logging
out while they are still connected can hang the machine. SAN-Unlink unmounts and ejects those
drives cleanly with one click — and automatically unmounts them on logout / shutdown, so the
Mac never hangs.

## Features

- **Auto-detects Fibre Channel drives**, including **Xsan** SAN volumes — only FC volumes
  appear; internal, USB, and SD media (and the raw Xsan component LUNs) are ignored.
- **One-click mount / unmount** per volume, with a **live status** counter while it works, plus
  a context-aware **Mount All** / **Unmount All (safe to disconnect)** button.
- **Shutdown / logout guard** — unmounts all FC volumes before the Mac powers off. It fires
  *only* on a real logout / restart / shutdown; a manual **Quit** never unmounts your volumes.
- **Launch at login** so the guard is always active.
- Native menu bar app, no Dock icon. No network access, no root, no privileged helper.

> **Note:** Xsan volume mounts are inherently slow (~60s — that's StorNext, not the app). The
> app shows a live `Mounting… Ns` status so you can see it is working.

## Requirements

- macOS 14 (Sonoma) or later — universal (Apple Silicon or Intel).
- Xcode 16+ to build from source.

## Install

Open `SANUnlink.dmg`, then install the app into `/Applications` so it has a stable location
(this matters — see the note below).

- **Notarized build:** drag **SANUnlink** to Applications and open it.
- **Ad-hoc build (unsigned):** macOS Gatekeeper will block it as an "unidentified developer."
  Run the bundled installer from the mounted DMG, which copies it to `/Applications` and clears
  the quarantine flag:

  ```sh
  ./install.sh
  ```

  (Alternatively: drag it to Applications, then right-click → **Open** → **Open** the first
  time.)

Once it is running, open the menu and enable **Launch at login**.

> **Why /Applications matters:** running the app directly from the DMG or Downloads while it is
> still quarantined triggers macOS "app translocation" (it runs from a random read-only path).
> That breaks **Launch at login** and therefore the shutdown guard. Installing to `/Applications`
> with the quarantine cleared (what `install.sh` does) avoids this.

## Build from source

```sh
./scripts/build.sh      # universal (arm64 + x86_64) app into ./dist
./scripts/package.sh    # wrap dist/SANUnlink.app into dist/SANUnlink.dmg
```

By default the build is **ad-hoc signed** (no Apple Developer account needed). To produce a
Developer ID–signed, notarized DMG that opens with no Gatekeeper prompt, set the signing and
notarization variables — see the header comments in [`scripts/package.sh`](scripts/package.sh).

## How it works

The app shells out to `/usr/sbin/diskutil` (via an argument array, never a shell) to enumerate
disks and mount / unmount / eject them, identifying FC devices by a `BusProtocol` that begins
with `Fibre Channel`. Xsan volumes are whole-disk `acfs` filesystems and are handled as such;
the raw component LUNs are hidden. Every `diskutil` call has a hard timeout so a wedged call
can't hang the app. `diskutil` performs the mount/unmount without root. The app listens for
live attach/detach via the Disk Arbitration framework, and hooks `applicationShouldTerminate`
(gated to genuine logout/shutdown) to run the guard. See [CLAUDE.md](CLAUDE.md) for
architecture details.
