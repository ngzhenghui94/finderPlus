import Foundation

@MainActor enum BrowserSelfCheck {
    /// Columns keys: ↑ with nothing selected, → before and after a column loads, ↓, type-select and ← keep their column.
    static func columns() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FinderPlus-columns-check-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("a/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: false)
        for name in ["a/x.txt", "a/y.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        defer { try? fm.removeItem(at: root) }
        let pane = BrowserPane(url: root)
        // Listings may report the temp folder as /private/var/…, so match on the part below the root.
        func selected(_ relative: String) -> Bool { pane.selection.count == 1 && pane.selection.first!.hasSuffix(root.lastPathComponent + "/" + relative) }
        func wait(_ step: String, _ done: () -> Bool) async throws {
            for _ in 0..<300 { if done() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw OperationFailure.message("Columns self-check: \(step) (selection \(pane.selection.map { $0.components(separatedBy: root.lastPathComponent).last ?? $0 }), columns \(pane.columnEntries.map(\.count)))")
        }
        pane.load(); try await wait("root listing") { !pane.loading }
        _ = pane.moveInColumns(126); try await wait("↑ with nothing selected opens the first folder") { selected("a") && pane.columnEntries.count == 2 }
        _ = pane.moveInColumns(124); try await wait("→ selects the first child") { selected("a/inner") }
        _ = pane.moveInColumns(125); try await wait("↓ moves within the column") { selected("a/x.txt") && pane.columnEntries.count == 2 }
        pane.typeSelectInColumns("y"); try await wait("type-select stays in the active column") { selected("a/y.txt") && pane.columnEntries.count == 2 }
        _ = pane.moveInColumns(123); try await wait("← returns to the parent and keeps its column") { selected("a") && pane.columnEntries.count == 2 }
        // A change on disk (a finished operation or download) relists the open columns instead of closing them.
        try Data().write(to: root.appendingPathComponent("a/z.txt"))
        pane.load(refresh: true); try await wait("refresh keeps and relists open columns") { !pane.loading && selected("a") && pane.columnEntries.count == 2 && pane.columnEntries[1].count == 4 }
        pane.chooseColumn(pane.columnEntries[1].first { $0.name == "y.txt" }!, at: 1)
        try fm.removeItem(at: root.appendingPathComponent("a/y.txt"))
        pane.load(refresh: true); try await wait("refresh drops a deleted selection") { !pane.loading && pane.selection.isEmpty && pane.columnEntries.count == 2 && pane.columnEntries[1].count == 3 }
        pane.load(); try await wait("reload") { !pane.loading }
        pane.selection = []
        _ = pane.moveInColumns(125); _ = pane.moveInColumns(124) // → immediately, before the folder's column has loaded
        try await wait("→ before the column loads still lands inside it") { selected("a/inner") }
        print("Columns keys: ↑ ↓ ← →, early →, type-select PASS")
    }
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
        let tagged = root.appendingPathComponent("a.txt")
        let tagPlist = try PropertyListSerialization.data(fromPropertyList: ["Work\n4", "Red\n6"], format: .binary, options: 0)
        _ = tagPlist.withUnsafeBytes { setxattr(tagged.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, tagPlist.count, 0, 0) }
        guard try FileEntry(url: tagged).tagColors == ["Work": 4, "Red": 6] else { throw CocoaError(.validationInvalidDate) }
        // The sorted listing is cached; every input that changes it must refresh it.
        let pane = BrowserPane(url: root)
        pane.entries = entries
        let byName = pane.shown.map(\.name)
        pane.sortKey = "Size"; pane.ascending = false
        let bySize = pane.shown.filter { !$0.isDirectory }.map(\.name)
        pane.filter = "b"
        guard byName.contains("a.txt"), bySize == ["b.txt", "c.txt", "a.txt"], pane.shown.map(\.name) == ["b.txt"] else { throw CocoaError(.validationStringTooLong) }
        var auditFailures: [String] = []
        let duplicateName = try file("folder/a.txt", bytes: 10, daysAgo: 0)
        pane.filter = ""
        let ties = [entries[0], duplicateName]
        for key in ["Size", "Kind", "Modified"] {
            pane.sortKey = key
            for ascending in [true, false] {
                pane.ascending = ascending
                if pane.sorted(ties).map(\.id) != pane.sorted(Array(ties.reversed())).map(\.id) {
                    auditFailures.append("\(key) sorting depends on input order for equal names")
                }
            }
        }
        let missing = root.appendingPathComponent("temporarily-unavailable")
        for backward in [true, false] {
            let tab = BrowserTab(url: root, back: backward ? [missing] : [], forward: backward ? [] : [missing])
            let historyPane = BrowserPane(snapshot: PaneSnapshot(id: UUID(), tabs: [tab], activeTab: tab.id))
            historyPane.history(backward)
            if historyPane.url != root || historyPane.tabs[0].back != tab.back || historyPane.tabs[0].forward != tab.forward {
                auditFailures.append("Failed \(backward ? "Back" : "Forward") changes navigation history")
            }
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
            historyPane.history(backward)
            if historyPane.url.standardizedFileURL != missing.standardizedFileURL {
                auditFailures.append("Restored folder cannot be reached by retrying history")
            }
            historyPane.history(!backward)
            if historyPane.url.standardizedFileURL != root.standardizedFileURL {
                auditFailures.append("Successful history navigation loses the return path")
            }
            try FileManager.default.removeItem(at: missing)
        }
        pane.selection = [entries[0].id]
        pane.filter = "no matching file"
        if !pane.selected.isEmpty { auditFailures.append("Filtering leaves hidden files selected for file operations") }
        pane.filter = ""
        pane.selection = [entries[0].id]
        pane.query = "no matching file"
        if !pane.selected.isEmpty { auditFailures.append("Searching leaves the old folder selection active") }
        pane.query = ""
        pane.sortKey = "Name"; pane.ascending = true
        let visible = pane.displayed
        pane.selection = [visible[0].id]
        pane.moveSelection(by: 1, extending: true)
        pane.moveSelection(by: 1, extending: true)
        guard pane.selection == Set(visible.prefix(3).map(\.id)) else {
            throw OperationFailure.message("Repeated Shift–Down stops extending the selection")
        }
        pane.moveSelection(by: -1, extending: true)
        guard pane.selection == Set(visible.prefix(2).map(\.id)) else {
            throw OperationFailure.message("Reversing Shift–Down does not shrink the range")
        }
        pane.selection = [visible[1].id]
        pane.moveSelection(by: -1, extending: true)
        pane.moveSelection(by: 1, extending: true)
        pane.moveSelection(by: 1, extending: true)
        guard pane.selection == Set(visible[1...2].map(\.id)) else {
            throw OperationFailure.message("Keyboard range selection loses its anchor across direction changes")
        }
        let defaults = UserDefaults.standard
        let oldRecent = defaults.object(forKey: "recentFolders")
        let wasRestoring = AppDelegate.shared.restoringWindows
        AppDelegate.shared.restoringWindows = true
        defer {
            defaults.set(oldRecent, forKey: "recentFolders")
            AppDelegate.shared.restoringWindows = wasRestoring
        }
        let sourceTab = BrowserTab(url: root)
        let movingTab = BrowserTab(url: root.appendingPathComponent("folder"), mode: .gallery, back: [root], forward: [])
        let paneID = UUID()
        let workspace = Workspace(snapshot: WorkspaceSnapshot(layout: .leaf(paneID), panes: [PaneSnapshot(id: paneID, tabs: [sourceTab, movingTab], activeTab: movingTab.id)], active: paneID))
        workspace.split(vertical: true, moveTab: true)
        guard workspace.panes.count == 2, workspace.panes[0].tabs.map(\.id) == [sourceTab.id],
              workspace.active.tabs.first?.id == movingTab.id, workspace.active.mode == .gallery,
              workspace.active.tabs.first?.back == [root] else {
            throw OperationFailure.message("Moving a tab must preserve its view and navigation history")
        }
        let savedPane = PaneSnapshot(id: paneID, tabs: [sourceTab, movingTab], activeTab: sourceTab.id)
        let duplicateTabPane = PaneSnapshot(id: paneID, tabs: [sourceTab, sourceTab], activeTab: sourceTab.id)
        let brokenSnapshots = [
            WorkspaceSnapshot(layout: .leaf(paneID), panes: [], active: paneID),
            WorkspaceSnapshot(layout: .leaf(UUID()), panes: [savedPane], active: UUID()),
            WorkspaceSnapshot(layout: .leaf(paneID), panes: [savedPane, duplicateTabPane], active: paneID)
        ]
        for broken in brokenSnapshots {
            let restored = Workspace(snapshot: try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(broken)))
            let ids = restored.panes.map(\.id)
            guard !ids.isEmpty, Set(ids).count == ids.count, Set(restored.layout.ids) == Set(ids),
                  restored.layout.ids.count == ids.count, ids.contains(restored.activeID),
                  restored.panes.allSatisfy({ Set($0.tabs.map(\.id)).count == $0.tabs.count }) else {
                auditFailures.append("Malformed saved sessions leave invalid pane/tab identities or an unusable layout")
                continue
            }
            if !broken.panes.isEmpty {
                guard restored.panes.flatMap(\.tabs).map(\.url) == broken.panes.flatMap(\.tabs).map(\.url) else {
                    throw OperationFailure.message("Session recovery loses saved tabs")
                }
            }
            restored.nextPane(1)
            restored.preset(1)
            guard restored.panes.count == 1 else { throw OperationFailure.message("Recovered session cannot return to one pane") }
        }
        guard auditFailures.isEmpty else { throw OperationFailure.message(auditFailures.joined(separator: "; ")) }
        var job = TransferJob(id: UUID(), title: "Copy")
        job.copiedBytes = 500_000_000; job.totalBytes = 1_000_000_000; job.bytesPerSecond = 100_000_000
        guard job.transferStats.contains("500 MB of 1 GB"), job.transferStats.contains("/s"), job.transferStats.contains("left") else { throw CocoaError(.validationNumberTooLarge) }
        print("Browser invariants: recursive splits, closing panes, session round-trip, grouping, fuzzy match, transfer stats PASS")
    }
}
