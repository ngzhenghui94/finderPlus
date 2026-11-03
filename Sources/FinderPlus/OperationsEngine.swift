import Foundation
import CryptoKit
import Darwin

enum OperationFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ConflictChoice: Sendable { case keepBoth, skip, replace, merge, cancel }
struct OperationConflict: Sendable {
    let source: URL
    let destination: URL
    let canMerge: Bool
    let preview: String
}
struct OperationsRecovery: Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String
}

actor OperationControl {
    private var paused = false
    private var cancelled = false
    private(set) var copiedBytes: Int64 = 0
    func addCopied(_ count: Int) { copiedBytes += Int64(count) }
    func setPaused(_ value: Bool) { paused = value }
    func cancel() { cancelled = true; paused = false }
    func checkpoint() async throws {
        while paused && !cancelled { try await Task.sleep(nanoseconds: 100_000_000) }
        if cancelled || Task.isCancelled { throw CancellationError() }
    }
}

struct OperationMove: Codable {
    var from: String
    var to: String
    var signature: String
    var applied: Bool = false
    var trashBookmark: Data? = nil
    var fromParent: String
    var toParent: String
}
struct OperationRecord: Codable {
    var id: UUID
    var title: String
    var state: String = "working"
    var moves: [OperationMove] = []
    var pending: Int? = nil
    var pendingForward: Bool = true
    var artifacts: [String] = []
    var error: String? = nil
}
struct OperationStorage: Codable {
    var path: String
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    var parent: String
    var signature: String?
    var pendingTrash: Data?
    var trashedAt: String?
}

struct OperationJournal: Codable {
    var version = 1
    var records: [OperationRecord] = []
    var storage: [OperationStorage]?
    var clearingHistory: Bool?
}

struct OperationHistoryScope: Sendable {
    let revision: String
    let paths: [String]
    let recordCount: Int
}

struct OperationSnapshot: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let size: UInt64
    let modified: Double
    let type: String

    static func capture(_ url: URL) throws -> OperationSnapshot? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return OperationSnapshot(device: (attrs[.systemNumber] as? UInt64) ?? 0,
                                     inode: (attrs[.systemFileNumber] as? UInt64) ?? 0,
                                     owner: (attrs[.ownerAccountID] as? UInt32) ?? UInt32.max,
                                     size: (attrs[.size] as? UInt64) ?? 0,
                                     modified: (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
                                     type: (attrs[.type] as? FileAttributeType)?.rawValue ?? "")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
    }
}

struct OperationPlannedCopy: Sendable {
    let source: URL
    let destination: URL
    let sourceSnapshot: OperationSnapshot
    let destinationSnapshot: OperationSnapshot?
    init(source: URL, destination: URL) throws {
        guard let snapshot = try OperationSnapshot.capture(source) else { throw OperationFailure.message("Sync source no longer exists: \(source.path)") }
        self.source = source; self.destination = destination
        sourceSnapshot = snapshot
        destinationSnapshot = try OperationSnapshot.capture(destination)
    }
    func validate() throws {
        guard try OperationSnapshot.capture(source) == sourceSnapshot,
              try OperationSnapshot.capture(destination) == destinationSnapshot else {
            throw OperationFailure.message("A synchronization item changed after review. Refresh the comparison before trying again: \(destination.path)")
        }
    }
}

enum OperationRequest: Sendable {
    case transfer([URL], URL, Bool)
    case duplicate([URL])
    case rename([(URL, String)])
    case folder(URL, String)
    case trash([URL])
    case putBack([URL])
    case archive([URL], URL)
    case alias([URL], URL)
    case synchronize([OperationPlannedCopy])
    case undo, redo, recover(UUID), abandon(UUID), clearHistory(OperationHistoryScope)
    /// History and recovery actions are re-run from their own buttons instead.
    var isRetryable: Bool { switch self { case .undo, .redo, .recover, .abandon, .clearHistory: return false; default: return true } }
    var copySources: [URL] {
        switch self {
        case .transfer(let urls, _, _), .duplicate(let urls): return urls
        case .synchronize(let copies): return copies.map(\.source)
        default: return []
        }
    }
}

actor OperationsEngine {
    typealias Review = @Sendable (OperationConflict) async -> ConflictChoice
    typealias Progress = @Sendable (Double, String) async -> Void
    private let fm = FileManager.default
    private let journalURL: URL
    private var journal = OperationJournal()
    private var ownedArtifactNames: Set<String> = []
    private var loadError: String?

    init(directory: URL) {
        journalURL = directory.appendingPathComponent("operations.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            journal = try Self.readJournal(journalURL)
            ownedArtifactNames = Set(journal.records.flatMap(\.artifacts).map { URL(fileURLWithPath: $0).lastPathComponent })
        } catch { loadError = "Operations journal unavailable: \(error.localizedDescription)" }
    }

    private static func readJournal(_ url: URL) throws -> OperationJournal {
        guard try OperationSnapshot.capture(url) != nil else { return OperationJournal() }
        let loaded = try JSONDecoder().decode(OperationJournal.self, from: Data(contentsOf: url))
        guard loaded.version == 1 else { throw OperationFailure.message("Unsupported operations journal version. The existing journal was not changed.") }
        let states: Set<String> = ["working", "committed", "undone", "cancelled", "superseded", "undoing", "redoing", "interrupted"]
        guard Set(loaded.records.map(\.id)).count == loaded.records.count else { throw OperationFailure.message("Duplicate journal records.") }
        for record in loaded.records {
            guard states.contains(record.state), record.pending.map({ record.moves.indices.contains($0) }) ?? true else { throw OperationFailure.message("Invalid journal operation state.") }
            for step in record.moves {
                guard step.from.hasPrefix("/"), step.to.hasPrefix("/"), !step.fromParent.isEmpty, !step.toParent.isEmpty,
                      step.signature.count == 64, step.signature.allSatisfy({ $0.isHexDigit }) else { throw OperationFailure.message("Invalid journal file reference.") }
            }
            guard record.artifacts.allSatisfy({ path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return path.hasPrefix("/") && name.hasPrefix(".FinderPlus-") && UUID(uuidString: String(name.dropFirst(12))) != nil
            }) else { throw OperationFailure.message("Invalid journal staging reference.") }
        }
        let registered = Set(loaded.records.flatMap(\.artifacts))
        let storage = loaded.storage ?? []
        guard Set(storage.map(\.path)).count == storage.count else { throw OperationFailure.message("Duplicate journal storage references.") }
        for entry in storage {
            guard registered.contains(entry.path), !entry.parent.isEmpty,
                  entry.signature.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true,
                  entry.trashedAt.map({ $0.hasPrefix("/") }) ?? true else {
                throw OperationFailure.message("Invalid retained storage identity.")
            }
        }
        return loaded
    }

    func status() -> (Bool, Bool, [OperationsRecovery], String?) {
        let recovery = journal.records.filter { !["committed", "undone", "cancelled", "superseded"].contains($0.state) }
            .map { OperationsRecovery(id: $0.id, title: $0.title, detail: $0.error ?? "Interrupted operation. Review and roll back its validated changes.") }
        let clearing = journal.clearingHistory == true
        return (!clearing && journal.records.contains { $0.state == "committed" },
                !clearing && journal.records.contains { $0.state == "undone" }, recovery,
                loadError ?? (clearing ? "History cleanup was interrupted. Retry Clear File Operation History; completed Trash moves are retained in the journal." : nil))
    }

    private func persist() throws {
        if let loadError { throw OperationFailure.message(loadError) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.synchronize()
        try handle.close()
        let fd = open(journalURL.deletingLastPathComponent().path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }

    private func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func parentIdentity(_ url: URL) throws -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let attributes = try fm.attributesOfItem(atPath: parent.path)
        return parent.path + ":" + String(describing: attributes[.systemNumber] ?? "") + ":" + String(describing: attributes[.systemFileNumber] ?? "")
    }

    static func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw OperationFailure.message("Enter a nonempty file name without /, :, or null characters (maximum 255 UTF-8 bytes).")
        }
    }

    private func local(_ url: URL) throws {
        guard url.isFileURL else { throw OperationFailure.message("Only local file URLs are supported.") }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_flags & 0x40000000 != 0 {
            throw OperationFailure.message("Cloud-only item must be downloaded before use: \(url.path)")
        }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            throw OperationFailure.message("Download \(url.lastPathComponent) in its cloud provider before changing or copying it.")
        }
        if url.lastPathComponent.hasPrefix("."), url.pathExtension == "icloud" {
            throw OperationFailure.message("Cloud placeholder \(url.lastPathComponent) must be downloaded first.")
        }
    }

    private func children(_ url: URL) throws -> [URL] {
        return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { !ownedArtifactNames.contains($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func kind(_ url: URL) throws -> FileAttributeType {
        guard let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { throw OperationFailure.message("Cannot identify \(url.path)") }
        return type
    }

    // Hash names, contents, links, dates, permissions and extended attributes without following symbolic links.
    private func signature(_ url: URL, control: OperationControl, includeArtifacts: Bool = false) async throws -> String {
        var hash = SHA256()
        func append(_ text: String) { hash.update(data: Data(text.utf8)); hash.update(data: Data([0])) }
        func walk(_ item: URL, relative: String) async throws {
            try await control.checkpoint()
            try local(item)
            let attrs = try fm.attributesOfItem(atPath: item.path)
            let type = try kind(item)
            append(relative); append(type.rawValue)
            append(String(describing: attrs[.posixPermissions] ?? ""))
            if type != .typeDirectory { append(String((attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)) }
            if type == .typeSymbolicLink {
                append(try fm.destinationOfSymbolicLink(atPath: item.path))
            } else if type == .typeDirectory {
                let entries: [URL]
                if includeArtifacts {
                    entries = try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                } else { entries = try children(item) }
                for child in entries { try await walk(child, relative: relative + "/" + child.lastPathComponent) }
            } else if type == .typeRegular {
                let input = try FileHandle(forReadingFrom: item)
                append(String(describing: attrs[.size] ?? ""))
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                    try await control.checkpoint(); hash.update(data: data)
                }
            } else { throw OperationFailure.message("Special files, devices, and sockets are not supported: \(item.path)") }
            let length = listxattr(item.path, nil, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { throw OperationFailure.message("Cannot inspect extended attributes: \(item.path)") }
            if length > 0 {
                var buffer = [CChar](repeating: 0, count: length)
                let read = listxattr(item.path, &buffer, length, XATTR_NOFOLLOW)
                guard read == length else { throw OperationFailure.message("Extended attributes changed while reading \(item.path)") }
                let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
                // macOS assigns provenance to new files; copyfile cannot transfer this system-owned attribute.
                for name in names where name != "com.apple.provenance" {
                    let size = getxattr(item.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    guard size >= 0 else { throw OperationFailure.message("Cannot read attribute \(name) on \(item.path)") }
                    var data = Data(count: size)
                    let result = data.withUnsafeMutableBytes { getxattr(item.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
                    guard result == size else { throw OperationFailure.message("Attribute changed while reading \(item.path)") }
                    append(name); append(String(size)); hash.update(data: data)
                }
            }
        }
        try await walk(url, relative: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stage(in parent: URL, record: Int) throws -> URL {
        try local(parent)
        guard try kind(parent) == .typeDirectory else { throw OperationFailure.message("Destination is not a directory: \(parent.path)") }
        let root = parent.appendingPathComponent(".FinderPlus-" + UUID().uuidString, isDirectory: true)
        guard !exists(root) else { throw OperationFailure.message("Staging path already exists.") }
        journal.records[record].artifacts.append(root.path)
        ownedArtifactNames.insert(root.lastPathComponent)
        try persist()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let identity = try OperationSnapshot.capture(root) else { throw OperationFailure.message("Cannot identify new staging storage.") }
        if journal.storage == nil { journal.storage = [] }
        journal.storage!.append(OperationStorage(path: root.path, device: identity.device, inode: identity.inode, owner: getuid(), parent: try parentIdentity(root)))
        try persist()
        return root.appendingPathComponent("item")
    }

    private func copyTree(_ source: URL, _ destination: URL, control: OperationControl, progress: Progress) async throws {
        try await control.checkpoint()
        try local(source)
        let type = try kind(source)
        if type == .typeDirectory {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try children(source) {
                try await copyTree(child, destination.appendingPathComponent(child.lastPathComponent), control: control, progress: progress)
            }
        } else if type == .typeSymbolicLink {
            try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: source.path))
        } else if type == .typeRegular {
            guard fm.createFile(atPath: destination.path, contents: nil) else { throw OperationFailure.message("Cannot create staging file: \(destination.path)") }
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            let size = try fm.attributesOfItem(atPath: source.path)[.size] as? Double ?? 0
            var copied = 0.0
            var lastUpdate = -Double.infinity
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try await control.checkpoint()
                try output.write(contentsOf: data)
                copied += Double(data.count)
                await control.addCopied(data.count)
                let now = Date.timeIntervalSinceReferenceDate
                if now - lastUpdate >= 0.05 || copied == size {
                    await progress(size > 0 ? min(0.9, copied / size * 0.9) : 0, "Copying " + source.lastPathComponent)
                    lastUpdate = now
                }
            }
            try output.synchronize()
        } else { throw OperationFailure.message("Cannot copy special file: \(source.path)") }
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else { throw OperationFailure.message("Cannot preserve metadata for \(source.path): \(String(cString: strerror(errno)))") }
    }

    private func apply(_ record: Int, _ index: Int, forward: Bool, control: OperationControl) async throws {
        try await control.checkpoint()
        var step = journal.records[record].moves[index]
        guard step.applied != forward else { return }
        let source = URL(fileURLWithPath: forward ? step.from : step.to)
        let destination = URL(fileURLWithPath: forward ? step.to : step.from)
        let destinationParentMatches: Bool
        if forward && step.trashBookmark != nil { destinationParentMatches = true }
        else { destinationParentMatches = try parentIdentity(destination) == (forward ? step.toParent : step.fromParent) }
        guard try parentIdentity(source) == (forward ? step.fromParent : step.toParent),
              destinationParentMatches else {
            throw OperationFailure.message("A parent directory moved or changed. Restore its original location before retrying: \(source.path)")
        }
        guard exists(source), !exists(destination) else { throw OperationFailure.message("Refusing to overwrite or recover changed paths: \(source.path) → \(destination.path)") }
        guard try await signature(source, control: control) == step.signature else { throw OperationFailure.message("File changed since this operation; refusing to overwrite it: \(source.path)") }
        for entry in journal.storage ?? [] where entry.signature != nil && entry.trashedAt == nil {
            if source.path.hasPrefix(entry.path + "/") || destination.path.hasPrefix(entry.path + "/") {
                try await validateStorage(entry, at: URL(fileURLWithPath: entry.path), checkParent: true, control: control)
            }
        }
        journal.records[record].pending = index
        journal.records[record].pendingForward = forward
        try persist()
        if forward && step.trashBookmark != nil {
            var result: NSURL?
            try fm.trashItem(at: source, resultingItemURL: &result)
            guard let result else { throw OperationFailure.message("Trash did not return a recoverable file location.") }
            step.to = (result as URL).path
            step.toParent = try parentIdentity(result as URL)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
        step.applied = forward
        try storageMoved(from: source, to: URL(fileURLWithPath: forward ? step.to : step.from))
        journal.records[record].moves[index] = step
        journal.records[record].pending = nil
        try persist()
    }

    private func move(_ source: URL, _ destination: URL, record: Int, control: OperationControl, trash: Bool = false) async throws {
        try local(source)
        if try kind(source) == .typeDirectory {
            let retained = journal.records.flatMap(\.artifacts).contains { $0.hasPrefix(source.path + "/") && exists(URL(fileURLWithPath: $0)) }
            guard !retained else { throw OperationFailure.message("This folder contains retained FinderPlus undo storage. Move its contents instead, or leave the folder in place while this undo history is needed: \(source.path)") }
        }
        var step = OperationMove(from: source.path, to: destination.path, signature: try await signature(source, control: control), fromParent: try parentIdentity(source), toParent: try parentIdentity(destination))
        if trash { step.trashBookmark = try source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        journal.records[record].moves.append(step)
        try persist()
        try await apply(record, journal.records[record].moves.count - 1, forward: true, control: control)
    }

    private func unique(_ destination: URL) -> URL {
        if !exists(destination) { return destination }
        let parent = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let stem = ext.isEmpty ? destination.lastPathComponent : destination.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let name = stem + " copy" + (number == 2 ? "" : " \(number - 1)") + (ext.isEmpty ? "" : "." + ext)
            let candidate = parent.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    private func preview(_ source: URL, _ destination: URL) throws -> String {
        var sourceCount = 0, destinationCount = 0, collisions = 0
        func count(_ item: URL) throws -> Int {
            if try kind(item) != .typeDirectory { return 1 }
            return try children(item).reduce(1) { try $0 + count($1) }
        }
        sourceCount = try count(source); destinationCount = try count(destination)
        if try kind(source) == .typeDirectory, try kind(destination) == .typeDirectory {
            let names = Set(try children(destination).map(\.lastPathComponent))
            collisions = try children(source).filter { names.contains($0.lastPathComponent) }.count
        }
        return "Source: \(source.path) (\(sourceCount) items)\nDestination: \(destination.path) (\(destinationCount) items)\nMerge keeps unmatched items and reviews each name conflict; \(collisions) immediate names overlap. Replace retains the entire old item for validated Undo."
    }

    private func transfer(_ source: URL, _ requested: URL, moving: Bool, record: Int, control: OperationControl, review: Review, progress: Progress, sourceStorage: URL? = nil) async throws {
        try await control.checkpoint()
        try local(source)
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalDestination = requested.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(requested.lastPathComponent).standardizedFileURL.path
        guard canonicalSource != canonicalDestination, !canonicalDestination.hasPrefix(canonicalSource + "/") else { throw OperationFailure.message("An item cannot be copied or moved into itself: \(source.path)") }
        var destination = requested
        var approvedDestination: String?
        if exists(destination) {
            let merge = try kind(source) == .typeDirectory && kind(destination) == .typeDirectory
            let choice = await review(OperationConflict(source: source, destination: destination, canMerge: merge, preview: try preview(source, destination)))
            switch choice {
            case .cancel: throw CancellationError()
            case .skip: return
            case .keepBoth: destination = unique(destination)
            case .replace: approvedDestination = try await signature(destination, control: control)
            case .merge:
                guard merge else { throw OperationFailure.message("Only two directories can be merged.") }
                for child in try children(source) {
                    try await transfer(child, destination.appendingPathComponent(child.lastPathComponent), moving: moving, record: record, control: control, review: review, progress: progress, sourceStorage: sourceStorage ?? source.deletingLastPathComponent())
                }
                // Skipped files stay in the source; only an empty source directory is moved to undo storage.
                if moving, try children(source).isEmpty {
                    let held = try stage(in: sourceStorage ?? source.deletingLastPathComponent(), record: record)
                    try await move(source, held, record: record, control: control)
                }
                return
            }
        }
        let before = try await signature(source, control: control)
        let staged = try stage(in: destination.deletingLastPathComponent(), record: record)
        try await copyTree(source, staged, control: control, progress: progress)
        await progress(0.92, "Verifying " + source.lastPathComponent)
        guard try await signature(source, control: control) == before, try await signature(staged, control: control) == before else {
            throw OperationFailure.message("Verification failed or source changed. Original and staged data were retained: \(source.path)")
        }
        guard exists(destination) == (approvedDestination != nil) else {
            throw OperationFailure.message("Destination appeared or disappeared while copying. Retry to review the current conflict; staged data was retained.")
        }
        if exists(destination) {
            guard let approvedDestination, try await signature(destination, control: control) == approvedDestination else {
                throw OperationFailure.message("Destination changed after conflict review. No replacement was made; retry to review it again.")
            }
            let held = try stage(in: destination.deletingLastPathComponent(), record: record)
            try await move(destination, held, record: record, control: control)
        }
        try await move(staged, destination, record: record, control: control)
        if moving {
            guard try await signature(source, control: control) == before else { throw OperationFailure.message("Source changed after copying; original retained.") }
            let held = try stage(in: sourceStorage ?? source.deletingLastPathComponent(), record: record)
            try await move(source, held, record: record, control: control)
        }
    }

    private func folder(_ parent: URL, _ name: String, record: Int, control: OperationControl) async throws {
        try Self.validName(name)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard !exists(destination) else { throw OperationFailure.message("An item already exists: \(destination.path)") }
        let staged = try stage(in: parent, record: record)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        try await move(staged, destination, record: record, control: control)
    }

    private func ensureParent(_ url: URL, record: Int, control: OperationControl) async throws {
        if exists(url) {
            guard try kind(url) == .typeDirectory else { throw OperationFailure.message("Not a folder: \(url.path)") }
            try local(url)
            return
        }
        let parent = url.deletingLastPathComponent()
        guard parent != url else { throw OperationFailure.message("No existing parent for \(url.path)") }
        try await ensureParent(parent, record: record, control: control)
        try await folder(parent, url.lastPathComponent, record: record, control: control)
    }

    private static func historyRevision(_ value: OperationJournal) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    func historyScope() throws -> OperationHistoryScope {
        if let loadError { throw OperationFailure.message(loadError) }
        let current = try Self.readJournal(journalURL)
        return OperationHistoryScope(revision: try Self.historyRevision(current),
                                     paths: Array(Set(current.records.flatMap(\.artifacts))).sorted(),
                                     recordCount: current.records.count)
    }

    private func storageMoved(from source: URL, to destination: URL) throws {
        guard var storage = journal.storage else { return }
        var relocated: [String: String] = [:]
        for index in storage.indices {
            let old = storage[index].path
            if old == source.path || old.hasPrefix(source.path + "/") {
                let new = destination.path + String(old.dropFirst(source.path.count))
                storage[index].path = new
                storage[index].parent = try parentIdentity(URL(fileURLWithPath: new))
                relocated[old] = new
            }
            let root = storage[index].path
            if source.path.hasPrefix(root + "/") || destination.path.hasPrefix(root + "/") {
                storage[index].signature = nil
            }
        }
        journal.storage = storage
        for record in journal.records.indices {
            journal.records[record].artifacts = journal.records[record].artifacts.map { relocated[$0] ?? $0 }
        }
    }

    private func validateStorage(_ entry: OperationStorage, at url: URL, checkParent: Bool, control: OperationControl) async throws {
        let parentMatches: Bool
        if checkParent { parentMatches = try parentIdentity(url) == entry.parent }
        else { parentMatches = true }
        guard let identity = try OperationSnapshot.capture(url),
              identity.type == FileAttributeType.typeDirectory.rawValue,
              identity.device == entry.device, identity.inode == entry.inode,
              identity.owner == entry.owner, entry.owner == getuid(),
              parentMatches else {
            throw OperationFailure.message("Retained storage was replaced, moved, or is a symbolic link. Nothing at this path will be removed: \(url.path)")
        }
        guard let expected = entry.signature,
              try await signature(url, control: control, includeArtifacts: true) == expected else {
            throw OperationFailure.message("Retained storage contains changed or unverified data. History was kept; inspect this folder manually: \(url.path)")
        }
    }

    private func sealStorage() async throws {
        guard var storage = journal.storage else { return }
        let control = OperationControl()
        for index in storage.indices where storage[index].signature == nil && storage[index].trashedAt == nil {
            let url = URL(fileURLWithPath: storage[index].path)
            guard let identity = try OperationSnapshot.capture(url),
                  identity.type == FileAttributeType.typeDirectory.rawValue,
                  identity.device == storage[index].device, identity.inode == storage[index].inode,
                  identity.owner == storage[index].owner, storage[index].owner == getuid(),
                  try parentIdentity(url) == storage[index].parent else {
                throw OperationFailure.message("Staging storage changed identity; retaining its journal for manual recovery: \(url.path)")
            }
            storage[index].signature = try await signature(url, control: control, includeArtifacts: true)
        }
        journal.storage = storage
    }

    private func markStorageTrashed(_ index: Int, destination: URL) {
        guard var storage = journal.storage else { return }
        let root = storage[index].path
        for item in storage.indices where storage[item].path == root || storage[item].path.hasPrefix(root + "/") {
            storage[item].trashedAt = destination.path + String(storage[item].path.dropFirst(root.count))
            storage[item].pendingTrash = nil
        }
        journal.storage = storage
    }

    private func clearHistory(_ scope: OperationHistoryScope, control: OperationControl) async throws {
        guard try Self.historyRevision(journal) == scope.revision else {
            throw OperationFailure.message("File history changed after confirmation. Review Clear History again.")
        }
        guard !journal.records.contains(where: { !["committed", "undone", "cancelled", "superseded"].contains($0.state) }) else {
            throw OperationFailure.message("Resolve interrupted operations before clearing history.")
        }
        let registered = Set(journal.records.flatMap(\.artifacts))
        let entries = journal.storage ?? []
        for path in registered where !entries.contains(where: { $0.path == path }) {
            if exists(URL(fileURLWithPath: path)) {
                throw OperationFailure.message("This older or interrupted storage has no validated ownership record. History was kept; inspect it manually: \(path)")
            }
        }
        guard entries.allSatisfy({ registered.contains($0.path) }),
              Set(entries.map(\.path)).count == entries.count else { throw OperationFailure.message("History storage references are inconsistent; journal was retained.") }
        // Recover a crash between the native Trash operation and its journal update.
        for index in entries.indices where journal.storage![index].trashedAt == nil {
            let entry = journal.storage![index]
            let url = URL(fileURLWithPath: entry.path)
            if let bookmark = entry.pendingTrash, !exists(url) {
                var stale = false
                let moved = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard moved.path != url.path else { throw OperationFailure.message("Cannot locate interrupted history cleanup. Journal was retained.") }
                try await validateStorage(entry, at: moved, checkParent: false, control: control)
                markStorageTrashed(index, destination: moved)
                try persist()
            }
        }
        // Validate every root, including nested storage, before moving any of them.
        for entry in journal.storage ?? [] where entry.trashedAt == nil {
            try await validateStorage(entry, at: URL(fileURLWithPath: entry.path), checkParent: true, control: control)
        }
        try await control.checkpoint()
        journal.clearingHistory = true
        try persist()
        let finish = OperationControl()
        let pending = (journal.storage ?? []).filter { $0.trashedAt == nil }
        let roots = pending.filter { entry in !pending.contains { other in entry.path != other.path && entry.path.hasPrefix(other.path + "/") } }
        for root in roots {
            guard let index = journal.storage?.firstIndex(where: { $0.path == root.path }) else { throw OperationFailure.message("History storage changed unexpectedly.") }
            let url = URL(fileURLWithPath: root.path)
            try await validateStorage(root, at: url, checkParent: true, control: finish)
            journal.storage![index].pendingTrash = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            try persist()
            var result: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw OperationFailure.message("Trash returned no storage location. Journal was retained for recovery.") }
            markStorageTrashed(index, destination: result as URL)
            try persist()
        }
        let previous = journal
        let backup = journalURL.deletingLastPathComponent().appendingPathComponent("history-cleanup-" + UUID().uuidString + ".json")
        try Data(contentsOf: journalURL).write(to: backup, options: .withoutOverwriting)
        let backupHandle = try FileHandle(forWritingTo: backup)
        try backupHandle.synchronize()
        try backupHandle.close()
        journal = OperationJournal()
        do {
            try persist()
            try fm.removeItem(at: backup)
            ownedArtifactNames.removeAll()
        } catch {
            journal = previous
            try? persist()
            throw OperationFailure.message("History reset failed. Its recovery journal is retained at \(backup.path): \(error.localizedDescription)")
        }
    }

    private func archiveTool(_ executable: String, arguments: [String], logURL: URL, control: OperationControl) async throws {
        try await control.checkpoint()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        guard fm.createFile(atPath: logURL.path, contents: nil) else { throw OperationFailure.message("Cannot create archive diagnostic log.") }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardError = log
        process.standardOutput = log
        try process.run()
        do {
            while process.isRunning {
                _ = kill(process.processIdentifier, SIGSTOP)
                try await control.checkpoint()
                _ = kill(process.processIdentifier, SIGCONT)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            _ = kill(process.processIdentifier, SIGCONT)
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            let input = try FileHandle(forReadingFrom: logURL)
            defer { try? input.close() }
            let data = try input.read(upToCount: 16_384) ?? Data()
            throw OperationFailure.message("Archive tool failed: " + (String(data: data, encoding: .utf8) ?? executable))
        }
    }

    private func reconcilePending(_ record: Int, control: OperationControl) async throws {
        guard let index = journal.records[record].pending else { return }
        var step = journal.records[record].moves[index]
        let forward = journal.records[record].pendingForward
        let source = URL(fileURLWithPath: forward ? step.from : step.to)
        if forward, let data = step.trashBookmark, !exists(source) {
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard resolved.path != source.path, exists(resolved) else { throw OperationFailure.message("Cannot resolve the interrupted Trash item. Restore it manually in Finder before retrying.") }
            step.to = resolved.path
            step.toParent = try parentIdentity(resolved)
        }
        let destination = URL(fileURLWithPath: forward ? step.to : step.from)
        if exists(source), !exists(destination), try await signature(source, control: control) == step.signature {
            step.applied = !forward
        } else if !exists(source), exists(destination), try await signature(destination, control: control) == step.signature {
            step.applied = forward
            try storageMoved(from: source, to: destination)
        } else { throw OperationFailure.message("Interrupted step has changed or ambiguous files. No recovery changes were made to this step.") }
        journal.records[record].moves[index] = step
        journal.records[record].pending = nil
        try persist()
    }

    private func rollback(_ record: Int, finalState: String) async throws {
        let control = OperationControl()
        try await reconcilePending(record, control: control)
        for index in journal.records[record].moves.indices.reversed() where journal.records[record].moves[index].applied {
            try await apply(record, index, forward: false, control: control)
        }
        try await sealStorage()
        journal.records[record].state = finalState
        journal.records[record].error = nil
        try persist()
    }

    func execute(_ request: OperationRequest, id: UUID, title: String, control: OperationControl, review: Review, progress: Progress) async throws {
        if let loadError { throw OperationFailure.message(loadError) }
        let lockURL = journalURL.deletingLastPathComponent().appendingPathComponent("operations.lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw OperationFailure.message("Cannot open the operations journal lock.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw OperationFailure.message("Another FinderPlus process is performing a file operation. Wait for it to finish.")
        }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        journal = try Self.readJournal(journalURL)
        ownedArtifactNames = Set(journal.records.flatMap(\.artifacts).map { URL(fileURLWithPath: $0).lastPathComponent })
        if case .clearHistory(let scope) = request {
            await progress(0.05, "Verifying retained history storage")
            try await clearHistory(scope, control: control)
            await progress(1, "File history cleared")
            return
        }
        guard journal.clearingHistory != true else {
            throw OperationFailure.message("History cleanup is incomplete. Retry Clear File Operation History before starting another operation.")
        }
        if case .abandon(let recoveryID) = request {
            guard let index = journal.records.firstIndex(where: { $0.id == recoveryID }),
                  !["committed", "undone", "cancelled", "superseded"].contains(journal.records[index].state) else {
                throw OperationFailure.message("This record no longer needs recovery.")
            }
            journal.records[index].state = "superseded"
            journal.records[index].error = "Recovery intentionally abandoned; current files and retained staging data were left untouched."
            try persist()
            return
        }
        if case .recover(let recoveryID) = request {
            guard let index = journal.records.firstIndex(where: { $0.id == recoveryID }) else { throw OperationFailure.message("Recovery record no longer exists.") }
            let state = journal.records[index].state
            do { try await rollback(index, finalState: ["undoing", "redoing"].contains(state) ? "undone" : "cancelled") }
            catch { journal.records[index].error = error.localizedDescription; try? persist(); throw error }
            return
        }
        guard !journal.records.contains(where: { !["committed", "undone", "cancelled", "superseded"].contains($0.state) }) else {
            throw OperationFailure.message("Resolve interrupted operations in the Operations panel before making new changes.")
        }
        if case .undo = request {
            guard let index = journal.records.lastIndex(where: { $0.state == "committed" }) else { return }
            journal.records[index].state = "undoing"; try persist()
            do { try await rollback(index, finalState: "undone") }
            catch { journal.records[index].error = error.localizedDescription; try? persist(); throw error }
            return
        }
        if case .redo = request {
            guard let index = journal.records.firstIndex(where: { $0.state == "undone" }) else { return }
            journal.records[index].state = "redoing"; try persist()
            do {
                for step in journal.records[index].moves.indices { try await apply(index, step, forward: true, control: control) }
                try await sealStorage()
                journal.records[index].state = "committed"; try persist()
            } catch { journal.records[index].error = error.localizedDescription; try? persist(); throw error }
            return
        }
        let userPaths: [URL]
        switch request {
        case .transfer(let urls, let parent, _), .archive(let urls, let parent), .alias(let urls, let parent):
            userPaths = urls + [parent]
        case .duplicate(let urls), .trash(let urls), .putBack(let urls): userPaths = urls
        case .rename(let changes): userPaths = changes.map { $0.0 }
        case .folder(let parent, _): userPaths = [parent]
        case .synchronize(let copies): userPaths = copies.flatMap { [$0.source, $0.destination] }
        case .undo, .redo, .recover, .abandon, .clearHistory: userPaths = []
        }
        guard !userPaths.contains(where: { !ownedArtifactNames.isDisjoint(with: $0.pathComponents) }) else {
            throw OperationFailure.message("FinderPlus undo storage cannot be edited directly. Use Clear File Operation History to release it safely.")
        }
        for index in journal.records.indices where journal.records[index].state == "undone" { journal.records[index].state = "superseded" }
        journal.records.append(OperationRecord(id: id, title: title))
        let record = journal.records.count - 1
        try persist()
        do {
            switch request {
            case .transfer(let urls, let destination, let moving):
                for (index, source) in urls.enumerated() {
                    try await transfer(source, destination.appendingPathComponent(source.lastPathComponent), moving: moving, record: record, control: control, review: review, progress: progress)
                    await progress(Double(index + 1) / Double(max(1, urls.count)), source.lastPathComponent)
                }
            case .duplicate(let urls):
                for source in urls { try await transfer(source, unique(source), moving: false, record: record, control: control, review: review, progress: progress) }
            case .rename(let changes):
                var sources = Set<String>()
                var destinations = Set<String>()
                for (source, name) in changes {
                    guard sources.insert(source.standardizedFileURL.path).inserted,
                          !changes.contains(where: { $0.0.path != source.path && source.path.hasPrefix($0.0.path + "/") }) else {
                        throw OperationFailure.message("A batch rename cannot include duplicate sources or both a folder and its descendants.")
                    }
                    try Self.validName(name); try local(source)
                    let destination = source.deletingLastPathComponent().appendingPathComponent(name)
                    guard destinations.insert(destination.path.lowercased()).inserted else { throw OperationFailure.message("Two renames have the same destination.") }
                    guard source.path == destination.path || !exists(destination) else { throw OperationFailure.message("Rename destination already exists: \(destination.path). Rename cycles and case-only renames are not supported.") }
                }
                for (source, name) in changes {
                    let destination = source.deletingLastPathComponent().appendingPathComponent(name)
                    if source.path != destination.path { try await move(source, destination, record: record, control: control) }
                }
            case .folder(let parent, let name): try await folder(parent, name, record: record, control: control)
            case .trash(let urls):
                for source in urls { try await move(source, URL(fileURLWithPath: "/.FinderPlus-trash-" + UUID().uuidString), record: record, control: control, trash: true) }
            case .putBack(let urls):
                var restores: [(URL, URL)] = []
                for url in urls {
                    guard let step = journal.records.reversed().flatMap(\.moves).first(where: {
                        $0.trashBookmark != nil && $0.applied && URL(fileURLWithPath: $0.to).standardizedFileURL.path == url.standardizedFileURL.path
                    }) else { throw OperationFailure.message("No FinderPlus Trash record exists for \(url.path). Use Finder’s Put Back for items trashed by another app.") }
                    let original = URL(fileURLWithPath: step.from)
                    guard !exists(original), try await signature(url, control: control) == step.signature,
                          try parentIdentity(original) == step.fromParent else {
                        throw OperationFailure.message("The original location is occupied or changed, or the Trash item changed: \(url.path)")
                    }
                    restores.append((url, original))
                }
                for (url, original) in restores { try await move(url, original, record: record, control: control) }
            case .alias(let urls, let parent):
                for source in urls {
                    try local(source)
                    let staged = try stage(in: parent, record: record)
                    let data = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try URL.writeBookmarkData(data, to: staged)
                    try await move(staged, unique(parent.appendingPathComponent(source.lastPathComponent + " alias")), record: record, control: control)
                }
            case .archive(let urls, let parent):
                guard !urls.isEmpty else { break }
                let output = try stage(in: parent, record: record)
                let input = output.deletingLastPathComponent().appendingPathComponent("archive-input")
                try fm.createDirectory(at: input, withIntermediateDirectories: false)
                var names = Set<String>()
                for source in urls {
                    guard names.insert(source.lastPathComponent).inserted else { throw OperationFailure.message("Archive selections contain duplicate file names.") }
                    let before = try await signature(source, control: control)
                    let copy = input.appendingPathComponent(source.lastPathComponent)
                    try await copyTree(source, copy, control: control, progress: progress)
                    guard try await signature(source, control: control) == before, try await signature(copy, control: control) == before else { throw OperationFailure.message("Archive input verification failed.") }
                }
                let logURL = output.deletingLastPathComponent().appendingPathComponent("archive-errors")
                try await archiveTool("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", input.path, output.path], logURL: logURL, control: control)
                await progress(0.95, "Checking ZIP integrity")
                try await archiveTool("/usr/bin/unzip", arguments: ["-t", "-qq", output.path], logURL: logURL, control: control)
                guard exists(output) else { throw OperationFailure.message("Archive tool produced no output.") }
                let name = urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "Archive.zip"
                try await move(output, unique(parent.appendingPathComponent(name)), record: record, control: control)
            case .synchronize(let copies):
                for item in copies {
                    try item.validate()
                    try await ensureParent(item.destination.deletingLastPathComponent(), record: record, control: control)
                    try await transfer(item.source, item.destination, moving: false, record: record, control: control, review: review, progress: progress)
                }
            case .undo, .redo, .recover, .abandon, .clearHistory: break
            }
            try await sealStorage()
            journal.records[record].state = journal.records[record].moves.isEmpty ? "cancelled" : "committed"
            try persist()
            await progress(1, "Completed")
        } catch {
            let original = error
            journal.records[record].error = error.localizedDescription
            try? persist()
            do { try await rollback(record, finalState: "cancelled") }
            catch {
                journal.records[record].state = "interrupted"
                journal.records[record].error = "\(original.localizedDescription) Recovery: \(error.localizedDescription)"
                try? persist()
                throw OperationFailure.message(journal.records[record].error!)
            }
            throw original
        }
    }
}
