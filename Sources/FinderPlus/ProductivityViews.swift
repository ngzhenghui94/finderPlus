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
                            .disabled(!isSelectable(item, in: comparison) || busy)
                            Spacer()
                            Text(item.kind.rawValue).foregroundStyle(item.kind == .typeConflict ? Color.red : Color.secondary)
                        }
                    }
                }
                HStack {
                    Button("Select Copyable") { selected = Set(comparison.items.filter { isSelectable($0, in: comparison) }.map(\.id)) }
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
                Text("Only these paths will be copied. Existing destinations still require conflict confirmation in the operations queue. Both-way synchronization chooses the newer modification date, not a version history; equal-date conflicts require an explicit direction.")
                    .font(.caption)
                List(reviewed) { copy in
                    VStack(alignment: .leading) {
                        Text(copy.source.path).textSelection(.enabled)
                        Text("→ \(copy.destination.path)").textSelection(.enabled)
                        Text(copy.destinationSnapshot == nil ? "Create" : "Existing destination — conflict review required").font(.caption).foregroundStyle(.secondary)
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

    private func isSelectable(_ item: FolderComparison.Item, in comparison: FolderComparison) -> Bool {
        guard item.canCopy else { return false }
        if (item.left?.isDirectory == true || item.right?.isDirectory == true) && comparison.items.contains(where: { $0.path.hasPrefix(item.path + "/") }) { return false }
        return !comparison.items.contains { $0.kind == .typeConflict && item.path.hasPrefix($0.path + "/") }
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
                selected = Set(result.items.filter { isSelectable($0, in: result) }.map(\.id))
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
                FileOperations.shared.synchronize(copies.map { (source: $0.source, destination: $0.destination) })
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
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Refresh") { load() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Metadata") { save() }.disabled(entry == nil)
            }
        }.padding(20).frame(width: 660, height: 620).onAppear { load() }
        .task(id: url) { if entry?.isDirectory == true || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { let target = url; folderSize = await Task.detached(priority: .utility) { totalFileSize([target]) }.value } }
    }

    private func load() {
        do {
            entry = try FileEntry(url: url)
            let values = try url.resourceValues(forKeys: [.tagNamesKey, .creationDateKey, .contentModificationDateKey, .hasHiddenExtensionKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { entry = nil; throw FolderComparison.Failure("Editing symlink metadata is not supported; inspect its target explicitly.") }
            tags = (values.tagNames ?? []).joined(separator: "\n")
            created = values.creationDate ?? Date()
            modified = values.contentModificationDate ?? Date()
            hiddenExtension = values.hasHiddenExtension ?? false
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            locked = attributes[.immutable] as? Bool ?? false
            sharing = Self.permissions(attributes, url: url)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Owner, group and everyone access in Finder's wording, plus what the current user can do.
    static func permissions(_ attributes: [FileAttributeKey: Any], url: URL) -> [(String, String)] {
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        func access(_ bits: Int) -> String { bits & 4 != 0 ? (bits & 2 != 0 ? "Read & Write" : "Read only") : (bits & 2 != 0 ? "Write only (Drop Box)" : "No Access") }
        let fm = FileManager.default
        let you = fm.isWritableFile(atPath: url.path) ? "Read & Write" : fm.isReadableFile(atPath: url.path) ? "Read only" : "No Access"
        return [("You (\(NSUserName()))", you),
                ((attributes[.ownerAccountName] as? String ?? "Owner") + " (owner)", access(mode >> 6 & 7)),
                ((attributes[.groupOwnerAccountName] as? String ?? "Group") + " (group)", access(mode >> 3 & 7)),
                ("Everyone", access(mode & 7)),
                ("Mode", String(format: "%03o", mode & 0o777))]
    }

    private func save() {
        let names = tags.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard names.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 255 }) else { error = "Tag names must be at most 255 UTF-8 bytes and cannot contain NUL."; return }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        do {
            let oldAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let wasLocked = oldAttributes[.immutable] as? Bool ?? false
            if wasLocked && locked { throw FolderComparison.Failure("Unlock this item and save first before editing other metadata.") }
            if wasLocked { try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
            try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
            var values = URLResourceValues()
            try (url as NSURL).setResourceValue(unique, forKey: .tagNamesKey)
            values.hasHiddenExtension = hiddenExtension
            var target = url
            try target.setResourceValues(values)
            try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
            message = "Metadata saved."
            load()
            NotificationCenter.default.post(name: Notification.Name("FinderPlusFilesChanged"), object: nil)
        } catch { self.error = "Metadata save failed; some earlier attributes may already have changed. Refresh to inspect: \(error.localizedDescription)"; message = "" }
    }
}
