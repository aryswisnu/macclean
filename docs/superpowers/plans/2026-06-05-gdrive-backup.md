# Google Drive Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Google Drive (via its CloudStorage mount) as a Copy-or-Move destination in the Largest Items tab, alongside external drives.

**Architecture:** Generalize `ExternalVolume` to a `Destination` model with an `externalDrive`/`googleDrive` kind. Detect Drive accounts by enumerating `~/Library/CloudStorage/GoogleDrive-*/My Drive`. Replace the Move-only flow with a Send flow whose confirm dialog offers Copy / Move / Cancel for every destination. Reuse `copyTree`/`copyFileChunked` unchanged.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, single file `MacClean.swift`, built with `./build.sh` (swiftc, no package manager, no test framework). Verification is compile plus scripted manual checks; there is no test infrastructure to TDD against (per approved spec).

**Spec:** `docs/superpowers/specs/2026-06-05-gdrive-backup-design.md`

**Line numbers** below refer to the baseline commit `fb9cbc8` of `MacClean.swift`. They shift as tasks land; anchor on the quoted code, not the numbers.

> **Bug fix included (Task 2):** the current `moveEntry` deletes `target` on ANY copy error. When the error is "Already exists on drive" (`copyTree` returns it before writing anything), that cleanup deletes the pre-existing item on the destination drive. Data loss. The new flow only cleans up on genuine partial-copy failures.

---

### Task 1: Destination model + Google Drive detection

**Files:**
- Modify: `MacClean.swift:798-807` (the `ExternalVolume` struct)
- Modify: `MacClean.swift:809-850` (`DiskUsageModel` published properties, `init`, `refreshVolumes`)
- Modify: `MacClean.swift:884-894,930` (three `refreshVolumes()` call sites inside `moveEntry`)
- Modify: `MacClean.swift:1189-1215` (`destinationPicker`)

After this task the app compiles and runs. Google Drive appears in the picker but the Move button errors against it ("not available") until Task 2 lands. Externals keep working.

- [ ] **Step 1: Replace the `ExternalVolume` struct with `Destination`**

Delete lines 798-807 (`struct ExternalVolume ... }`) and put this in their place:

```swift
struct Destination: Identifiable, Hashable {
    enum Kind { case externalDrive, googleDrive }
    let id: URL          // volume root, or ".../My Drive/MacClean Backups"
    let name: String     // "Samsung T7" / "Google Drive (user@gmail.com)"
    let kind: Kind
    let freeBytes: Int64?   // nil for Google Drive (quota unknowable from the mount)

    // Identity by URL only: freeBytes changes between scans, and including it
    // would break Picker selection matching (stale tag -> blank picker).
    static func == (lhs: Destination, rhs: Destination) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
```

- [ ] **Step 2: Update `DiskUsageModel` properties and `init`**

Replace the two published properties (lines 815-816):

```swift
    @Published var volumes: [ExternalVolume] = []
    @Published var destination: ExternalVolume? = nil
```

with:

```swift
    @Published var destinations: [Destination] = []
    @Published var destination: Destination? = nil
```

In `init()` (line 820), change `refreshVolumes()` to `refreshDestinations()`.

- [ ] **Step 3: Replace `refreshVolumes()` with `refreshDestinations()` + detection helper**

Delete the whole `refreshVolumes()` method (lines 827-850, including its doc comment) and put this in its place:

```swift
    /// Mounted external (non-internal) volumes plus signed-in Google Drive
    /// accounts, offered as send destinations. Externals first, then Drive.
    func refreshDestinations() {
        var found: [Destination] = []

        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsInternal == true { continue }
            let name = values.volumeName ?? url.lastPathComponent
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            found.append(Destination(id: url, name: name, kind: .externalDrive, freeBytes: free))
        }

        found.append(contentsOf: Self.googleDriveDestinations())

        destinations = found
        // Rebind destination to the FRESH instance (freeBytes differs each scan);
        // keep the same destination if still present, else first available.
        if let dest = destination, let match = found.first(where: { $0.id == dest.id }) {
            destination = match
        } else {
            destination = found.first
        }
    }

    /// One destination per signed-in Google Drive account, pointing at
    /// "My Drive/MacClean Backups" (created lazily on first send).
    nonisolated static func googleDriveDestinations() -> [Destination] {
        let fm = FileManager.default
        let cloudStorage = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage")
        guard let entries = try? fm.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [Destination] = []
        for entry in entries {
            let dirName = entry.lastPathComponent
            guard dirName.hasPrefix("GoogleDrive-") else { continue }
            let myDrive = entry.appendingPathComponent("My Drive")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: myDrive.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let account = String(dirName.dropFirst("GoogleDrive-".count))
            result.append(Destination(
                id: myDrive.appendingPathComponent("MacClean Backups"),
                name: "Google Drive (\(account))",
                kind: .googleDrive,
                freeBytes: nil
            ))
        }
        return result.sorted { $0.name < $1.name }
    }
```

- [ ] **Step 4: Update the three `refreshVolumes()` call sites inside `moveEntry`**

`moveEntry` calls `refreshVolumes()` at lines 885, 894, and 930. Change each to `refreshDestinations()`. Leave the rest of `moveEntry` untouched; it compiles because `Destination` also has `.id` and `.name`. (The whole method is replaced in Task 2.)

- [ ] **Step 5: Update `destinationPicker` in `DiskUsageView`**

Replace the `destinationPicker` computed property (lines 1189-1215) with:

```swift
    private var destinationPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            if model.destinations.isEmpty {
                Text("No destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.refreshDestinations()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-check for drives and Google Drive")
            } else {
                Picker("Send to", selection: $model.destination) {
                    ForEach(model.destinations) { dest in
                        Text(destinationLabel(dest))
                            .tag(Destination?.some(dest))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
    }

    private func destinationLabel(_ dest: Destination) -> String {
        if let free = dest.freeBytes {
            return "\(dest.name) (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free)"
        }
        return dest.name
    }
```

- [ ] **Step 6: Build**

Run: `cd /Users/edgepropmacbookpro/MacClean && ./build.sh`
Expected: ends with `Built: /Users/edgepropmacbookpro/MacClean/MacClean.app`. No compiler errors. Grep check that no stale references remain: `grep -n "ExternalVolume\|refreshVolumes" MacClean.swift` returns nothing. Then `grep -n "\.volumes" MacClean.swift` returns exactly two hits, both inside `StorageOverview` (around lines 444 and 448); that is a different model (`StorageModel.volumes`) and stays as is.

- [ ] **Step 7: Smoke test**

Run: `open MacClean.app`, switch to Largest Items tab.
Expected: picker shows "Google Drive (bayuarys2010@gmail.com)" (plus any connected external drives, listed first).

- [ ] **Step 8: Commit**

```bash
git add MacClean.swift
git commit -m "feat: generalize move destinations, detect Google Drive mounts"
```

---

### Task 2: Send flow with Copy / Move / Cancel

**Files:**
- Modify: `MacClean.swift:884-936` (replace `moveEntry`)
- Modify: `MacClean.swift:938-960` (`beginMoving` / `setProgress` status strings)
- Modify: `MacClean.swift:968-978` (replace `confirmMove`)
- Modify: `MacClean.swift:990-992` (error string in `copyTree`)
- Modify: `MacClean.swift:1150` (call site in `DiskUsageView`)

- [ ] **Step 1: Replace `moveEntry` with `sendEntry`**

Delete the whole `moveEntry` method including its doc comment (lines 882-936) and put this in its place:

```swift
    /// Send one entry to the selected destination. The user picks Copy (keep
    /// the original) or Move (delete the original after a verified copy).
    /// Chunked copy with byte progress; cross-volume safe.
    func sendEntry(_ entry: DiskEntry) async {
        refreshDestinations()
        guard let dest = destination else {
            setStatus(for: entry.id, "No destination available")
            return
        }
        // Re-verify the destination is still mounted (drives and DriveFS are
        // flaky). For Google Drive the backup folder may not exist yet, so
        // check its parent ("My Drive", which exists iff the mount is alive).
        let mountCheck: URL = dest.kind == .googleDrive
            ? dest.id.deletingLastPathComponent()
            : dest.id
        guard FileManager.default.fileExists(atPath: mountCheck.path) else {
            setStatus(for: entry.id, "\(dest.name) not available")
            refreshDestinations()
            return
        }

        let action = await confirmSend(name: entry.name, bytes: entry.sizeBytes, dest: dest)
        guard action != .cancel else { return }

        // Lazily create "MacClean Backups" on Google Drive (idempotent).
        if dest.kind == .googleDrive {
            do {
                try FileManager.default.createDirectory(at: dest.id, withIntermediateDirectories: true)
            } catch {
                setStatus(for: entry.id, "Cannot create backup folder on Google Drive")
                return
            }
        }

        beginMoving(for: entry.id)
        let src = entry.url
        let target = dest.id.appendingPathComponent(entry.name)
        let total = max(entry.sizeBytes, 1)

        // Stream byte-progress from the detached copy back to the UI.
        let (stream, continuation) = AsyncStream.makeStream(of: Int64.self)
        let copyTask = Task.detached(priority: .userInitiated) { () -> String? in
            let err = Self.copyTree(from: src, to: target) { copied in
                continuation.yield(copied)
            }
            continuation.finish()
            return err
        }

        for await copied in stream {
            setProgress(for: entry.id, Double(copied) / Double(total))
        }
        let error = await copyTask.value

        if let error = error {
            // Clean up a partial copy, but never delete a pre-existing item
            // at the destination (copyTree wrote nothing in that case).
            if error != "Already exists at destination" {
                try? FileManager.default.removeItem(at: target)
            }
            endMoving(for: entry.id, status: error)
            return
        }

        switch action {
        case .copy:
            // Source stays; nothing freed locally, so no storageChanged post.
            endMoving(for: entry.id, status: "Copied to \(dest.name)")
        case .move:
            // Copy verified by copyTree; now remove the source.
            do {
                try FileManager.default.removeItem(at: src)
                endMoving(for: entry.id, status: nil)
                await scan()
                refreshDestinations()
                NotificationCenter.default.post(name: .storageChanged, object: nil)
            } catch {
                endMoving(for: entry.id, status: "Copied OK, source delete failed")
            }
        case .cancel:
            break
        }
    }
```

- [ ] **Step 2: Generalize progress strings**

In `beginMoving` (line ~942) change `"Moving… 0%"` to `"Sending… 0%"`.
In `setProgress` (line ~950) change `"Moving… \(Int(clamped * 100))%"` to `"Sending… \(Int(clamped * 100))%"`.

- [ ] **Step 3: Replace `confirmMove` with `SendAction` + `confirmSend`**

Delete the `confirmMove` method (lines 968-978) and put this in its place:

```swift
    enum SendAction {
        case copy
        case move
        case cancel
    }

    private func confirmSend(name: String, bytes: Int64, dest: Destination) async -> SendAction {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Send \(name) to \(dest.name)?"
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            var info = "Copy keeps the original on this Mac. Move sends \(size) and removes it from this Mac."
            if dest.kind == .googleDrive {
                info += " Uploads finish in the background via the Google Drive app."
            }
            alert.informativeText = info
            alert.alertStyle = .warning
            // Button order = return order: first..third.
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  return .copy
            case .alertSecondButtonReturn: return .move
            default:                       return .cancel
            }
        }
    }
```

- [ ] **Step 4: Generalize the exists error in `copyTree`**

Line ~991, inside `copyTree`:

```swift
        if fm.fileExists(atPath: target.path) {
            return "Already exists on drive"
        }
```

becomes:

```swift
        if fm.fileExists(atPath: target.path) {
            return "Already exists at destination"
        }
```

This string is compared verbatim in `sendEntry` Step 1 to skip the partial-copy cleanup. If you reword one, reword both.

- [ ] **Step 5: Update the call site in `DiskUsageView`**

Line ~1150: change

```swift
                            moveAction: { Task { await model.moveEntry(entry) } }
```

to

```swift
                            moveAction: { Task { await model.sendEntry(entry) } }
```

(The `moveAction` parameter itself is renamed in Task 3.)

- [ ] **Step 6: Build**

Run: `cd /Users/edgepropmacbookpro/MacClean && ./build.sh`
Expected: `Built: ...` with no errors. `grep -n "moveEntry\|confirmMove\|Already exists on drive" MacClean.swift` returns nothing.

- [ ] **Step 7: Commit**

```bash
git add MacClean.swift
git commit -m "feat: copy-or-move send flow for all destinations

Confirm dialog now offers Copy / Move / Cancel. Google Drive sends
land in My Drive/MacClean Backups (created lazily). Fixes data-loss
bug where an 'already exists' error deleted the pre-existing item
at the destination."
```

---

### Task 3: Row and label polish

**Files:**
- Modify: `MacClean.swift:1143-1151` (`DiskUsageView` row construction)
- Modify: `MacClean.swift:1231-1291` (`DiskEntryRow`)

- [ ] **Step 1: Rename row parameters and update the Send button**

In `DiskEntryRow` (lines 1231-1291):

1. Rename the stored properties `canMove` to `canSend` and `moveAction` to `sendAction` (also in the `HStack` body where they are referenced).
2. Replace the Move button block:

```swift
            Button {
                moveAction()
            } label: {
                Label("Move", systemImage: "arrow.right.circle")
            }
            .disabled(!canMove || entry.isMoving)
            .help(canMove ? "Move to \(destinationName ?? "external drive")" : "Connect an external drive first")
```

with:

```swift
            Button {
                sendAction()
            } label: {
                Label("Send", systemImage: "arrow.right.circle")
            }
            .disabled(!canSend || entry.isMoving)
            .help(canSend ? "Copy or move to \(destinationName ?? "destination")" : "Connect a drive or sign in to Google Drive first")
```

- [ ] **Step 2: Update the row construction in `DiskUsageView`**

Lines 1143-1151, replace:

```swift
                        DiskEntryRow(
                            entry: entry,
                            total: model.totalBytes,
                            canMove: model.destination != nil,
                            destinationName: model.destination?.name,
                            revealAction: { model.reveal(entry.url) },
                            moveAction: { Task { await model.sendEntry(entry) } }
                        )
```

with:

```swift
                        DiskEntryRow(
                            entry: entry,
                            total: model.totalBytes,
                            canSend: model.destination != nil,
                            destinationName: model.destination?.name,
                            revealAction: { model.reveal(entry.url) },
                            sendAction: { Task { await model.sendEntry(entry) } }
                        )
```

- [ ] **Step 3: Build**

Run: `cd /Users/edgepropmacbookpro/MacClean && ./build.sh`
Expected: `Built: ...` with no errors. `grep -n "canMove\|moveAction" MacClean.swift` returns nothing.

- [ ] **Step 4: Commit**

```bash
git add MacClean.swift
git commit -m "feat: relabel row action to Send, update destination hints"
```

---

### Task 4: Manual verification

**Files:** none modified (fixes, if needed, get their own commits).

- [ ] **Step 1: Create a sandbox folder with known content**

```bash
mkdir -p ~/MacCleanTest
dd if=/dev/zero of=~/MacCleanTest/testfile.bin bs=1m count=5
mkdir -p ~/MacCleanTest/testdir
dd if=/dev/zero of=~/MacCleanTest/testdir/inner.bin bs=1m count=3
```

- [ ] **Step 2: Copy a file to Google Drive**

`open MacClean.app` > Largest Items > Choose Folder... > pick `~/MacCleanTest` > Scan. Pick "Google Drive (bayuarys2010@gmail.com)" in the picker. Click Send on `testfile.bin`, choose **Copy**.
Expected: progress bar runs, row status becomes "Copied to Google Drive (bayuarys2010@gmail.com)". Verify both sides:

```bash
ls -l ~/Library/CloudStorage/GoogleDrive-bayuarys2010@gmail.com/"My Drive/MacClean Backups/"
ls -l ~/MacCleanTest/testfile.bin
```

Expected: file present in both places, 5 MB each.

- [ ] **Step 3: Duplicate copy is rejected without deleting the Drive copy**

Click Send on `testfile.bin` again, choose **Copy**.
Expected: status "Already exists at destination". Re-run the first `ls`; the Drive copy is still there (this is the bug-fix check).

- [ ] **Step 4: Move a directory to Google Drive**

Click Send on `testdir`, choose **Move**.
Expected: progress, then the row disappears after rescan; storage bar refreshes.

```bash
ls -l ~/Library/CloudStorage/GoogleDrive-bayuarys2010@gmail.com/"My Drive/MacClean Backups/testdir/"
ls ~/MacCleanTest/
```

Expected: `inner.bin` (3 MB) on Drive; `testdir` gone locally.

- [ ] **Step 5: External drive still works (skip if none connected)**

Connect an external drive, hit the picker refresh if needed, select the drive, Send a small file with **Copy**, then again with **Move**.
Expected: both succeed; Copy leaves the local file, Move removes it.

- [ ] **Step 6: Mount-loss handling**

Quit the Google Drive menu-bar app. In MacClean, click the picker refresh (or trigger any send).
Expected: the Google Drive entry leaves the picker; if it was selected, selection falls back to the first remaining destination or "No destination". Restart Google Drive afterwards.

- [ ] **Step 7: Clean up**

```bash
rm -rf ~/MacCleanTest
rm -rf ~/Library/CloudStorage/GoogleDrive-bayuarys2010@gmail.com/"My Drive/MacClean Backups"
```

(Or keep the Drive folder; later backups recreate it either way.)
