# Google Drive Backup for Largest Items

**Date:** 2026-06-05
**Status:** Approved by user
**Scope:** MacClean.swift (single file), Largest Items tab

## Goal

Add Google Drive as a backup destination in the Largest Items tab. Items can be copied (true backup, local file kept) or moved (local file deleted after copy) to Google Drive. The Copy/Move choice also applies to external drives, which today only support Move.

## Approach

Use the Google Drive Desktop mount at `~/Library/CloudStorage/GoogleDrive-*/My Drive/` as a filesystem destination. Reuse the existing `copyTree` / `copyFileChunked` machinery unchanged. DriveFS handles upload, retry, and offline queueing.

Rejected alternatives:

- **Drive REST API + OAuth:** real quota checks and upload confirmation, but requires OAuth client registration, Keychain token storage, and the resumable-upload protocol. Roughly 600+ lines in dependency-free Swift. Disproportionate for this app.
- **Manual handoff (reveal in Finder):** not a feature.

## Data model

`ExternalVolume` generalizes to `Destination`:

```swift
struct Destination: Identifiable, Hashable {
    enum Kind { case externalDrive, googleDrive }
    let id: URL          // volume root, or ".../My Drive/MacClean Backups"
    let name: String     // "Samsung T7" / "Google Drive (user@gmail.com)"
    let kind: Kind
    let freeBytes: Int64?   // nil for Drive (quota unknowable from mount)
}
```

- Identity is URL-only (`==` and `hash` use `id` alone). Preserves the existing Picker selection-matching fix: freeBytes changes between scans and would break tag matching.
- `freeBytes` is `nil` for Google Drive because the CloudStorage mount reports local disk capacity, not Drive quota.

## Detection

`refreshVolumes()` becomes `refreshDestinations()`:

1. External volumes: existing logic unchanged (mounted, non-internal, non-hidden).
2. Google Drive: enumerate `~/Library/CloudStorage/`, match directories named `GoogleDrive-*` that contain `My Drive/`. Each account found becomes one picker entry. The destination URL is `<mount>/My Drive/MacClean Backups`.
3. Order: external drives first, then Drive accounts.

`MacClean Backups` is created lazily on first send (not at detection time), via `createDirectory(withIntermediateDirectories: true)`, which is idempotent.

If the Google Drive app quits, the mount disappears and the entry drops from the picker on the next refresh, the same flow as an ejected drive. The existing pre-send "still mounted" re-check covers Drive too.

## UI changes

- **Picker:** Drive rows show "Google Drive (account email)" with no free-bytes suffix. External rows unchanged.
- **Row button:** "Move" relabels to "Send" (icon unchanged). Tooltip: "Copy or move to \<destination\>".
- **Empty state:** "No external drive" text becomes "No destination" and only shows when neither an external drive nor a Drive mount exists.
- **Confirm dialog (all destinations):** title "Send \<name\> to \<dest\>?", buttons **Copy** / **Move** / **Cancel**. The Move text keeps the "removes it from this Mac" warning. For Drive, the dialog adds "uploads in background via the Google Drive app".

## Action flow

`moveEntry(_:)` becomes `sendEntry(_:)`:

1. Refresh destinations; verify destination mount still exists (existing pattern).
2. Drive only: create `MacClean Backups/` (idempotent). On failure: status message, abort.
3. Confirm dialog returns `.copy` / `.move` / `.cancel`.
4. `copyTree` runs unchanged: chunked copy, 8 MB progress reports, `F_NOCACHE`, 256 MB periodic syncs. The progress bar reflects bytes handed to DriveFS, not bytes uploaded to Google's servers.
5. **Copy:** done when `copyTree` returns nil. Status: "Copied to \<dest\>". No `storageChanged` notification (nothing freed locally).
6. **Move:** delete source, rescan, post `storageChanged` (existing flow, confetti eligible).

## Error handling

All existing error paths are preserved:

- Target already exists at destination: `copyTree` returns an error; message text generalizes from "Already exists on drive" to "Already exists at destination".
- Copy fails midway: partial target removed, source left intact (existing).
- Source delete fails after a successful move-copy: "Copied OK, source delete failed" (existing).
- `MacClean Backups` creation fails: "Cannot create backup folder on Google Drive".
- `fcntl F_NOCACHE` may return -1 on FileProvider file descriptors; the return value is already ignored, harmless.

Known semantics, accepted: a Move deletes the local file once it is written to the DriveFS local cache, before the background upload completes. DriveFS persists its queue across reboots and uploads when online, so the window is acceptable for this app.

## Testing

No test infrastructure exists (single-file swiftc app). Verification is build plus manual checks:

1. `./build.sh` compiles clean.
2. Scan a folder, pick Google Drive in the picker, Copy a small file: appears in `My Drive/MacClean Backups/`, local file intact.
3. Move a small file: present in Drive, gone locally, storage bar refreshes.
4. Copy the same file again: "Already exists at destination" message.
5. External drive (if connected): Copy and Move both work.
6. Quit the Google Drive app: entry leaves the picker after refresh.
