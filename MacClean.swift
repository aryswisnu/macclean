import SwiftUI
import AppKit
import Darwin

extension Notification.Name {
    /// Posted after any action that changes disk usage (clean / move) so the
    /// global Storage overview can refresh.
    static let storageChanged = Notification.Name("MacCleanStorageChanged")
}

@main
struct MacCleanApp: App {
    var body: some Scene {
        WindowGroup("MacClean") {
            ContentView()
                .frame(minWidth: 680, minHeight: 720)
        }
        .defaultSize(width: 820, height: 820)
        .windowResizability(.contentSize)
    }
}

struct CleanupTarget: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let kind: Kind
    var sizeBytes: Int64 = 0
    var isScanning: Bool = false
    var isCleaning: Bool = false
    var lastCleaned: Date? = nil
    var statusMessage: String? = nil

    enum Kind {
        case directoryContents(URL)
        case screenshots(URL)
        case brewCleanup
    }
}

@MainActor
final class CleanupModel: ObservableObject {
    @Published var targets: [CleanupTarget]
    @Published var totalReclaimed: Int64 = 0
    @Published var isBusy: Bool = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        targets = [
            CleanupTarget(
                name: "User Caches",
                subtitle: "~/Library/Caches",
                kind: .directoryContents(home.appendingPathComponent("Library/Caches"))
            ),
            CleanupTarget(
                name: "User Logs",
                subtitle: "~/Library/Logs",
                kind: .directoryContents(home.appendingPathComponent("Library/Logs"))
            ),
            CleanupTarget(
                name: "Trash",
                subtitle: "~/.Trash",
                kind: .directoryContents(home.appendingPathComponent(".Trash"))
            ),
            CleanupTarget(
                name: "Xcode DerivedData",
                subtitle: "~/Library/Developer/Xcode/DerivedData",
                kind: .directoryContents(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
            ),
            CleanupTarget(
                name: "Screenshots",
                subtitle: "~/Screenshots",
                kind: .screenshots(home.appendingPathComponent("Screenshots"))
            ),
            CleanupTarget(
                name: "Homebrew cleanup",
                subtitle: "brew cleanup -s && brew autoremove",
                kind: .brewCleanup
            ),
        ]
    }

    func scanAll() async {
        for idx in targets.indices {
            await scan(index: idx)
        }
    }

    func scan(index: Int) async {
        guard targets.indices.contains(index) else { return }
        targets[index].isScanning = true
        targets[index].statusMessage = nil
        let kind = targets[index].kind
        let bytes: Int64 = await Task.detached(priority: .utility) {
            switch kind {
            case .directoryContents(let url):
                return Self.directorySize(at: url)
            case .screenshots(let url):
                return Self.directorySize(at: url)
            case .brewCleanup:
                return Self.brewCleanableBytes()
            }
        }.value
        targets[index].sizeBytes = bytes
        targets[index].isScanning = false
    }

    enum ScreenshotPolicy {
        case cancel
        case all
        case olderThan(days: Int)
    }

    func clean(index: Int) async {
        guard targets.indices.contains(index) else { return }
        let target = targets[index]

        // Screenshots: let the user choose delete-all vs prune-by-age.
        if case .screenshots(let url) = target.kind {
            let policy = await chooseScreenshotPolicy(bytes: target.sizeBytes)
            guard case let cutoffDays = policy, !isCancel(policy) else { return }
            targets[index].isCleaning = true
            targets[index].statusMessage = nil
            let cleared: Int64 = await Task.detached(priority: .utility) {
                switch cutoffDays {
                case .all: return Self.removeContents(of: url)
                case .olderThan(let days): return Self.removeContents(of: url, olderThanDays: days)
                case .cancel: return 0
                }
            }.value
            targets[index].isCleaning = false
            targets[index].lastCleaned = Date()
            totalReclaimed += cleared
            await scan(index: index)
            NotificationCenter.default.post(name: .storageChanged, object: nil)
            return
        }

        let confirmed = await confirmDelete(name: target.name, bytes: target.sizeBytes)
        guard confirmed else { return }

        targets[index].isCleaning = true
        targets[index].statusMessage = nil
        let kind = target.kind
        let priorSize = target.sizeBytes

        let result: (cleared: Int64, message: String?) = await Task.detached(priority: .utility) {
            switch kind {
            case .directoryContents(let url):
                let removed = Self.removeContents(of: url)
                return (removed, nil)
            case .screenshots(let url):
                let removed = Self.removeContents(of: url)
                return (removed, nil)
            case .brewCleanup:
                let (cleared, msg) = Self.runBrewCleanup()
                return (cleared, msg)
            }
        }.value

        targets[index].isCleaning = false
        targets[index].lastCleaned = Date()
        targets[index].statusMessage = result.message
        totalReclaimed += result.cleared
        // rescan to update size
        await scan(index: index)
        NotificationCenter.default.post(name: .storageChanged, object: nil)
        _ = priorSize
    }

    private func isCancel(_ p: ScreenshotPolicy) -> Bool {
        if case .cancel = p { return true }
        return false
    }

    private func chooseScreenshotPolicy(bytes: Int64) async -> ScreenshotPolicy {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Clean Screenshots?"
            alert.informativeText = "~/Screenshots holds \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). Choose what to delete. This cannot be undone."
            alert.alertStyle = .warning
            // Button order = return order: first..fourth.
            alert.addButton(withTitle: "Delete All")
            alert.addButton(withTitle: "Older than 30 days")
            alert.addButton(withTitle: "Older than 7 days")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  return .all
            case .alertSecondButtonReturn: return .olderThan(days: 30)
            case .alertThirdButtonReturn:  return .olderThan(days: 7)
            default:                        return .cancel
            }
        }
    }

    private func confirmDelete(name: String, bytes: Int64) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Clean \(name)?"
            alert.informativeText = "This will permanently delete approximately \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). This cannot be undone."
            alert.addButton(withTitle: "Clean")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: - Filesystem helpers

    nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                total += size
            }
        }
        return total
    }

    nonisolated static func removeContents(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let before = directorySize(at: url)
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) else {
            return 0
        }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
        let after = directorySize(at: url)
        return max(0, before - after)
    }

    /// Removes only entries whose modification date is older than `days`.
    /// Returns bytes freed.
    nonisolated static func removeContents(of url: URL, olderThanDays days: Int) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }
        let before = directorySize(at: url)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard let modified = values?.contentModificationDate else { continue }
            if modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
        let after = directorySize(at: url)
        return max(0, before - after)
    }

    // MARK: - Homebrew

    nonisolated static func brewPath() -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func brewCleanableBytes() -> Int64 {
        guard let brew = brewPath() else { return 0 }
        let output = runShell(brew, args: ["cleanup", "-n", "-s"]) ?? ""
        // Look for the summary line: "This operation would free approximately X.YMB of disk space."
        let regex = try? NSRegularExpression(pattern: "free approximately\\s+([0-9.]+)\\s*([KMGT]?B)", options: .caseInsensitive)
        if let regex = regex {
            let range = NSRange(output.startIndex..., in: output)
            if let match = regex.firstMatch(in: output, range: range),
               let numRange = Range(match.range(at: 1), in: output),
               let unitRange = Range(match.range(at: 2), in: output),
               let value = Double(output[numRange]) {
                let unit = output[unitRange].uppercased()
                let multiplier: Double = {
                    switch unit {
                    case "KB": return 1024
                    case "MB": return 1024 * 1024
                    case "GB": return 1024 * 1024 * 1024
                    case "TB": return 1024 * 1024 * 1024 * 1024
                    default: return 1
                    }
                }()
                return Int64(value * multiplier)
            }
        }
        return 0
    }

    nonisolated static func runBrewCleanup() -> (Int64, String?) {
        guard let brew = brewPath() else { return (0, "brew not found") }
        let before = brewCleanableBytes()
        _ = runShell(brew, args: ["cleanup", "-s"])
        _ = runShell(brew, args: ["autoremove"])
        let after = brewCleanableBytes()
        return (max(0, before - after), nil)
    }

    nonisolated static func runShell(_ path: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

struct ContentView: View {
    @StateObject private var storage = StorageModel()

    var body: some View {
        VStack(spacing: 0) {
            StorageOverview(model: storage)
            Divider()
            TabView {
                CleanupView()
                    .tabItem { Label("Cleanup", systemImage: "sparkles") }
                DiskUsageView()
                    .tabItem { Label("Largest Items", systemImage: "chart.pie") }
            }
        }
        .frame(minWidth: 680, minHeight: 720)
        .onChange(of: storage.celebrate) { value in
            if value > 0 { ConfettiPresenter.shared.fire() }
        }
    }
}

// MARK: - Global storage overview (shown above both tabs)

struct VolumeInfo: Identifiable {
    let id: URL
    let name: String
    let total: Int64
    let free: Int64          // true free now (volumeAvailableCapacity)
    let available: Int64     // free + purgeable (matches Finder/About)
    let isInternal: Bool
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var purgeable: Int64 { max(0, available - free) }
}

@MainActor
final class StorageModel: ObservableObject {
    @Published var volumes: [VolumeInfo] = []
    @Published var celebrate: Int = 0   // bumps when free space grows → confetti
    private var lastInternalFree: Int64 = -1

    func reload() {
        let priorFree = lastInternalFree
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard v.volumeIsBrowsable == true else { continue }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            let trueFree = Int64(v.volumeAvailableCapacity ?? 0)
            // ImportantUsage = free + purgeable; fall back to true free if absent.
            let avail = Int64(v.volumeAvailableCapacityForImportantUsage ?? Int64(trueFree))
            result.append(VolumeInfo(
                id: url,
                name: v.volumeName ?? url.lastPathComponent,
                total: total,
                free: trueFree,
                available: max(avail, trueFree),
                isInternal: v.volumeIsInternal ?? true
            ))
        }
        // Internal first, then largest capacity.
        volumes = result.sorted {
            $0.isInternal != $1.isInternal ? $0.isInternal && !$1.isInternal : $0.total > $1.total
        }

        // Celebrate when the internal volume gained free space since last reload.
        let internalFree = volumes.first(where: { $0.isInternal })?.free ?? 0
        if priorFree >= 0 && internalFree > priorFree {
            celebrate += 1
        }
        lastInternalFree = internalFree
    }
}

struct StorageOverview: View {
    @ObservedObject var model: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh storage")
            }
            if model.volumes.isEmpty {
                Text("No volumes detected").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.volumes) { vol in
                        VolumeBar(vol: vol)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .task { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .storageChanged)) { _ in
            model.reload()
        }
    }
}

// MARK: - Confetti

struct ConfettiPiece: Identifiable {
    let id = UUID()
    let xStart: CGFloat
    let xEnd: CGFloat
    let color: Color
    let size: CGFloat
    let spin: Double
    let delay: Double
    let isCircle: Bool
}

struct ConfettiPieceView: View {
    let piece: ConfettiPiece
    let fieldHeight: CGFloat
    @State private var t: CGFloat = 0

    var body: some View {
        Group {
            if piece.isCircle {
                Circle().fill(piece.color)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(piece.color)
            }
        }
        .frame(width: piece.size, height: piece.size * (piece.isCircle ? 1 : 0.5))
        .rotationEffect(.degrees(piece.spin * Double(t)))
        .opacity(1 - Double(t))
        .position(
            x: piece.xStart + (piece.xEnd - piece.xStart) * t,
            y: -12 + (fieldHeight + 40) * t
        )
        .onAppear {
            withAnimation(.easeIn(duration: 1.5).delay(piece.delay)) { t = 1 }
        }
    }
}

private let confettiPalette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]

/// Confetti that bursts once when it appears, sized to its container.
struct FullScreenConfetti: View {
    @State private var pieces: [ConfettiPiece] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    ConfettiPieceView(piece: piece, fieldHeight: geo.size.height)
                }
            }
            .onAppear { burst(width: geo.size.width) }
        }
    }

    private func burst(width: CGFloat) {
        let w = max(width, 1)
        var new: [ConfettiPiece] = []
        for _ in 0..<260 {
            let start = CGFloat.random(in: 0...w)
            new.append(ConfettiPiece(
                xStart: start,
                xEnd: start + CGFloat.random(in: -160...160),
                color: confettiPalette.randomElement() ?? .blue,
                size: CGFloat.random(in: 8...16),
                spin: Double.random(in: -720...720),
                delay: Double.random(in: 0...0.8),
                isCircle: Bool.random()
            ))
        }
        pieces = new
    }
}

/// Shows confetti over the ENTIRE screen via a borderless, transparent,
/// click-through window above all other windows.
@MainActor
final class ConfettiPresenter {
    static let shared = ConfettiPresenter()
    private var window: NSWindow?

    func fire() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }

        // Replace any in-flight burst.
        window?.orderOut(nil)

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: FullScreenConfetti())
        host.frame = NSRect(origin: .zero, size: frame.size)
        win.contentView = host
        win.setFrame(frame, display: true)
        win.orderFrontRegardless()
        window = win

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            win.orderOut(nil)
            if self.window === win { self.window = nil }
        }
    }
}

struct VolumeBar: View {
    let vol: VolumeInfo

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var barColor: Color {
        switch vol.usedFraction {
        case ..<0.75: return .green
        case ..<0.9: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: vol.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                    .foregroundStyle(.secondary)
                Text(vol.name).font(.subheadline).bold()
                    .lineLimit(1).truncationMode(.middle)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: max(2, geo.size.width * vol.usedFraction))
                }
            }
            .frame(height: 8)
            Text("\(fmt(vol.free)) free of \(fmt(vol.total))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if vol.purgeable > 0 {
                Text("\(fmt(vol.available)) available · \(fmt(vol.purgeable)) purgeable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("macOS counts free + purgeable (caches, snapshots) as available — this matches Finder/About.")
            }
            Text("\(Int(vol.usedFraction * 100))% used")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 180, maxWidth: 260)
    }
}

/// Opens System Settings → Privacy & Security → Full Disk Access directly.
struct FullDiskAccessButton: View {
    var body: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("Grant Full Disk Access", systemImage: "lock.open")
        }
        .help("Open System Settings → Privacy & Security → Full Disk Access, then add MacClean.")
    }
}

struct CleanupView: View {
    @StateObject private var model = CleanupModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                    TargetRow(target: target) {
                        Task { await model.scan(index: index) }
                    } cleanAction: {
                        Task { await model.clean(index: index) }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .task {
            await model.scanAll()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("MacClean")
                    .font(.title2).bold()
                Text("Reclaim disk space from caches, logs, and dev tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("Reclaimed this session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: model.totalReclaimed, countStyle: .file))
                    .font(.title3).monospacedDigit().bold()
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await model.scanAll() }
            } label: {
                Label("Rescan all", systemImage: "arrow.clockwise")
            }
            FullDiskAccessButton()
            Spacer()
            Text("Potential: \(ByteCountFormatter.string(fromByteCount: totalPotential, countStyle: .file))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var totalPotential: Int64 {
        model.targets.reduce(0) { $0 + $1.sizeBytes }
    }
}

struct TargetRow: View {
    let target: CleanupTarget
    let rescanAction: () -> Void
    let cleanAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline)
                Text(target.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let msg = target.statusMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let date = target.lastCleaned {
                    Text("Cleaned \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            sizeView
            Button("Clean", action: cleanAction)
                .disabled(target.isCleaning || target.isScanning || target.sizeBytes == 0)
            Button {
                rescanAction()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(target.isScanning || target.isCleaning)
        }
        .padding(.vertical, 6)
    }

    private var iconView: some View {
        Image(systemName: iconName)
            .font(.title2)
            .frame(width: 32, height: 32)
            .foregroundStyle(.tint)
    }

    private var iconName: String {
        switch target.name {
        case "User Caches": return "tray.full"
        case "User Logs": return "doc.text"
        case "Trash": return "trash"
        case "Xcode DerivedData": return "hammer"
        case "Screenshots": return "camera.viewfinder"
        case "Homebrew cleanup": return "mug"
        default: return "folder"
        }
    }

    private var sizeView: some View {
        Group {
            if target.isScanning {
                ProgressView().controlSize(.small)
            } else if target.isCleaning {
                ProgressView().controlSize(.small)
            } else {
                Text(ByteCountFormatter.string(fromByteCount: target.sizeBytes, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(target.sizeBytes > 0 ? .primary : .secondary)
            }
        }
        .frame(width: 80, alignment: .trailing)
    }
}

// MARK: - Largest Items (disk usage)

struct DiskEntry: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64
    var statusMessage: String? = nil
    var isMoving: Bool = false
    var progress: Double = 0
}

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

@MainActor
final class DiskUsageModel: ObservableObject {
    @Published var folder: URL
    @Published var entries: [DiskEntry] = []
    @Published var isScanning: Bool = false
    @Published var scannedCount: Int = 0
    @Published var destinations: [Destination] = []
    @Published var destination: Destination? = nil

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
        refreshDestinations()
    }

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }

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

    func scan() async {
        isScanning = true
        scannedCount = 0
        entries = []
        let target = folder
        let results: [DiskEntry] = await Task.detached(priority: .userInitiated) {
            Self.scanChildren(of: target)
        }.value
        entries = results
        scannedCount = results.count
        isScanning = false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            Task { await scan() }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Move one entry to the selected external volume. Confirms first; copy-then-delete
    /// fallback for cross-volume moves. Returns nothing; updates entry status / rescans.
    func moveEntry(_ entry: DiskEntry) async {
        refreshDestinations()
        guard let dest = destination else {
            setStatus(for: entry.id, "No external drive connected")
            return
        }
        // Re-verify the destination is still mounted (drive is flaky).
        guard FileManager.default.fileExists(atPath: dest.id.path) else {
            setStatus(for: entry.id, "Drive \(dest.name) unmounted")
            refreshDestinations()
            return
        }

        let confirmed = await confirmMove(name: entry.name, bytes: entry.sizeBytes, dest: dest.name)
        guard confirmed else { return }

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
            // Copy failed — leave source intact, clean up partial destination.
            try? FileManager.default.removeItem(at: target)
            endMoving(for: entry.id, status: error)
        } else {
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
        }
    }

    private func beginMoving(for id: UUID) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].isMoving = true
            entries[idx].progress = 0
            entries[idx].statusMessage = "Moving… 0%"
        }
    }

    private func setProgress(for id: UUID, _ value: Double) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            let clamped = min(max(value, 0), 1)
            entries[idx].progress = clamped
            entries[idx].statusMessage = "Moving… \(Int(clamped * 100))%"
        }
    }

    private func endMoving(for id: UUID, status: String?) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].isMoving = false
            entries[idx].progress = 0
            entries[idx].statusMessage = status
        }
    }

    private func setStatus(for id: UUID, _ message: String?) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].statusMessage = message
        }
    }

    private func confirmMove(name: String, bytes: Int64, dest: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Move \(name) to \(dest)?"
            alert.informativeText = "Moves \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) to the external drive and removes it from this Mac."
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// Recursively copies src → target in chunks, calling `report` with the
    /// running total of bytes copied (throttled). Returns nil on success or an
    /// error message. Does NOT delete the source — caller does that after this
    /// returns nil (copy verified).
    nonisolated static func copyTree(
        from src: URL,
        to target: URL,
        report: @escaping (Int64) -> Void
    ) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            return "Already exists on drive"
        }

        var copied: Int64 = 0
        var lastReported: Int64 = 0
        let reportStep: Int64 = 8 * 1024 * 1024  // emit every ~8 MB
        func bump(_ n: Int64) {
            copied += n
            if copied - lastReported >= reportStep {
                lastReported = copied
                report(copied)
            }
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
            return "Source missing"
        }

        if isDir.boolValue {
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                return "Cannot create folder on drive: \(error.localizedDescription)"
            }
            guard let enumerator = fm.enumerator(
                at: src,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else {
                return "Cannot read source folder"
            }
            for case let item as URL in enumerator {
                let rel = item.path.replacingOccurrences(of: src.path + "/", with: "")
                let dest = target.appendingPathComponent(rel)
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    if let err = copyFileChunked(from: item, to: dest, bump: bump) {
                        return err
                    }
                }
            }
        } else {
            if let err = copyFileChunked(from: src, to: target, bump: bump) {
                return err
            }
        }

        report(copied)  // final 100%
        return nil
    }

    /// Copies one file in chunks via FileHandle, calling `bump` with each
    /// chunk's byte count. FileHandle surfaces real OS errors (unlike streams).
    nonisolated static func copyFileChunked(
        from src: URL,
        to dest: URL,
        bump: (Int64) -> Void
    ) -> String? {
        let fm = FileManager.default
        let chunkSize = 4 * 1024 * 1024  // 4 MB
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let input = try FileHandle(forReadingFrom: src)
            defer { try? input.close() }
            guard fm.createFile(atPath: dest.path, contents: nil) else {
                return "Cannot create \(dest.lastPathComponent) on drive"
            }
            let output = try FileHandle(forWritingTo: dest)
            defer { try? output.close() }

            // Bypass the unified buffer cache on both ends. Without this, copying
            // large files fills RAM with dirty pages until the app is OOM-killed.
            _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
            _ = fcntl(output.fileDescriptor, F_NOCACHE, 1)

            let syncEvery: Int64 = 256 * 1024 * 1024  // flush every 256 MB
            var sinceSync: Int64 = 0
            while true {
                let data = try input.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                bump(Int64(data.count))
                sinceSync += Int64(data.count)
                if sinceSync >= syncEvery {
                    try output.synchronize()
                    sinceSync = 0
                }
            }
            try output.synchronize()
            return nil
        } catch let err as NSError {
            return "Copy failed (\(src.lastPathComponent)): \(err.localizedDescription)"
        }
    }

    /// Top-level children of a folder, each with recursive size, sorted largest first.
    nonisolated static func scanChildren(of url: URL) -> [DiskEntry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var result: [DiskEntry] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = values?.isDirectory ?? false
            let size = isDir ? CleanupModel.directorySize(at: entry) : fileSize(at: entry)
            result.append(DiskEntry(
                url: entry,
                name: entry.lastPathComponent,
                isDirectory: isDir,
                sizeBytes: size
            ))
        }
        return result.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    nonisolated static func fileSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}

struct DiskUsageView: View {
    @StateObject private var model = DiskUsageModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isScanning {
                Spacer()
                ProgressView("Scanning \(model.folder.lastPathComponent)…")
                Spacer()
            } else if model.entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Pick a folder and scan to find the biggest items.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(model.entries) { entry in
                        DiskEntryRow(
                            entry: entry,
                            total: model.totalBytes,
                            canMove: model.destination != nil,
                            destinationName: model.destination?.name,
                            revealAction: { model.reveal(entry.url) },
                            moveAction: { Task { await model.moveEntry(entry) } }
                        )
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Largest Items")
                    .font(.title2).bold()
                Text(model.folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            destinationPicker
            Button {
                model.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
            }
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .disabled(model.isScanning)
        }
        .padding()
    }

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

    private var footer: some View {
        HStack {
            Text("\(model.entries.count) items")
                .foregroundStyle(.secondary)
            FullDiskAccessButton()
            Spacer()
            Text("Total: \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct DiskEntryRow: View {
    let entry: DiskEntry
    let total: Int64
    let canMove: Bool
    let destinationName: String?
    let revealAction: () -> Void
    let moveAction: () -> Void

    private var fraction: Double {
        total > 0 ? Double(entry.sizeBytes) / Double(total) : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.isMoving {
                    ProgressView(value: entry.progress)
                        .progressViewStyle(.linear)
                        .tint(.green)
                        .frame(maxWidth: 240)
                } else {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                }
                if let msg = entry.statusMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(entry.isMoving ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Button {
                moveAction()
            } label: {
                Label("Move", systemImage: "arrow.right.circle")
            }
            .disabled(!canMove || entry.isMoving)
            .help(canMove ? "Move to \(destinationName ?? "external drive")" : "Connect an external drive first")
            Button {
                revealAction()
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 6)
    }
}
