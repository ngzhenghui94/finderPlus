import Foundation

@MainActor enum BrowserSelfCheck {
    static func run() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = PaneLayout.leaf(a).splitting(a, with: b, vertical: true).splitting(b, with: c, vertical: false, before: true)
        guard layout.ids == [a, c, b], layout.removing(c)?.ids == [a, b], PaneLayout.leaf(a).removing(a) == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tab = BrowserTab(url: home, mode: .gallery, back: [URL(fileURLWithPath: "/")], forward: [])
        let snapshot = WorkspaceSnapshot(layout: layout, panes: [PaneSnapshot(id: a, tabs: [tab], activeTab: tab.id)], active: a)
        let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        guard restored.layout.ids == layout.ids, restored.panes[0].tabs[0].back == tab.back, restored.panes[0].tabs[0].mode == .gallery else { throw CocoaError(.fileReadCorruptFile) }
        guard fuzzyScore("dwn", "Downloads") == 1, fuzzyScore("down", "Downloads") == 3, fuzzyScore("load", "Downloads") == 2, fuzzyScore("xyz", "Downloads") == nil,
              ranked(["d-o-w-n", "xdown", "Downloads", "Desktop"], by: { fuzzyScore("down", $0) }) == ["Downloads", "xdown", "d-o-w-n"] else { throw CocoaError(.validationStringPatternMatching) }
        guard explainFailure(CocoaError(.fileWriteOutOfSpace)).contains("disk is full"), explainFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))).contains("Get Info") else { throw CocoaError(.validationInvalidDate) }
        guard folderGlyph(named: "Photos") == "photo", folderGlyph(named: "Tax Reports 2025") == "dollarsign.circle", folderGlyph(named: "my_videos") == "film",
              folderGlyph(named: "Happy") == nil, folderGlyph(named: "Apps") == nil else { throw CocoaError(.validationInvalidDate) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderPlus-browser-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), calendar = Calendar.current
        func file(_ name: String, bytes: Int, daysAgo: Int) throws -> FileEntry {
            let url = root.appendingPathComponent(name)
            try Data(count: bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: calendar.date(byAdding: .day, value: -daysAgo, to: now)!], ofItemAtPath: url.path)
            return try FileEntry(url: url)
        }
        let entries = [try file("a.txt", bytes: 10, daysAgo: 0), try file("b.txt", bytes: 2_000_000, daysAgo: 1), try file("c.txt", bytes: 150_000, daysAgo: 5), try FileEntry(url: root.appendingPathComponent("folder"))]
        guard FileGrouping.modified.groups(Array(entries.prefix(3)), now: now).map(\.name) == ["Today", "Yesterday", "Previous 7 Days"],
              FileGrouping.size.groups(entries, now: now).map(\.name) == ["1 MB to 100 MB", "100 KB to 1 MB", "Under 100 KB", "Folders"],
              FileGrouping.none.groups(entries).first?.entries.count == 4,
              totalFileSize([root]) == 2_150_010 else { throw CocoaError(.validationNumberTooSmall) }
        var job = TransferJob(id: UUID(), title: "Copy")
        job.copiedBytes = 500_000_000; job.totalBytes = 1_000_000_000; job.bytesPerSecond = 100_000_000
        guard job.transferStats.contains("500 MB of 1 GB"), job.transferStats.contains("/s"), job.transferStats.contains("left") else { throw CocoaError(.validationNumberTooLarge) }
        print("Browser invariants: recursive splits, closing panes, session round-trip, grouping, fuzzy match, transfer stats PASS")
    }
}
