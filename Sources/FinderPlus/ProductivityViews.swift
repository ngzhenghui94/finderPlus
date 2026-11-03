import AppKit
import SwiftUI

@MainActor
struct CompareFoldersView: View {
    let left: URL
    let right: URL
    @State private var comparison: FolderComparison?
    @State private var selected = Set<String>()
    @State private var direction = FolderComparison.Direction.leftToRight
    @State private var includeEqual = false
    @State private var allowCloudDownloads = false
    @State private var busy = false
    @State private var error: String?
    @State private var message = ""
    @State private var reviewed: [FolderComparison.Copy] = []
    @State private var showReview = false
    @State private var worker: Task<FolderComparison, Error>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare Folders").font(.title2)
            Text("Left: \(left.path)\nRight: \(right.path)").font(.caption).textSelection(.enabled)
            HStack {
                Toggle("Show identical items", isOn: $includeEqual)
                Toggle("Allow cloud downloads for comparison", isOn: $allowCloudDownloads)
                    .disabled(busy)
                Spacer()
                Button("Compare") { compare() }.disabled(busy)
            }
            Text("Recursive SHA-256 content comparison includes hidden files. Symlinks are compared as links and never synchronized. No files are deleted. Folder metadata, permissions and tags are not synchronized.")
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView("Reading and comparing…") }
            if let comparison {
                List {
                    ForEach(comparison.items.filter { includeEqual || $0.kind != .equal }) { item in
                        HStack {
                            Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                                if value { selected.insert(item.id) } else { selected.remove(item.id) }
                            })) { Text(item.path).lineLimit(2) }
                            .disabled(!comparison.isSelectable(item) || busy)
                            Spacer()
                            Text(item.kind.rawValue).foregroundStyle(item.kind == .typeConflict ? Color.red : Color.secondary)
                        }
                    }
                }
                HStack {
                    Button("Select Copyable") { selected = Set(comparison.items.filter { comparison.isSelectable($0) }.map(\.id)) }
                    Button("Clear Selection") { selected.removeAll() }
                    Spacer()
                    Text("\(comparison.items.filter { $0.kind != .equal }.count) differences")
                }.disabled(busy)
            } else { ContentUnavailableView("Compare two folders", systemImage: "folder.badge.gearshape", description: Text("Choose Compare to read both folder trees. No files are changed during comparison.")) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            HStack {
                Picker("Synchronization", selection: $direction) {
                    ForEach(FolderComparison.Direction.allCases, id: \.self) { Text($0.rawValue) }
                }.frame(maxWidth: 340)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review Copies…") { review() }.disabled(comparison == nil || selected.isEmpty || busy)
            }
        }.padding(20).frame(minWidth: 800, minHeight: 560)
        .onDisappear { worker?.cancel() }
        .sheet(isPresented: $showReview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review \(reviewed.count) Copies").font(.title2)
                Text("Only these paths will be copied. Existing files are replaced; Undo restores the replaced versions. Both-way synchronization chooses the newer modification date, not a version history; equal-date conflicts require an explicit direction.")
                    .font(.caption)
                List(reviewed) { copy in
                    VStack(alignment: .leading) {
                        Text(copy.source.path).textSelection(.enabled)
                        Text("→ \(copy.destination.path)").textSelection(.enabled)
                        Text(copy.destinationSnapshot == nil ? "Create" : "Replaces the existing item (Undo restores it)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Cancel") { showReview = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Queue Reviewed Copies") { synchronize() }.disabled(busy)
                }
            }.padding(20).frame(width: 760, height: 440)
        }
    }

    private func compare() {
        worker?.cancel()
        busy = true
        error = nil
        message = ""
        comparison = nil
        selected.removeAll()
        let cloud = allowCloudDownloads
        let task = Task.detached(priority: .userInitiated) { try FolderComparison.compare(left: left, right: right, allowCloudDownloads: cloud) }
        worker = task
        Task {
            do {
                let result = try await task.value
                guard !task.isCancelled else { busy = false; return }
                comparison = result
                selected = Set(result.items.filter { result.isSelectable($0) }.map(\.id))
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func review() {
        guard let comparison else { return }
        do {
            reviewed = try comparison.copies(selected: selected, direction: direction)
            guard !reviewed.isEmpty else { error = "No selected items can be copied in this direction."; return }
            error = nil
            showReview = true
        } catch { self.error = error.localizedDescription }
    }

    private func synchronize() {
        guard let comparison else { return }
        let copies = reviewed
        busy = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try comparison.validate(copies) }.value
                FileOperations.shared.synchronize(try copies.map { try OperationPlannedCopy(source: $0.source, destination: $0.destination, reviewed: $0, allowCloudDownloads: comparison.allowCloudDownloads) })
                self.comparison = nil
                selected.removeAll()
                message = "Queued \(copies.count) reviewed copies. See the operations queue for progress and conflicts. Compare again after completion."
            } catch { self.error = error.localizedDescription }
            showReview = false
            busy = false
        }
    }
}

@MainActor
struct BatchRenameView: View {
    let urls: [URL]
    @State private var options = BatchRenamePlan.Options()
    @State private var changes: [BatchRenamePlan.Change] = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Rename").font(.title2)
            Form {
                Picker("Mode", selection: $options.mode) {
                    ForEach(BatchRenamePlan.Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                if options.mode == .replace {
                    TextField("Find (case-sensitive)", text: $options.find)
                    TextField("Replace with", text: $options.replacement)
                } else {
                    TextField("Prefix", text: $options.prefix)
                    TextField("Suffix", text: $options.suffix)
                }
                if options.mode == .number {
                    TextField("Start at", value: $options.start, format: .number)
                    Stepper("Padding: \(options.digits) digits", value: $options.digits, in: 1...12)
                    Text("Numbering follows the selection order shown below.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Preserve file extensions", isOn: $options.preserveExtension)
            }.formStyle(.grouped)
            List(changes) { change in
                HStack {
                    Text(change.url.lastPathComponent).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                    Text(change.name).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(change.changed ? .primary : .secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Existing destinations, duplicate names, case-only renames and parent/child batches are rejected. Nothing is overwritten.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename \(changes.filter(\.changed).count) Items…") { rename() }
                    .disabled(error != nil || !changes.contains(where: \.changed))
            }
        }.padding(20).frame(width: 700, height: 600)
        .onAppear { preview() }
        .onChange(of: options) { _, _ in preview() }
    }

    private func preview() {
        do { changes = try BatchRenamePlan.make(urls: urls, options: options); error = nil }
        catch { changes = []; self.error = error.localizedDescription }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename \(changes.filter(\.changed).count) items?"
        alert.informativeText = "The displayed preview will be queued. Names are revalidated before execution. You can undo completed renames from the operations menu."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try BatchRenamePlan.validate(changes)
            FileOperations.shared.batchRename(changes.filter(\.changed).map { ($0.url, $0.name) })
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct InfoView: View {
    let url: URL
    @State private var entry: FileEntry?
    @State private var loadedMetadata: Metadata?
    @State private var tags = ""
    @State private var created = Date()
    @State private var modified = Date()
    @State private var locked = false
    @State private var hiddenExtension = false
    @State private var error: String?
    @State private var message = ""
    @State private var folderSize: Int64?
    @State private var sharing: [(String, String)] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 48, height: 48)
                Text(url.lastPathComponent).font(.title2).textSelection(.enabled)
            }
            Form {
                LabeledContent("Location") { Text(url.path).textSelection(.enabled) }
                if let entry {
                    LabeledContent("Kind", value: entry.kind)
                    if entry.isDirectory {
                        LabeledContent("Size") { if let folderSize { Text(ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file)) } else { ProgressView().controlSize(.small) } }
                    } else { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) }
                    LabeledContent("Cloud", value: CloudLocations.status(url))
                }
                DatePicker("Created", selection: $created)
                DatePicker("Modified", selection: $modified)
                Toggle("Locked", isOn: $locked)
                Toggle("Hide extension in Finder", isOn: $hiddenExtension)
                Section("Finder tags — one per line") {
                    TextEditor(text: $tags).font(.body).frame(height: 90)
                }
                Section("Sharing & Permissions") {
                    ForEach(sharing, id: \.0) { name, access in LabeledContent(name, value: access) }
                }
            }.formStyle(.grouped).disabled(loadedMetadata == nil)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Refresh") { load() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Metadata") { save() }.disabled(loadedMetadata == nil)
            }
        }.padding(20).frame(width: 660, height: 620).onAppear { load() }
        .task(id: url) { if entry?.isDirectory == true || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { let target = url; folderSize = await measuredSize([target]) } }
    }

    private func load() {
        loadedMetadata = nil
        entry = nil
        sharing = []
        message = ""
        do {
            let metadata = try Metadata(url)
            let loadedEntry = try FileEntry(url: URL(fileURLWithPath: url.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            tags = metadata.tags.joined(separator: "\n")
            created = metadata.created
            modified = metadata.modified
            hiddenExtension = metadata.hiddenExtension
            locked = metadata.locked
            sharing = Self.permissions(attributes, url: url)
            entry = loadedEntry
            loadedMetadata = metadata
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Owner, group and everyone access in Finder's wording, plus what the current user can do.
    static func permissions(_ attributes: [FileAttributeKey: Any], url: URL) -> [(String, String)] {
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        func access(_ bits: Int) -> String { bits & 4 != 0 ? (bits & 2 != 0 ? "Read & Write" : "Read only") : (bits & 2 != 0 ? "Write only (Drop Box)" : "No Access") }
        let fm = FileManager.default
        let you = access((fm.isReadableFile(atPath: url.path) ? 4 : 0) | (fm.isWritableFile(atPath: url.path) ? 2 : 0))
        return [("You (\(NSUserName()))", you),
                ((attributes[.ownerAccountName] as? String ?? "Owner") + " (owner)", access(mode >> 6 & 7)),
                ((attributes[.groupOwnerAccountName] as? String ?? "Group") + " (group)", access(mode >> 3 & 7)),
                ("Everyone", access(mode & 7)),
                ("Mode", String(format: "%03o", mode & 0o777))]
    }

    private func save() {
        guard let loadedMetadata else { return }
        do {
            try loadedMetadata.save(url, tags: tags, created: created, modified: modified, locked: locked, hiddenExtension: hiddenExtension)
            load()
            if error == nil { message = "Metadata saved." }
            NotificationCenter.default.post(name: Notification.Name("FinderPlusFilesChanged"), object: nil)
        } catch { self.error = "Metadata save failed; some earlier attributes may already have changed. Refresh to inspect: \(error.localizedDescription)"; message = "" }
    }

    static func selfCheck() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FinderPlus-metadata-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("original.txt")
        let target = root.appendingPathComponent("target.txt")
        let lockedFile = root.appendingPathComponent("locked.txt")
        defer {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: lockedFile.path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try? fm.removeItem(at: root)
        }
        try Data("original".utf8).write(to: file)
        try Data("target".utf8).write(to: target)
        try Data("locked".utf8).write(to: lockedFile)
        func save(_ metadata: Metadata, at url: URL, tags: String? = nil, locked: Bool? = nil) throws {
            try metadata.save(url, tags: tags ?? metadata.tags.joined(separator: "\n"), created: metadata.created,
                              modified: metadata.modified, locked: locked ?? metadata.locked, hiddenExtension: metadata.hiddenExtension)
        }
        func reject(_ metadata: Metadata, at url: URL, tags: String? = nil) throws {
            do { try save(metadata, at: url, tags: tags) }
            catch { return }
            throw OperationFailure.message("Unsafe metadata save was accepted: \(url.lastPathComponent)")
        }
        let original = try Metadata(file)
        try save(original, at: file, tags: "Audit\nAudit\n")
        let edited = try Metadata(file)
        guard edited.tags == ["Audit"], try Data(contentsOf: file) == Data("original".utf8) else {
            throw OperationFailure.message("Metadata save changed file contents or did not deduplicate tags.")
        }
        try reject(edited, at: file, tags: "bad\0tag")
        guard try Metadata(file) == edited else { throw OperationFailure.message("Invalid tags changed metadata.") }
        try (URL(fileURLWithPath: file.path) as NSURL).setResourceValue(["External"], forKey: .tagNamesKey)
        let external = try Metadata(file)
        try reject(edited, at: file)
        guard try Metadata(file) == external else { throw OperationFailure.message("Stale metadata overwrote externally edited tags.") }

        try fm.moveItem(at: file, to: root.appendingPathComponent("moved.txt"))
        try Data("replacement".utf8).write(to: file)
        let replacement = try Metadata(file)
        try reject(external, at: file)
        guard try Metadata(file) == replacement else { throw OperationFailure.message("Metadata was written to a replacement file.") }
        try fm.removeItem(at: file)
        let targetBefore = try Metadata(target)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        try reject(replacement, at: file)
        guard try Metadata(target) == targetBefore, try Data(contentsOf: target) == Data("target".utf8) else {
            throw OperationFailure.message("Metadata followed a replacement symlink.")
        }
        try fm.removeItem(at: file)
        if case .success = Result(catching: { try Metadata(file) }) {
            throw OperationFailure.message("Missing item retained editable metadata.")
        }
        try fm.setAttributes([.immutable: true], ofItemAtPath: lockedFile.path)
        let locked = try Metadata(lockedFile)
        try reject(locked, at: lockedFile)
        guard try Metadata(lockedFile) == locked else { throw OperationFailure.message("Rejected locked save changed metadata.") }
        try save(locked, at: lockedFile, locked: false)
        guard try !Metadata(lockedFile).locked else { throw OperationFailure.message("Explicit metadata unlock failed.") }

        try fm.setAttributes([.posixPermissions: 0o200], ofItemAtPath: target.path)
        let reported = Self.permissions(try fm.attributesOfItem(atPath: target.path), url: target)
        guard reported[1].1 == "Write only (Drop Box)",
              fm.isReadableFile(atPath: target.path) || !fm.isWritableFile(atPath: target.path) || reported[0].1 == "Write only (Drop Box)" else {
            throw OperationFailure.message("Write-only permissions were reported as readable.")
        }
    }

    private struct Metadata: Equatable {
        let snapshot: OperationSnapshot
        let tags: [String]
        let created: Date
        let modified: Date
        let locked: Bool
        let hiddenExtension: Bool

        init(_ url: URL) throws {
            guard let snapshot = try OperationSnapshot.capture(url) else { throw CocoaError(.fileNoSuchFile) }
            guard snapshot.type != FileAttributeType.typeSymbolicLink.rawValue else {
                throw OperationFailure.message("Editing symlink metadata is not supported; inspect its target explicitly.")
            }
            let target = URL(fileURLWithPath: url.path)
            let values = try target.resourceValues(forKeys: [.tagNamesKey, .creationDateKey, .contentModificationDateKey, .hasHiddenExtensionKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard let created = values.creationDate, let modified = values.contentModificationDate,
                  try OperationSnapshot.capture(target) == snapshot else {
                throw OperationFailure.message("Cannot read consistent metadata. Refresh before editing.")
            }
            self.snapshot = snapshot
            self.tags = values.tagNames ?? []
            self.created = created
            self.modified = modified
            self.locked = attributes[.immutable] as? Bool ?? false
            self.hiddenExtension = values.hasHiddenExtension ?? false
        }

        func save(_ url: URL, tags: String, created: Date, modified: Date, locked: Bool, hiddenExtension: Bool) throws {
            let names = tags.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard names.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 255 }) else {
                throw OperationFailure.message("Tag names must be at most 255 UTF-8 bytes and cannot contain NUL.")
            }
            var unique: [String] = []
            for name in names where !unique.contains(name) { unique.append(name) }
            guard try Metadata(url) == self else { throw OperationFailure.message("This item changed since it was loaded. Refresh before saving metadata.") }
            if self.locked && locked { throw OperationFailure.message("Unlock this item and save first before editing other metadata.") }
            if self.locked { try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
            try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
            try (url as NSURL).setResourceValue(unique, forKey: .tagNamesKey)
            var values = URLResourceValues()
            values.hasHiddenExtension = hiddenExtension
            var target = URL(fileURLWithPath: url.path)
            try target.setResourceValues(values)
            try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
        }
    }
}
