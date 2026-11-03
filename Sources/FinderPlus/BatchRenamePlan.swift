import Foundation

struct BatchRenamePlan {
    enum Mode: String, CaseIterable { case replace = "Replace text", add = "Add text", number = "Number" }
    struct Options: Equatable {
        var mode: Mode = .replace
        var find = ""
        var replacement = ""
        var prefix = ""
        var suffix = ""
        var start = 1
        var digits = 3
        var preserveExtension = true
    }
    struct Change: Identifiable {
        let url: URL
        let name: String
        var id: String { url.path }
        var changed: Bool { url.lastPathComponent != name }
    }

    static func make(urls: [URL], options: Options) throws -> [Change] {
        guard !urls.isEmpty else { throw OperationFailure.message("Select at least one item.") }
        guard options.start >= 0, (1...12).contains(options.digits), options.start <= Int.max - urls.count else { throw OperationFailure.message("Use a nonnegative starting number and 1–12 padding digits.") }
        if options.mode == .replace && options.find.isEmpty { throw OperationFailure.message("Enter the text to replace.") }
        let changes = try urls.enumerated().map { index, url -> Change in
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let ext = options.preserveExtension && !isDirectory ? url.pathExtension : ""
            let original = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            let stem: String
            switch options.mode {
            case .replace: stem = original.replacingOccurrences(of: options.find, with: options.replacement)
            case .add: stem = options.prefix + original + options.suffix
            case .number:
                let number = String(options.start + index)
                stem = options.prefix + String(repeating: "0", count: max(0, options.digits - number.count)) + number + options.suffix
            }
            guard !stem.isEmpty else { throw OperationFailure.message("“\(url.lastPathComponent)” would be left without a name.") }
            return Change(url: url, name: ext.isEmpty ? stem : stem + "." + ext)
        }
        try validate(changes)
        return changes
    }

    static func validate(_ changes: [Change]) throws {
        var destinations = Set<String>()
        var sources = Set<String>()
        for change in changes {
            let url = change.url.standardizedFileURL
            guard url.isFileURL, sources.insert(url.path).inserted else { throw OperationFailure.message("Duplicate or invalid source: \(url.path)") }
            try OperationsEngine.validName(change.name)
            if change.changed && url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == change.name.precomposedStringWithCanonicalMapping.lowercased() {
                throw OperationFailure.message("Case-only and Unicode-normalization-only renames are not supported: \(change.name)")
            }
            let target = url.deletingLastPathComponent().appendingPathComponent(change.name)
            // Conservative on case-sensitive disks too: never risk case-folding collisions on other volumes.
            let key = target.path.precomposedStringWithCanonicalMapping.lowercased()
            guard destinations.insert(key).inserted else { throw OperationFailure.message("Several items would become \(change.name).") }
            if change.changed && FileManager.default.fileExists(atPath: target.path) {
                throw OperationFailure.message("The destination already exists: \(target.path). Rename cycles and case-only renames are not supported.")
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw OperationFailure.message("Source is missing: \(url.path)") }
        }
        let paths = Set(changes.map { $0.url.standardizedFileURL.path })
        if paths.contains(where: { ancestorPaths($0).contains(where: paths.contains) }) {
            throw OperationFailure.message("Do not rename a folder and one of its descendants in the same batch.")
        }
    }

    static func selfCheck() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FinderPlus-Rename-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data().write(to: a)
        try Data().write(to: b)
        var options = Options()
        options.mode = .number
        options.prefix = "Photo-"
        let plan = try make(urls: [a, b], options: options)
        guard plan.map(\.name) == ["Photo-001.txt", "Photo-002.txt"] else { throw OperationFailure.message("Numbered rename self-check failed") }
        var emptied = Options(); emptied.find = "a"
        guard (try? make(urls: [a], options: emptied)) == nil else { throw OperationFailure.message("Empty-name rename self-check failed") }
        var rejected = 0
        for changes in [[Change(url: a, name: "b.txt")], [Change(url: a, name: "../bad")], [Change(url: a, name: "same"), Change(url: b, name: "SAME")]] {
            do { try validate(changes) } catch { rejected += 1 }
        }
        guard rejected == 3 else { throw OperationFailure.message("Rename collision self-check failed") }
    }
}
