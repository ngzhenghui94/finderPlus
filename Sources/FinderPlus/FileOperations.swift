import AppKit
import SwiftUI
import Combine
import Darwin

struct TransferJob: Identifiable {
    let id: UUID
    var title: String
    var detail: String = "Waiting"
    var progress: Double = 0
    var isPaused: Bool = false
    var isFinished: Bool = false
    var canRetry = false
    var copiedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    /// "1.2 GB of 4 GB · 85 MB/s · 32 sec left"; empty until bytes move.
    var transferStats: String {
        guard copiedBytes > 0, !isFinished else { return "" }
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        var parts = [format(copiedBytes) + (totalBytes > 0 ? " of " + format(totalBytes) : "")]
        if isPaused { parts.append("Paused") }
        else if bytesPerSecond > 0 {
            parts.append(format(Int64(bytesPerSecond)) + "/s")
            if totalBytes > copiedBytes {
                let seconds = max(1, Double(totalBytes - copiedBytes) / bytesPerSecond)
                parts.append(Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) + " left")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Total bytes of regular files under `urls`, without following symlinks.
func totalFileSize(_ urls: [URL]) -> Int64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    var total: Int64 = 0
    func add(_ url: URL) { if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) } }
    for url in urls {
        add(url)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { continue }
        for case let child as URL in walker { if Task.isCancelled { return total }; add(child) }
    }
    return total
}

/// `totalFileSize` off the main thread; cancelling the caller stops the walk.
func measuredSize(_ urls: [URL]) async -> Int64 {
    let work = Task.detached(priority: .utility) { totalFileSize(urls) }
    return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
}

/// The error text plus a plain-language next step for the failures people actually hit.
func explainFailure(_ error: Error) -> String {
    let ns = error as NSError
    func posix(_ e: NSError) -> Int32? { e.domain == NSPOSIXErrorDomain ? Int32(e.code) : (e.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap(posix) }
    let cocoa: [Int: Int32] = [NSFileReadNoPermissionError: EACCES, NSFileWriteNoPermissionError: EACCES, NSFileWriteOutOfSpaceError: ENOSPC, NSFileWriteVolumeReadOnlyError: EROFS, NSFileNoSuchFileError: ENOENT, NSFileReadNoSuchFileError: ENOENT]
    let hint: String?
    switch posix(ns) ?? (ns.domain == NSCocoaErrorDomain ? cocoa[ns.code] : nil) {
    case EACCES, EPERM: hint = "FinderPlus is not allowed to change this item. Check Sharing & Permissions in Get Info, or allow FinderPlus under System Settings › Privacy & Security, then choose Retry."
    case ENOSPC: hint = "The destination disk is full. Free up space, then choose Retry."
    case EROFS: hint = "The destination is read-only. Choose a different destination."
    case ENOENT: hint = "An item was moved, renamed or deleted while this ran. Check the folder, then choose Retry."
    default: hint = nil
    }
    return error.localizedDescription + (hint.map { " " + $0 } ?? "")
}

@MainActor
final class FileOperations: ObservableObject {
    static let shared = FileOperations()
    @Published var jobs: [TransferJob] = []
    @Published var problems: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var recoveryItems: [OperationsRecovery] = []
    private let engine: OperationsEngine
    private var requests: [UUID: OperationRequest] = [:]
    private var controls: [UUID: OperationControl] = [:]
    @Published private(set) var activeID: UUID?
    private var processing: Task<Void, Never>?
    @Published private(set) var globallyPaused = false
    private var failedRequests: [UUID: OperationRequest] = [:]
    private var rateSamples: [UUID: (time: TimeInterval, bytes: Int64)] = [:]
    private var sizeTasks: [UUID: Task<Void, Never>] = [:]
    private var confirmingHistory = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        engine = OperationsEngine(directory: support.appendingPathComponent("FinderPlus/Operations", isDirectory: true))
        Task { await refreshStatus() }
    }

    func copy(_ urls: [URL], to: URL, move: Bool = false) {
        guard !urls.isEmpty else { return }
        let normalized = normalize(urls)
        if move && CloudLocations.containsCloudItems(normalized) {
            Task {
                if await confirm(title: "Move files in cloud storage?", detail: "Moving these \(normalized.count) items to \(to.path) can remove them from their current cloud folder and your other devices. The provider controls synchronization.", action: "Move Files") {
                    enqueue(.transfer(normalized, to, true), title: "Move \(normalized.count) items")
                }
            }
        } else {
            enqueue(.transfer(normalized, to, move), title: "\(move ? "Move" : "Copy") \(normalized.count) item\(normalized.count == 1 ? "" : "s")")
        }
    }
    func duplicate(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        enqueue(.duplicate(normalize(urls)), title: "Duplicate \(urls.count) items")
    }
    func rename(_ url: URL, to name: String) { batchRename([(url, name)]) }
    func batchRename(_ changes: [(URL, String)]) {
        guard !changes.isEmpty else { return }
        enqueue(.rename(changes), title: changes.count == 1 ? "Rename \(changes[0].0.lastPathComponent)" : "Rename \(changes.count) items")
    }
    func createFolder(in parent: URL, name: String) { enqueue(.folder(parent, name), title: "Create folder \(name)") }
    func compress(_ urls: [URL], in parent: URL) {
        guard !urls.isEmpty else { return }
        enqueue(.archive(normalize(urls), parent), title: "Create ZIP archive")
    }
    func makeAlias(_ urls: [URL], in parent: URL) {
        guard !urls.isEmpty else { return }
        enqueue(.alias(normalize(urls), parent), title: "Create Finder aliases")
    }
    func synchronize(_ copies: [(source: URL, destination: URL)]) {
        guard !copies.isEmpty else { return }
        do {
            let planned = try copies.map { try OperationPlannedCopy(source: $0.source, destination: $0.destination) }
            enqueue(.synchronize(planned), title: "Synchronize \(copies.count) items")
        } catch { problems.append(error.localizedDescription) }
    }
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let names = urls.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
            let cloudWarning = CloudLocations.containsCloudItems(urls) ? "\n\nThese items are in cloud storage. Trashing them also removes them from the cloud and your other devices." : ""
            if await confirm(title: "Move \(urls.count) items to Trash?", detail: names + (urls.count > 8 ? "\n…" : "") + cloudWarning + "\n\nValidated Undo is available while the items remain in Trash. Emptying Trash makes those items unrecoverable.", action: "Move to Trash") {
                enqueue(.trash(normalize(urls)), title: "Trash \(urls.count) items")
            }
        }
    }
    func putBack(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        enqueue(.putBack(normalize(urls)), title: "Put Back \(urls.count) Trash items")
    }
    func undo() { enqueue(.undo, title: "Undo last operation") }
    func redo() { enqueue(.redo, title: "Redo operation") }
    func recover(id: UUID) {
        guard let item = recoveryItems.first(where: { $0.id == id }) else { return }
        Task {
            if await confirm(title: "Roll back interrupted operation?", detail: item.title + "\n\nOnly unchanged, fingerprint-validated items will be moved. Changed files or occupied paths stop recovery without overwriting anything. Staged data is retained.", action: "Recover") {
                enqueue(.recover(id), title: "Recover " + item.title)
            }
        }
    }
    func dismissRecovery(id: UUID) {
        guard let item = recoveryItems.first(where: { $0.id == id }) else { return }
        Task {
            if await confirm(title: "Keep current files and abandon this recovery?", detail: item.title + "\n\nNo files will be moved or deleted. Hidden staged files and journal evidence remain available for manual recovery. This transaction will no longer participate in Undo or Redo. Use this only after inspecting its current files.", action: "Keep Current Files") {
                enqueue(.abandon(id), title: "Keep current files: " + item.title)
            }
        }
    }

    private func normalize(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        return unique.filter { item in !unique.contains { other in other != item && item.path.hasPrefix(other.path + "/") } }
    }

    private func enqueue(_ request: OperationRequest, title: String) {
        let id = UUID()
        jobs.append(TransferJob(id: id, title: title, isPaused: globallyPaused))
        requests[id] = request
        controls[id] = OperationControl()
        startNext()
    }

    private func startNext() {
        isBusy = jobs.contains { !$0.isFinished }
        guard processing == nil, !globallyPaused else { return }
        guard let job = jobs.first(where: { !$0.isFinished && !$0.isPaused && requests[$0.id] != nil }), let request = requests[job.id], let control = controls[job.id] else {
            isBusy = jobs.contains { !$0.isFinished }; return
        }
        activeID = job.id
        isBusy = true
        let sources = request.copySources
        if !sources.isEmpty {
            sizeTasks[job.id] = Task {
                let total = await measuredSize(sources)
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].totalBytes = total }
            }
        }
        processing = Task {
            do {
                try await engine.execute(request, id: job.id, title: job.title, control: control, review: { [weak self] conflict in
                    guard let self else { return .cancel }
                    return await self.review(conflict)
                }, progress: { [weak self] fraction, text in
                    let bytes = await control.copiedBytes
                    await self?.update(job.id, progress: fraction, detail: text, bytes: bytes)
                })
                update(job.id, progress: 1, detail: "Completed")
            } catch is CancellationError {
                update(job.id, progress: 0, detail: "Cancelled; completed changes rolled back")
            } catch {
                let message = explainFailure(error)
                problems.append(job.title + ": " + message)
                update(job.id, progress: 0, detail: message)
                if request.isRetryable, let index = jobs.firstIndex(where: { $0.id == job.id }) { failedRequests[job.id] = request; jobs[index].canRetry = true }
            }
            rateSamples[job.id] = nil
            sizeTasks.removeValue(forKey: job.id)?.cancel()
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].isFinished = true
                jobs[index].isPaused = false
            }
            requests[job.id] = nil
            controls[job.id] = nil
            activeID = nil
            processing = nil
            NotificationCenter.default.post(name: Notification.Name("FinderPlusFilesChanged"), object: nil)
            await refreshStatus()
            startNext()
        }
    }

    private func update(_ id: UUID, progress: Double, detail: String, bytes: Int64 = 0) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = max(0, min(1, progress))
        jobs[index].detail = detail
        guard bytes > 0 else { return }
        jobs[index].copiedBytes = bytes
        // Whole-job progress instead of per-file, so multi-file copies don't restart the bar.
        if jobs[index].totalBytes > 0 { jobs[index].progress = min(0.97, Double(bytes) / Double(jobs[index].totalBytes)) }
        let now = Date.timeIntervalSinceReferenceDate
        if let last = rateSamples[id] {
            guard now - last.time >= 0.5 else { return }
            let rate = Double(bytes - last.bytes) / (now - last.time)
            jobs[index].bytesPerSecond = jobs[index].bytesPerSecond == 0 ? rate : jobs[index].bytesPerSecond * 0.7 + rate * 0.3
        }
        rateSamples[id] = (now, bytes)
    }
    func retry(_ id: UUID) {
        guard let request = failedRequests.removeValue(forKey: id), let job = jobs.first(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        enqueue(request, title: job.title)
    }
    private func refreshStatus() async {
        let status = await engine.status()
        canUndo = status.0; canRedo = status.1; recoveryItems = status.2
        if let error = status.3, !problems.contains(error) { problems.append(error) }
    }
    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else { return }
        jobs[index].isPaused.toggle()
        let value = jobs[index].isPaused
        rateSamples[id] = nil; jobs[index].bytesPerSecond = 0
        if let control = controls[id] { Task { await control.setPaused(value) } }
        startNext()
    }
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else { return }
        if activeID == id {
            jobs[index].detail = "Cancelling and rolling back…"
            if let control = controls[id] { Task { await control.cancel() } }
        } else {
            requests[id] = nil; controls[id] = nil
            jobs[index].isFinished = true; jobs[index].isPaused = false; jobs[index].detail = "Cancelled before starting"
            isBusy = jobs.contains { !$0.isFinished }
        }
    }
    func reorder(_ id: UUID, offset: Int) {
        guard id != activeID, let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else { return }
        let pending = jobs.indices.filter { !jobs[$0].isFinished && jobs[$0].id != activeID }
        guard let position = pending.firstIndex(of: index) else { return }
        let target = max(0, min(pending.count - 1, position + offset))
        guard target != position else { return }
        let job = jobs.remove(at: index)
        jobs.insert(job, at: pending[target])
    }
    func pauseAll() {
        globallyPaused = true
        for index in jobs.indices where !jobs[index].isFinished { jobs[index].isPaused = true }
        let controls = Array(controls.values)
        Task { for control in controls { await control.setPaused(true) } }
    }
    func resumeAll() {
        globallyPaused = false
        for index in jobs.indices where !jobs[index].isFinished { jobs[index].isPaused = false }
        let controls = Array(controls.values)
        Task { for control in controls { await control.setPaused(false) }; startNext() }
    }
    func clearHistory() {
        guard !confirmingHistory else { return }
        guard !isBusy, recoveryItems.isEmpty else {
            problems.append("Finish or cancel queued work and resolve interrupted operations before clearing file history.")
            return
        }
        confirmingHistory = true
        Task {
            defer { confirmingHistory = false }
            do {
                let scope = try await engine.historyScope()
                let detail = "Permanently forget \(scope.recordCount) recorded operations, including all app Undo, Redo, and Put Back records?\n\nOnly the \(scope.paths.count) registered hidden storage folders listed below will be moved to system Trash, after ownership and content verification. Current user files and existing Trash contents stay untouched. System Trash will not be emptied. There is no automatic way to restore the discarded app history."
                guard await confirm(title: "Clear File Operation History?", detail: detail, action: "Clear History and Trash Storage", paths: scope.paths) else { return }
                guard !isBusy, recoveryItems.isEmpty else {
                    problems.append("The queue changed during confirmation. Finish its work before clearing history.")
                    return
                }
                enqueue(.clearHistory(scope), title: "Clear File Operation History")
            } catch { problems.append(error.localizedDescription) }
        }
    }

    func clearFinished() { jobs.removeAll { $0.isFinished }; failedRequests = failedRequests.filter { id, _ in jobs.contains { $0.id == id } } }
    func clearProblems() { problems.removeAll() }
    func revealRecoveryStorage() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        NSWorkspace.shared.open(support.appendingPathComponent("FinderPlus/Operations"))
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response) }
            }
        }
        return alert.runModal()
    }
    private func confirm(title: String, detail: String, action: String, paths: [String] = []) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        if !paths.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.string = paths.joined(separator: "\n")
            text.isEditable = false
            text.isSelectable = true
            text.isHorizontallyResizable = false
            text.isVerticallyResizable = true
            text.autoresizingMask = .width
            text.maxSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        return await present(alert) == .alertFirstButtonReturn
    }
    private func review(_ conflict: OperationConflict) async -> ConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(conflict.destination.lastPathComponent)” already exists in “\(conflict.destination.deletingLastPathComponent().lastPathComponent)”"
        alert.informativeText = "Keep Both adds the incoming item with a new name. Nothing is replaced unless you choose Replace." + (conflict.canMerge ? "\n\n" + conflict.preview : "")
        let comparison = NSHostingView(rootView: ConflictComparison(existing: conflict.destination, incoming: conflict.source))
        comparison.frame.size = comparison.fittingSize
        alert.accessoryView = comparison
        var options: [ConflictChoice] = [.keepBoth, .skip, .replace]
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Replace…")
        if conflict.canMerge { alert.addButton(withTitle: "Merge"); options.append(.merge) }
        alert.addButton(withTitle: "Stop"); options.append(.cancel)
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let response = await present(alert)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard options.indices.contains(index) else { return .cancel }
        let choice = options[index]
        if case .replace = choice {
            return await confirm(title: "Replace this item?", detail: conflict.preview + "\n\nThe existing destination will be removed from its current location and retained in hidden undo storage. Continue?", action: "Replace") ? .replace : .cancel
        }
        return choice
    }

    static func selfCheck() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FinderPlus-operations-check-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("sample.txt")
        try Data("fixture contents".utf8).write(to: file)
        let engine = OperationsEngine(directory: root.appendingPathComponent("journal"))
        let keep: OperationsEngine.Review = { _ in .keepBoth }
        let progress: OperationsEngine.Progress = { _, _ in }
        func run(_ request: OperationRequest) async throws {
            try await engine.execute(request, id: UUID(), title: "Temporary fixture", control: OperationControl(), review: keep, progress: progress)
        }
        func require(_ condition: Bool, _ description: String) throws {
            guard condition else { throw OperationFailure.message("Operations self-check: " + description) }
        }
        let attribute = Data("preserve user metadata".utf8)
        let attributeWritten = attribute.withUnsafeBytes { setxattr(file.path, "com.finderplus.fixture", $0.baseAddress, attribute.count, 0, 0) }
        try require(attributeWritten == 0, "create extended-attribute fixture")
        try await run(.transfer([file], destination, false))
        let copied = destination.appendingPathComponent("sample.txt")
        try require(try Data(contentsOf: copied) == Data(contentsOf: file), "copy contents")
        var copiedAttribute = Data(count: attribute.count)
        let attributeRead = copiedAttribute.withUnsafeMutableBytes { getxattr(copied.path, "com.finderplus.fixture", $0.baseAddress, attribute.count, 0, 0) }
        try require(attributeRead == attribute.count && copiedAttribute == attribute, "copy preserves user extended attributes")
        try await run(.undo)
        try require(!fm.fileExists(atPath: copied.path), "undo removes installed copy")
        try await run(.redo)
        try require(fm.fileExists(atPath: copied.path), "redo restores copy")
        try await run(.transfer([file], destination, false))
        try require(fm.fileExists(atPath: destination.appendingPathComponent("sample copy.txt").path), "keep both")
        try await run(.rename([(file, "renamed.txt")]))
        let renamed = source.appendingPathComponent("renamed.txt")
        try require(fm.fileExists(atPath: renamed.path), "rename")
        try await run(.undo)
        try require(fm.fileExists(atPath: file.path), "rename undo")
        try await run(.folder(destination, "Created"))
        let created = destination.appendingPathComponent("Created")
        try require(try created.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true, "new folder is a real directory")
        for name in ["Created", "sample.txt", "", "../escaped", "nested/name"] {
            var rejected = false
            do { try await run(.folder(destination, name)) } catch { rejected = true }
            try require(rejected, "folder creation rejects occupied or invalid name: \(name)")
        }
        try require(try Data(contentsOf: copied) == Data(contentsOf: file), "folder creation never replaces an existing file")
        try require(!fm.fileExists(atPath: root.appendingPathComponent("escaped").path), "folder name cannot escape its parent")
        try await run(.undo)
        try require(!fm.fileExists(atPath: destination.appendingPathComponent("Created").path), "folder undo")
        let nested = destination.appendingPathComponent("new/child/sample.txt")
        try await run(.synchronize([try OperationPlannedCopy(source: file, destination: nested)]))
        try require(try Data(contentsOf: nested) == Data(contentsOf: file), "sync creates missing parents")
        try await run(.undo)
        try require(!fm.fileExists(atPath: destination.appendingPathComponent("new").path), "sync parent undo")
        let moveDestination = root.appendingPathComponent("moved")
        try fm.createDirectory(at: moveDestination, withIntermediateDirectories: false)
        func heldCopies() throws -> Int { try fm.contentsOfDirectory(atPath: source.path).filter { $0.hasPrefix(".FinderPlus-") }.count }
        let heldBefore = try heldCopies()
        try await run(.transfer([file], moveDestination, true))
        try require(!fm.fileExists(atPath: file.path) && fm.fileExists(atPath: moveDestination.appendingPathComponent(file.lastPathComponent).path), "move removes source")
        try require(try heldCopies() == heldBefore, "same-disk move is a rename that keeps no hidden copy")
        try await run(.undo)
        try require(fm.fileExists(atPath: file.path), "move undo restores source")
        let besideCopy = source.appendingPathComponent("sample copy.txt")
        try await run(.transfer([file], source, false))
        try require(try Data(contentsOf: besideCopy) == Data(contentsOf: file), "paste into the same folder makes a copy beside it")
        try await run(.undo)
        try require(!fm.fileExists(atPath: besideCopy.path), "undo of a same-folder paste")
        try await run(.transfer([file], source, true))
        try require(fm.fileExists(atPath: file.path), "moving an item into its own folder changes nothing")
        if let volume = try? ramDisk() {
            defer { volume.detach() }
            let crossFile = source.appendingPathComponent("cross.txt")
            try Data("cross-disk fixture".utf8).write(to: crossFile)
            let heldCross = try heldCopies()
            try await run(.transfer([crossFile], volume.url, true))
            try require(!fm.fileExists(atPath: crossFile.path) && (try? Data(contentsOf: volume.url.appendingPathComponent("cross.txt"))) == Data("cross-disk fixture".utf8), "cross-disk move")
            try require(try heldCopies() == heldCross, "cross-disk move sends the original to the Trash, not hidden storage")
            try await run(.undo)
            try require(fm.fileExists(atPath: crossFile.path) && !fm.fileExists(atPath: volume.url.appendingPathComponent("cross.txt").path), "cross-disk move undo restores the original from the Trash")
            print("Operations: cross-disk move via RAM disk PASS")
        } else { print("Operations: cross-disk move skipped (could not create a RAM disk)") }
        let replacement = root.appendingPathComponent("replacement")
        try fm.createDirectory(at: replacement, withIntermediateDirectories: false)
        let old = replacement.appendingPathComponent(file.lastPathComponent)
        try Data("old contents".utf8).write(to: old)
        try await engine.execute(.transfer([file], replacement, false), id: UUID(), title: "Replace fixture", control: OperationControl(), review: { _ in .replace }, progress: progress)
        try require(try Data(contentsOf: old) == Data(contentsOf: file), "replace installs copy")
        try await run(.undo)
        try require(try Data(contentsOf: old) == Data("old contents".utf8), "replace undo restores original destination")
        let mergeSource = root.appendingPathComponent("mergeSource")
        let mergeTarget = root.appendingPathComponent("mergeTarget")
        try fm.createDirectory(at: mergeSource, withIntermediateDirectories: false)
        try fm.createDirectory(at: mergeTarget, withIntermediateDirectories: false)
        try Data("merge".utf8).write(to: mergeSource.appendingPathComponent("incoming"))
        try Data("keep".utf8).write(to: mergeTarget.appendingPathComponent("existing"))
        try await engine.execute(.synchronize([try OperationPlannedCopy(source: mergeSource, destination: mergeTarget)]), id: UUID(), title: "Merge fixture", control: OperationControl(), review: { _ in .merge }, progress: progress)
        try require(fm.fileExists(atPath: mergeTarget.appendingPathComponent("incoming").path) && fm.fileExists(atPath: mergeTarget.appendingPathComponent("existing").path), "merge keeps unmatched items")
        try await run(.undo)
        try require(!fm.fileExists(atPath: mergeTarget.appendingPathComponent("incoming").path), "merge undo")
        let moveMergeRoot = root.appendingPathComponent("merge-move")
        let moveMergeTarget = moveMergeRoot.appendingPathComponent(mergeSource.lastPathComponent)
        try fm.createDirectory(at: moveMergeTarget, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: moveMergeTarget.appendingPathComponent("existing"))
        try await engine.execute(.transfer([mergeSource], moveMergeRoot, true), id: UUID(), title: "Move merge fixture", control: OperationControl(), review: { _ in .merge }, progress: progress)
        try require(!fm.fileExists(atPath: mergeSource.path), "move merge removes empty source")
        try await run(.undo)
        try require(fm.fileExists(atPath: mergeSource.appendingPathComponent("incoming").path), "move merge undo restores source tree")
        let cancelled = OperationControl()
        await cancelled.cancel()
        do {
            try await engine.execute(.transfer([file], destination, false), id: UUID(), title: "Cancel fixture", control: cancelled, review: keep, progress: progress)
            throw OperationFailure.message("Operations self-check: cancelled transfer succeeded")
        } catch is CancellationError {}
        try await run(.alias([file], destination))
        let alias = destination.appendingPathComponent("sample.txt alias")
        let bookmark = try URL.bookmarkData(withContentsOf: alias)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        try require(resolved.resolvingSymlinksInPath() == file.resolvingSymlinksInPath(), "Finder alias target")
        try await run(.archive([file], destination))
        let archive = destination.appendingPathComponent("sample.txt.zip")
        try require(try Data(contentsOf: archive).prefix(2) == Data([0x50, 0x4b]), "ZIP output")
        let journalURL = root.appendingPathComponent("journal/operations.json")
        var interrupted = try JSONDecoder().decode(OperationJournal.self, from: Data(contentsOf: journalURL))
        let last = interrupted.records.count - 1
        interrupted.records[last].state = "working"
        let interruptedID = interrupted.records[last].id
        try JSONEncoder().encode(interrupted).write(to: journalURL, options: .atomic)
        let restarted = OperationsEngine(directory: root.appendingPathComponent("journal"))
        try await restarted.execute(.recover(interruptedID), id: UUID(), title: "Recovery fixture", control: OperationControl(), review: keep, progress: progress)
        try require(!fm.fileExists(atPath: archive.path), "interrupted transaction rollback after journal reload")
        let validationEngine = OperationsEngine(directory: root.appendingPathComponent("validation-journal"))
        let validationTarget = root.appendingPathComponent("validation-target")
        try fm.createDirectory(at: validationTarget, withIntermediateDirectories: false)
        try await validationEngine.execute(.transfer([file], validationTarget, false), id: UUID(), title: "Validation fixture", control: OperationControl(), review: keep, progress: progress)
        let edited = validationTarget.appendingPathComponent(file.lastPathComponent)
        try Data("user edit".utf8).write(to: edited)
        var refused = false
        do { try await validationEngine.execute(.undo, id: UUID(), title: "Refuse changed fixture", control: OperationControl(), review: keep, progress: progress) }
        catch { refused = true }
        let editedContents = try Data(contentsOf: edited)
        try require(refused && editedContents == Data("user edit".utf8), "undo protects edited files")
        let failedStatus = await validationEngine.status()
        guard let recovery = failedStatus.2.first else { throw OperationFailure.message("Operations self-check: missing failed Undo recovery") }
        try await validationEngine.execute(.abandon(recovery.id), id: UUID(), title: "Keep edited fixture", control: OperationControl(), review: keep, progress: progress)
        let keptStatus = await validationEngine.status()
        try require(keptStatus.2.isEmpty, "explicitly retaining edited data clears recovery blocker")
        let staleSource = root.appendingPathComponent("stale-source")
        let staleTarget = root.appendingPathComponent("stale-target")
        try Data("before".utf8).write(to: staleSource)
        let plan = try OperationPlannedCopy(source: staleSource, destination: staleTarget)
        try Data("changed after review".utf8).write(to: staleSource)
        var staleRefused = false
        do { try plan.validate() } catch { staleRefused = true }
        try require(staleRefused && !fm.fileExists(atPath: staleTarget.path), "sync detects changed reviewed source")
        let restoreRoot = root.appendingPathComponent("simulated-trash")
        try fm.createDirectory(at: restoreRoot, withIntermediateDirectories: false)
        let original = restoreRoot.appendingPathComponent("original")
        let parked = restoreRoot.appendingPathComponent("parked")
        try Data("restore fixture".utf8).write(to: original)
        let restoreJournal = root.appendingPathComponent("restore-journal")
        let restoreEngine = OperationsEngine(directory: restoreJournal)
        try await restoreEngine.execute(.rename([(original, "parked")]), id: UUID(), title: "Temporary simulated Trash ledger", control: OperationControl(), review: keep, progress: progress)
        let restoreJournalFile = restoreJournal.appendingPathComponent("operations.json")
        var restoreLedger = try JSONDecoder().decode(OperationJournal.self, from: Data(contentsOf: restoreJournalFile))
        // Exercise selected Put Back without touching the system Trash.
        restoreLedger.records[0].moves[0].trashBookmark = Data([1])
        try JSONEncoder().encode(restoreLedger).write(to: restoreJournalFile, options: .atomic)
        try await restoreEngine.execute(.putBack([parked]), id: UUID(), title: "Put Back fixture", control: OperationControl(), review: keep, progress: progress)
        try require(fm.fileExists(atPath: original.path) && !fm.fileExists(atPath: parked.path), "selected Put Back")
        let emptyEngine = OperationsEngine(directory: root.appendingPathComponent("empty-history"))
        let emptyScope = try await emptyEngine.historyScope()
        try await emptyEngine.execute(.clearHistory(emptyScope), id: UUID(), title: "Clear empty fixture history", control: OperationControl(), review: keep, progress: progress)
        let emptyStatus = await emptyEngine.status()
        try require(!emptyStatus.0 && !emptyStatus.1 && emptyStatus.2.isEmpty, "clear empty history")
        let storageLedgerData = try Data(contentsOf: journalURL)
        let storageLedger = try JSONDecoder().decode(OperationJournal.self, from: storageLedgerData)
        guard let storage = storageLedger.storage?.first(where: { $0.trashedAt == nil && fm.fileExists(atPath: $0.path) }) else {
            throw OperationFailure.message("Operations self-check: missing retained fixture storage")
        }
        let storageURL = URL(fileURLWithPath: storage.path)
        let unrelated = storageURL.appendingPathComponent("unrelated-fixture")
        try Data("must remain untouched".utf8).write(to: unrelated)
        let alteredScope = try await engine.historyScope()
        var cleanupRefused = false
        do { try await engine.execute(.clearHistory(alteredScope), id: UUID(), title: "Reject altered history fixture", control: OperationControl(), review: keep, progress: progress) }
        catch { cleanupRefused = error.localizedDescription.contains("changed or unverified") }
        let journalAfterRefusal = try Data(contentsOf: journalURL)
        try require(cleanupRefused && fm.fileExists(atPath: unrelated.path) && journalAfterRefusal == storageLedgerData, "clear history preserves unrelated changes and journal")
        try fm.removeItem(at: unrelated)
        let savedStorage = root.appendingPathComponent("saved-storage-" + UUID().uuidString)
        try fm.moveItem(at: storageURL, to: savedStorage)
        try fm.createSymbolicLink(at: storageURL, withDestinationURL: savedStorage)
        let linkedScope = try await engine.historyScope()
        var linkRefused = false
        do { try await engine.execute(.clearHistory(linkedScope), id: UUID(), title: "Reject symlink history fixture", control: OperationControl(), review: keep, progress: progress) }
        catch { linkRefused = error.localizedDescription.contains("symbolic link") }
        let journalAfterLink = try Data(contentsOf: journalURL)
        try require(linkRefused && fm.fileExists(atPath: savedStorage.path) && journalAfterLink == storageLedgerData, "clear history refuses substituted symbolic links")
        try fm.removeItem(at: storageURL)
        try fm.moveItem(at: savedStorage, to: storageURL)
        let cleanupParent = root.appendingPathComponent("cleanup-parent")
        try fm.createDirectory(at: cleanupParent, withIntermediateDirectories: false)
        let cleanupJournal = root.appendingPathComponent("cleanup-journal")
        let cleanupEngine = OperationsEngine(directory: cleanupJournal)
        try await cleanupEngine.execute(.folder(cleanupParent, "visible"), id: UUID(), title: "Cleanup recovery fixture", control: OperationControl(), review: keep, progress: progress)
        let cleanupJournalFile = cleanupJournal.appendingPathComponent("operations.json")
        var cleanupLedger = try JSONDecoder().decode(OperationJournal.self, from: Data(contentsOf: cleanupJournalFile))
        guard let cleanupRoot = cleanupLedger.storage?.first else { throw OperationFailure.message("Operations self-check: missing cleanup storage") }
        let cleanupURL = URL(fileURLWithPath: cleanupRoot.path)
        cleanupLedger.storage![0].pendingTrash = try cleanupURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        cleanupLedger.clearingHistory = true
        try JSONEncoder().encode(cleanupLedger).write(to: cleanupJournalFile, options: .atomic)
        // Simulate an interrupted Trash move entirely inside the temporary fixture.
        let simulatedTrash = root.appendingPathComponent("simulated-history-trash")
        try fm.moveItem(at: cleanupURL, to: simulatedTrash)
        let retryScope = try await cleanupEngine.historyScope()
        try await cleanupEngine.execute(.clearHistory(retryScope), id: UUID(), title: "Retry cleanup fixture", control: OperationControl(), review: keep, progress: progress)
        let clearedLedger = try JSONDecoder().decode(OperationJournal.self, from: Data(contentsOf: cleanupJournalFile))
        try require(clearedLedger.records.isEmpty && (clearedLedger.storage ?? []).isEmpty &&
                    fm.fileExists(atPath: cleanupParent.appendingPathComponent("visible").path) &&
                    fm.fileExists(atPath: simulatedTrash.path), "cleanup recovery clears history without moving current files")
        // A crash leaves a step marked pending; recovery must find out on disk whether its move happened.
        for movedBeforeCrash in [true, false] {
            let folder = root.appendingPathComponent("pending-\(movedBeforeCrash)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            let before = folder.appendingPathComponent("before"), after = folder.appendingPathComponent("after")
            try Data("pending fixture".utf8).write(to: before)
            let pendingJournal = root.appendingPathComponent("pending-journal-\(movedBeforeCrash)")
            try await OperationsEngine(directory: pendingJournal).execute(.rename([(before, "after")]), id: UUID(), title: "Pending fixture", control: OperationControl(), review: keep, progress: progress)
            if !movedBeforeCrash { try fm.moveItem(at: after, to: before) }
            let pendingFile = pendingJournal.appendingPathComponent("operations.json")
            var crashed = try JSONDecoder().decode(OperationJournal.self, from: Data(contentsOf: pendingFile))
            crashed.records[0].state = "working"
            crashed.records[0].pending = 0
            crashed.records[0].pendingForward = true
            crashed.records[0].moves[0].applied = false
            try JSONEncoder().encode(crashed).write(to: pendingFile, options: .atomic)
            try await OperationsEngine(directory: pendingJournal).execute(.recover(crashed.records[0].id), id: UUID(), title: "Recover pending fixture", control: OperationControl(), review: keep, progress: progress)
            try require(fm.fileExists(atPath: before.path) && !fm.fileExists(atPath: after.path), "recovery of a pending step (moved before crash: \(movedBeforeCrash))")
        }
        // The journal log is replayed after a crash: a matching header, one change, then a torn last line.
        let logFolder = root.appendingPathComponent("pending-journal-true")
        let snapshotData = try Data(contentsOf: logFolder.appendingPathComponent("operations.json"))
        let base = try JSONDecoder().decode(OperationJournal.self, from: snapshotData)
        var changed = base
        changed.records[0].title = "Renamed fixture"
        changed.records[0].moves.append(changed.records[0].moves[0])
        changed.records.append(OperationRecord(id: UUID(), title: "Logged fixture", state: "cancelled"))
        let patch = JournalPatch(from: base, to: changed)
        var replayed = base
        try JSONDecoder().decode(JournalPatch.self, from: JSONEncoder().encode(patch)).apply(to: &replayed)
        var log = try JSONEncoder().encode(OperationsEngine.digest(snapshotData)) + [0x0A]
        log += try JSONEncoder().encode(patch) + [0x0A] + Data("{\"torn".utf8)
        try log.write(to: logFolder.appendingPathComponent("operations.log"))
        let replayedScope = try await OperationsEngine(directory: logFolder).historyScope()
        try require(replayed == changed && replayedScope.recordCount == changed.records.count, "journal log replays after a crash and ignores a torn line")
        // A rewritten snapshot (as after compaction) makes the old log stale; replaying it would apply changes twice.
        try JSONEncoder().encode(base).write(to: logFolder.appendingPathComponent("operations.json"), options: .atomic)
        let staleScope = try await OperationsEngine(directory: logFolder).historyScope()
        try require(staleScope.recordCount == base.records.count, "a log for an older snapshot is ignored")
        let tornLog = root.appendingPathComponent("torn.log")
        try Data("\"head\"\n{\"a\":1}\n{\"to".utf8).write(to: tornLog)
        OperationsEngine.trimTornTail(tornLog)
        try require(try Data(contentsOf: tornLog) == Data("\"head\"\n{\"a\":1}\n".utf8), "a torn log line is cut before the next append")
    }
    /// A throwaway APFS RAM disk, so moves between disks are checked for real.
    private static func ramDisk() throws -> (url: URL, detach: () -> Void) {
        func run(_ tool: String, _ arguments: [String]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
            process.standardOutput = output; process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw OperationFailure.message("\(tool) failed") }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        guard let device = try run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://65536"]).split(whereSeparator: \.isWhitespace).first.map(String.init) else { throw OperationFailure.message("No RAM disk") }
        let detach = { _ = try? run("/usr/bin/hdiutil", ["detach", device, "-force"]) }
        let name = "FinderPlusCheck-" + UUID().uuidString.prefix(8)
        do { _ = try run("/usr/sbin/diskutil", ["erasevolume", "APFS", name, device]) } catch { detach(); throw error }
        return (URL(fileURLWithPath: "/Volumes/" + name), detach)
    }
}

struct OperationsPanel: View {
    @ObservedObject private var operations = FileOperations.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Operations", systemImage: "arrow.left.arrow.right")
                    .font(.title2.bold())
                Spacer()
                Button("Undo") { operations.undo() }.disabled(!operations.canUndo || operations.isBusy)
                Button("Redo") { operations.redo() }.disabled(!operations.canRedo || operations.isBusy)
                Button(operations.globallyPaused ? "Resume All" : "Pause All") { if operations.globallyPaused { operations.resumeAll() } else { operations.pauseAll() } }
                    .disabled(!operations.isBusy && !operations.globallyPaused)
            }
            if !operations.recoveryItems.isEmpty {
                GroupBox("Interrupted operations — recovery required") {
                    ForEach(operations.recoveryItems) { item in
                        HStack {
                            VStack(alignment: .leading) { Text(item.title).bold(); Text(item.detail).font(.caption).textSelection(.enabled) }
                            Spacer()
                            Button("Recover…") { operations.recover(id: item.id) }.disabled(operations.isBusy)
                            Button("Keep Current Files…") { operations.dismissRecovery(id: item.id) }.disabled(operations.isBusy)
                        }.padding(4)
                    }
                }
            }
            if operations.jobs.isEmpty {
                ContentUnavailableView("No File Operations", systemImage: "arrow.left.arrow.right", description: Text("Copies, moves, renames and other changes appear here with progress, speed and time left."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List {
                ForEach(operations.jobs) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(job.title).bold()
                            if job.isPaused { Text("Paused").foregroundStyle(.secondary) }
                            Spacer()
                            if !job.isFinished {
                                if job.id != operations.activeID {
                                    Button { operations.reorder(job.id, offset: -1) } label: { Image(systemName: "arrow.up") }.help("Move earlier in waiting queue")
                                    Button { operations.reorder(job.id, offset: 1) } label: { Image(systemName: "arrow.down") }.help("Move later in waiting queue")
                                }
                                Button(job.isPaused ? "Resume" : "Pause") { operations.pause(job.id) }
                                Button("Cancel") { operations.cancel(job.id) }
                            }
                        }
                        ProgressView(value: job.progress)
                        HStack(alignment: .firstTextBaseline) {
                            Text(job.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            if !job.transferStats.isEmpty { Text(job.transferStats).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            if job.canRetry { Button("Retry") { operations.retry(job.id) }.controlSize(.small) }
                        }
                    }.padding(.vertical, 5)
                }
            }
            }
            if !operations.problems.isEmpty {
                GroupBox("Problems") {
                    ScrollView { VStack(alignment: .leading, spacing: 5) { ForEach(Array(operations.problems.enumerated()), id: \.offset) { _, problem in Text(problem).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    Button("Clear messages") { operations.clearProblems() }
                }
            }
            DisclosureGroup("How verification, Undo and recovery storage work") {
            Text("Moves within one disk are instant renames. Copies and moves between disks are staged and fingerprint-verified before commit; a moved original then goes to the Trash, where Undo can restore it. Undo data is retained in hidden .FinderPlus folders beside affected items; these consume disk space and are never automatically purged. Do not delete them while you need Undo. Folders containing retained storage cannot be moved or renamed. Changed files are never overwritten by Undo or recovery. Trash recovery requires the item to remain in Trash. ZIP creation pauses between process slices; rollback and network/provider calls may finish before pausing.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Clear File Operation History releases retained storage to system Trash after verification and removes the folder-movement restriction. All app Undo, Redo, and Put Back records are lost. Modified or unverified storage is left untouched.")
                .font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            HStack {
                Button("Clear finished") { operations.clearFinished() }
                Button("Show journal") { operations.revealRecoveryStorage() }
                Button("Clear File Operation History…") { operations.clearHistory() }
                    .disabled(operations.isBusy || !operations.recoveryItems.isEmpty)
                Spacer()
                Text(operations.isBusy ? "Queue active" : "Ready").foregroundStyle(.secondary)
            }
        }.padding(18).frame(minWidth: 680, minHeight: 440)
    }
}

/// Side-by-side view of the two versions in a name conflict, with the newer one marked.
struct ConflictComparison: View {
    let existing: URL
    let incoming: URL
    var body: some View {
        let old = Version(existing), new = Version(incoming)
        HStack(alignment: .top, spacing: 12) {
            card("Existing", old, newer: old.modified > new.modified)
            Image(systemName: "arrow.left").foregroundStyle(.secondary).padding(.top, 34)
            card("Incoming", new, newer: new.modified > old.modified)
        }.frame(width: 400).padding(.vertical, 4)
    }
    struct Version {
        let url: URL, detail: String, modified: Date
        init(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
            self.url = url
            modified = values?.contentModificationDate ?? .distantPast
            detail = values?.isDirectory == true ? (values?.localizedTypeDescription ?? "Folder") : ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        }
    }
    func card(_ title: String, _ version: Version, newer: Bool) -> some View {
        VStack(spacing: 4) {
            FileIcon(url: version.url, size: 52)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(version.detail).font(.caption)
            Text(version.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Text("Newer").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor.opacity(0.2), in: Capsule()).opacity(newer ? 1 : 0)
        }.frame(maxWidth: .infinity).padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
