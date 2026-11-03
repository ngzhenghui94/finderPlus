import Foundation
import CryptoKit

struct FolderComparison {
    enum Kind: String { case onlyLeft = "Only left", onlyRight = "Only right", different = "Different contents", typeConflict = "Type conflict", equal = "Identical" }
    struct Item: Identifiable {
        let path: String
        let left: Snapshot?
        let right: Snapshot?
        let kind: Kind
        var id: String { path }
        var canCopy: Bool { kind != .equal && kind != .typeConflict && left?.isSymlink != true && right?.isSymlink != true }
    }
    struct Snapshot: Equatable, Sendable {
        let url: URL
        let isDirectory: Bool
        let isSymlink: Bool
        let size: Int
        let modified: Date
        let digest: Data?

        init(_ url: URL, allowCloudDownloads: Bool) throws {
            self.url = url
            let url = URL(fileURLWithPath: url.path) // Read fresh metadata, not cached resource values from enumeration.
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            isSymlink = values.isSymbolicLink == true
            isDirectory = values.isDirectory == true && !isSymlink
            size = values.fileSize ?? 0
            modified = values.contentModificationDate ?? .distantPast
            if !isDirectory && !isSymlink {
                guard values.isRegularFile == true else { throw OperationFailure.message("Unsupported special file: \(url.path)") }
                if !allowCloudDownloads && (CloudLocations.isProviderURL(url) || (values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded)) {
                    throw OperationFailure.message("Comparison would read a cloud file: \(url.path). Enable cloud downloads explicitly, or download the files first.")
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: data)
                }
                digest = Data(hash.finalize())
                let after = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard after.fileSize == values.fileSize, after.contentModificationDate == values.contentModificationDate else { throw OperationFailure.message("File changed during comparison: \(url.path)") }
            } else if isSymlink {
                digest = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            } else { digest = nil }
        }
    }
    let left: URL
    let right: URL
    let items: [Item]
    let allowCloudDownloads: Bool
    /// Paths that contain other listed items, and type-conflict paths, computed once instead of per row.
    let folders: Set<String>
    let conflicts: Set<String>

    /// Folders with listed contents are synced item by item; anything under a type conflict needs manual resolution.
    func isSelectable(_ item: Item) -> Bool {
        item.canCopy && !folders.contains(item.path) && !ancestorPaths(item.path).contains(where: conflicts.contains)
    }

    static func compare(left: URL, right: URL, allowCloudDownloads: Bool = false) throws -> FolderComparison {
        let left = left.standardizedFileURL.resolvingSymlinksInPath()
        let right = right.standardizedFileURL.resolvingSymlinksInPath()
        guard left != right, !left.path.hasPrefix(right.path + "/"), !right.path.hasPrefix(left.path + "/") else { throw OperationFailure.message("Choose separate, non-nested folders.") }
        let a = try inventory(left, allowCloudDownloads: allowCloudDownloads)
        let b = try inventory(right, allowCloudDownloads: allowCloudDownloads)
        let items = Set(a.keys).union(b.keys).sorted().map { path -> Item in
            let lhs = a[path], rhs = b[path]
            let kind: Kind
            if let lhs, let rhs {
                if lhs.isDirectory != rhs.isDirectory || lhs.isSymlink != rhs.isSymlink { kind = .typeConflict }
                else if lhs.isDirectory { kind = .equal }
                else { kind = lhs.digest == rhs.digest ? .equal : .different }
            } else { kind = lhs == nil ? .onlyRight : .onlyLeft }
            return Item(path: path, left: lhs, right: rhs, kind: kind)
        }
        return FolderComparison(left: left, right: right, items: items, allowCloudDownloads: allowCloudDownloads,
                                folders: Set(items.flatMap { ancestorPaths($0.path) }),
                                conflicts: Set(items.filter { $0.kind == .typeConflict }.map(\.path)))
    }

    private static func inventory(_ root: URL, allowCloudDownloads: Bool) throws -> [String: Snapshot] {
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw OperationFailure.message("Not a directory: \(root.path)") }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw OperationFailure.message("Cannot read \(root.path)") }
        var items: [String: Snapshot] = [:]
        for case let enumeratedURL as URL in enumerator {
            try Task.checkCancellation()
            // FinderPlus undo storage is not user data; syncing it would be refused by the operation queue.
            // skipDescendants only after a folder: after a file it can skip a folder returned just before.
            if enumeratedURL.lastPathComponent.hasPrefix(".FinderPlus-") {
                if (try? enumeratedURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            // Normalize the parent, not the item: symlinks must remain symlinks.
            let url = enumeratedURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(enumeratedURL.lastPathComponent)
            guard url.path.hasPrefix(root.path + "/") else { throw OperationFailure.message("An enumerated item escaped the comparison folder.") }
            let snapshot = try Snapshot(url, allowCloudDownloads: allowCloudDownloads)
            items[String(url.path.dropFirst(root.path.count + 1))] = snapshot
        }
        if let error = enumerationError { throw error }
        return items
    }

    enum Direction: String, CaseIterable { case leftToRight = "Left → Right", rightToLeft = "Right → Left", both = "Both ways (newer wins)" }
    struct Copy: Identifiable, Sendable {
        let source: URL
        let destination: URL
        let sourceSnapshot: Snapshot
        let destinationSnapshot: Snapshot?
        let sourceRoot: URL
        let destinationRoot: URL
        var id: String { destination.path }

        func validate(allowCloudDownloads: Bool) throws {
            for (url, root) in [(source, sourceRoot), (destination, destinationRoot)] {
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                guard parent == root.path || parent.hasPrefix(root.path + "/") else {
                    throw OperationFailure.message("A comparison path now leaves its reviewed folder: \(url.path). Compare again.")
                }
            }
            let current = try Snapshot(source, allowCloudDownloads: allowCloudDownloads)
            guard current == sourceSnapshot else { throw OperationFailure.message("Source changed since review: \(source.path). Compare again.") }
            if current.isDirectory {
                guard try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty else {
                    throw OperationFailure.message("A reviewed empty folder now contains items: \(source.path). Compare again.")
                }
            }
            if let expected = destinationSnapshot {
                guard try Snapshot(destination, allowCloudDownloads: allowCloudDownloads) == expected else { throw OperationFailure.message("Destination changed since review: \(destination.path). Compare again.") }
            } else {
                guard try OperationSnapshot.capture(destination) == nil else { throw OperationFailure.message("Destination appeared since review: \(destination.path). Compare again.") }
            }
        }
    }

    func copies(selected: Set<String>, direction: Direction) throws -> [Copy] {
        var result: [Copy] = []
        for item in items where selected.contains(item.id) && item.kind != .equal {
            guard item.canCopy else { throw OperationFailure.message("Symlinks and type conflicts require manual resolution: \(item.path)") }
            let useLeft: Bool
            switch direction {
            case .leftToRight: useLeft = true
            case .rightToLeft: useLeft = false
            case .both:
                if item.left == nil { useLeft = false }
                else if item.right == nil { useLeft = true }
                else {
                    guard item.left!.modified != item.right!.modified else { throw OperationFailure.message("Different contents with equal modification dates; choose an explicit direction: \(item.path)") }
                    useLeft = item.left!.modified > item.right!.modified
                }
            }
            guard let source = useLeft ? item.left : item.right else { continue }
            // Parents are created by the operation queue; never implicitly copy unselected descendants.
            if source.isDirectory && folders.contains(item.path) { continue }
            let destination = (useLeft ? right : left).appendingPathComponent(item.path, isDirectory: source.isDirectory)
            let existing = useLeft ? item.right : item.left
            result.append(Copy(source: source.url, destination: destination, sourceSnapshot: source, destinationSnapshot: existing,
                               sourceRoot: useLeft ? left : right, destinationRoot: useLeft ? right : left))
        }
        return result.sorted { $0.destination.path < $1.destination.path }
    }

    func validate(_ copies: [Copy]) throws {
        for copy in copies { try copy.validate(allowCloudDownloads: allowCloudDownloads) }
    }

    static func selfCheck() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("FinderPlus-Comparison-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let left = base.appendingPathComponent("left"), right = base.appendingPathComponent("right")
        try fm.createDirectory(at: left.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: left.appendingPathComponent("changed"))
        try Data("rite".utf8).write(to: right.appendingPathComponent("changed"))
        try Data("same".utf8).write(to: left.appendingPathComponent("same"))
        try Data("same".utf8).write(to: right.appendingPathComponent("same"))
        try Data("new".utf8).write(to: left.appendingPathComponent("nested/new"))
        try fm.createDirectory(at: left.appendingPathComponent(".FinderPlus-\(UUID().uuidString)"), withIntermediateDirectories: false)
        try Data("held".utf8).write(to: left.appendingPathComponent(".FinderPlus-\(UUID().uuidString)"))
        // Links next to a folder must not hide its contents (skipDescendants after a non-folder used to).
        let linked = base.appendingPathComponent("linked"), empty = base.appendingPathComponent("empty")
        try fm.createDirectory(at: linked.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("needle".utf8).write(to: linked.appendingPathComponent("deep/needle"))
        for index in 0..<12 { try fm.createSymbolicLink(at: linked.appendingPathComponent("link\(index)"), withDestinationURL: linked.appendingPathComponent("deep")) }
        guard try compare(left: linked, right: empty).items.contains(where: { $0.path == "deep/needle" }) else { throw OperationFailure.message("Comparison skipped a folder next to symlinks") }
        let comparison = try compare(left: left, right: right)
        guard !comparison.items.contains(where: { $0.path.hasPrefix(".FinderPlus-") }) else { throw OperationFailure.message("Comparison listed FinderPlus undo storage") }
        guard comparison.items.first(where: { $0.path == "changed" })?.kind == .different,
              comparison.items.first(where: { $0.path == "same" })?.kind == .equal,
              comparison.items.first(where: { $0.path == "nested/new" })?.kind == .onlyLeft else { throw OperationFailure.message("Recursive comparison self-check failed") }
        let copies = try comparison.copies(selected: Set(comparison.items.map(\.id)), direction: .leftToRight)
        guard copies.count == 2 else { throw OperationFailure.message("Directory deduplication self-check failed") }
        try comparison.validate(copies)
        try Data("edited".utf8).write(to: right.appendingPathComponent("changed"))
        var staleRefused = false
        do { try comparison.validate(copies) } catch { staleRefused = true }
        guard staleRefused else { throw OperationFailure.message("Stale comparison self-check failed") }
        let emptySource = left.appendingPathComponent("reviewed-empty")
        try fm.createDirectory(at: emptySource, withIntermediateDirectories: false)
        let emptyComparison = try compare(left: left, right: right)
        let emptyCopies = try emptyComparison.copies(selected: ["reviewed-empty"], direction: .leftToRight)
        try emptyComparison.validate(emptyCopies)
        try Data("not reviewed".utf8).write(to: emptySource.appendingPathComponent("new-child"))
        guard let emptyCopy = emptyCopies.first else { throw OperationFailure.message("Missing empty-folder fixture") }
        let emptyPlan = try OperationPlannedCopy(source: emptyCopy.source, destination: emptyCopy.destination, reviewed: emptyCopy)
        var childRefused = false
        do { try emptyPlan.validate() } catch { childRefused = true }
        guard childRefused else { throw OperationFailure.message("Sync accepted unreviewed folder descendants") }
        let escapeLeft = base.appendingPathComponent("escape-left"), escapeRight = base.appendingPathComponent("escape-right")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: escapeLeft.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: escapeRight.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try Data("reviewed".utf8).write(to: escapeLeft.appendingPathComponent("sub/deep/file"))
        let escapeComparison = try compare(left: escapeLeft, right: escapeRight)
        let escapeCopies = try escapeComparison.copies(selected: ["sub/deep/file"], direction: .leftToRight)
        try fm.moveItem(at: escapeRight.appendingPathComponent("sub"), to: base.appendingPathComponent("original-sub"))
        try fm.createSymbolicLink(at: escapeRight.appendingPathComponent("sub"), withDestinationURL: outside)
        var escapeRefused = false
        do { try escapeComparison.validate(escapeCopies) } catch { escapeRefused = true }
        guard escapeRefused && !fm.fileExists(atPath: outside.appendingPathComponent("deep/file").path) else {
            throw OperationFailure.message("Comparison accepted a destination parent redirected outside its root")
        }
        let dangling = right.appendingPathComponent("nested/new")
        try fm.createDirectory(at: dangling.deletingLastPathComponent(), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: base.appendingPathComponent("missing-target").path)
        var danglingRefused = false
        do { try comparison.validate(copies.filter { $0.destination == dangling }) } catch { danglingRefused = true }
        guard danglingRefused else { throw OperationFailure.message("Comparison accepted a newly appeared dangling symlink") }
    }
}
