# MacClean

A small, fast macOS disk cleanup utility. Reclaim space from caches, logs, and
developer tooling, see what is eating your disk, and offload your largest files
to an external drive or Google Drive.

Built with SwiftUI and AppKit. No dependencies, no package manager, one Swift
file, one build script.

## Features

**Storage overview** shown above every tab: per-volume used / free / purgeable
capacity, matching what Finder and About This Mac report.

**Cleanup tab** scans and clears common space hogs, each with a size estimate
and a confirmation before anything is deleted:

- User Caches (`~/Library/Caches`)
- User Logs (`~/Library/Logs`)
- Trash (`~/.Trash`)
- Xcode DerivedData
- Screenshots (delete all, or prune older than 7 / 30 days)
- Homebrew cleanup (`brew cleanup -s` + `brew autoremove`)

**Largest Items tab** scans any folder, lists its biggest files and folders, and
lets you **Send** each one to a destination of your choice:

- **Copy** keeps the original on your Mac (a real backup).
- **Move** copies to the destination, then removes the local copy to free space.

Destinations are mounted external drives and any signed-in Google Drive account.
Google Drive items land in `My Drive/MacClean Backups`, uploaded in the
background by the Google Drive app. Copies are chunked and verified before the
source is ever removed.

Reclaiming space triggers a small celebration.

## Requirements

- macOS 13 or later
- Swift toolchain (`swiftc`, from Xcode or the Command Line Tools)
- Optional: **Full Disk Access** for MacClean, so it can read protected caches
  (granted from System Settings, with a one-click button in the app)
- Optional: **Homebrew**, for the Homebrew cleanup target
- Optional: **Google Drive for desktop**, signed in, for Google Drive backups

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/aryswisnu/macclean/main/install.sh | bash
```

This downloads the latest release, installs `MacClean.app` to `/Applications`
(or `~/Applications` if that is not writable), and removes the macOS quarantine
flag so the app opens on first launch.

MacClean is ad-hoc signed, not Apple-notarized, so a freshly downloaded copy
would otherwise be blocked by Gatekeeper. The installer clears that flag for
you. If you prefer to do it by hand, download `MacClean.zip` from the
[Releases page](https://github.com/aryswisnu/macclean/releases), unzip it into
`/Applications`, then run `xattr -dr com.apple.quarantine /Applications/MacClean.app`.

Prefer to build it yourself? See [Build](#build) below.

## Build

```bash
./build.sh
open MacClean.app
```

`build.sh` compiles `MacClean.swift`, generates the app icon on first run, and
code-signs the bundle (ad-hoc by default; see the script for using a stable
local signing identity so Full Disk Access grants survive rebuilds).

## How it works

Google Drive support uses the Google Drive desktop mount under
`~/Library/CloudStorage/GoogleDrive-<account>/My Drive` as an ordinary
filesystem destination. There is no OAuth, no API key, and no network code in
MacClean itself: the Google Drive app handles upload, retry, and offline
queueing.

Moving a file copies it in 4 MB chunks with the unified buffer cache bypassed
(`F_NOCACHE`) so large transfers do not balloon memory, and only deletes the
source after the copy completes without error.

## Safety

Every destructive action asks for confirmation and reports how much it will
remove. Cleanup deletes are permanent (they do not go to Trash), so the
confirmation matters. A failed or partial copy never deletes your source file,
and sending an item that already exists at the destination is refused rather
than overwriting it.

## License

[MIT](LICENSE) © 2026 Arys Wisnu
