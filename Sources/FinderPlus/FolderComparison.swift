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
    struct Snapshot: Equatable {
        let url: URL
        let isDirectory: Bool
        let isSymlink: Bool
        let size: Int
        let modified: Date
        let digest: Data?

        init(_ url: URL, allowCloudDownloads: Bool) throws {
            self.url = url
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
                let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
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
        return FolderComparison(left: left, right: right, items: items, allowCloudDownloads: allowCloudDownloads)
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
    struct Copy: Identifiable {
        let source: URL
        let destination: URL
        let sourceSnapshot: Snapshot
        let destinationSnapshot: Snapshot?
        var id: String { destination.path }
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
            if source.isDirectory && items.contains(where: { $0.path.hasPrefix(item.path + "/") }) { continue }
            let destination = (useLeft ? right : left).appendingPathComponent(item.path, isDirectory: source.isDirectory)
            let existing = useLeft ? item.right : item.left
            result.append(Copy(source: source.url, destination: destination, sourceSnapshot: source, destinationSnapshot: existing))
        }
        return result.sorted { $0.destination.path < $1.destination.path }
    }

    func validate(_ copies: [Copy]) throws {
        for copy in copies {
            let current = try Snapshot(copy.source, allowCloudDownloads: allowCloudDownloads)
            guard current == copy.sourceSnapshot else { throw OperationFailure.message("Source changed since review: \(copy.source.path). Compare again.") }
            if let expected = copy.destinationSnapshot {
                guard try Snapshot(copy.destination, allowCloudDownloads: allowCloudDownloads) == expected else { throw OperationFailure.message("Destination changed since review: \(copy.destination.path). Compare again.") }
            } else {
                guard !FileManager.default.fileExists(atPath: copy.destination.path) else { throw OperationFailure.message("Destination appeared since review: \(copy.destination.path). Compare again.") }
            }
        }
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
        do { try comparison.validate(copies) } catch { return }
        throw OperationFailure.message("Stale comparison self-check failed")
    }
}
