import AppKit
import SwiftUI
import Combine

struct FileEntry: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String
    let tags: [String]
    /// Finder colour index per tag (0 none, 1 gray … 7 orange), from the same xattr Finder writes.
    let tagColors: [String: Int]
    let cloudStatus: String

    private static let ownKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .tagNamesKey]
    /// Everything `init` reads; prefetch these when listing so each file is not asked one key at a time.
    static let resourceKeys = ownKeys + CloudLocations.statusKeys

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: Set(Self.ownKeys))
        self.url = url
        name = url.lastPathComponent
        isDirectory = values.isDirectory == true && values.isPackage != true
        size = Int64(values.fileSize ?? 0)
        modified = values.contentModificationDate ?? .distantPast
        created = values.creationDate ?? .distantPast
        kind = values.localizedTypeDescription ?? (isDirectory ? "Folder" : url.pathExtension.uppercased() + " file")
        tags = values.tagNames ?? []
        tagColors = tags.isEmpty ? [:] : Self.tagColors(url)
        cloudStatus = CloudLocations.status(url)
    }
    static func tagColors(_ url: URL) -> [String: Int] {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 65_536 else { return [:] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return [:] }
        return Dictionary(list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1)
            return (String(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }, uniquingKeysWith: { first, _ in first })
    }
}

enum BrowserMode: String, CaseIterable, Codable {
    case icons = "Icons", list = "List", columns = "Columns", gallery = "Gallery"
    var symbol: String {
        switch self { case .icons: return "square.grid.2x2"; case .list: return "list.bullet"; case .columns: return "rectangle.split.3x1"; case .gallery: return "rectangle.bottomthird.inset.filled" }
    }
}

enum FileGrouping: String, CaseIterable, Codable {
    case none = "None", kind = "Kind", modified = "Date Modified", size = "Size", tags = "Tags"
    /// Groups keep the incoming (already sorted) order inside each group.
    func groups(_ entries: [FileEntry], now: Date = Date(), calendar: Calendar = .current) -> [(name: String, entries: [FileEntry])] {
        guard self != .none else { return [("", entries)] }
        var buckets: [String: (rank: Int, entries: [FileEntry])] = [:]
        for entry in entries {
            let key = bucket(entry, now: now, calendar: calendar)
            buckets[key.name, default: (key.rank, [])].entries.append(entry)
        }
        return buckets.sorted { $0.value.rank != $1.value.rank ? $0.value.rank < $1.value.rank : $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value.entries) }
    }
    private func bucket(_ entry: FileEntry, now: Date, calendar: Calendar) -> (rank: Int, name: String) {
        switch self {
        case .none: return (0, "")
        case .kind: return (0, entry.kind)
        case .tags: return entry.tags.first.map { (0, $0) } ?? (1, "No Tags")
        case .size:
            if entry.isDirectory { return (5, "Folders") }
            switch entry.size {
            case 1_000_000_000...: return (0, "Over 1 GB")
            case 100_000_000...: return (1, "100 MB to 1 GB")
            case 1_000_000...: return (2, "1 MB to 100 MB")
            case 100_000...: return (3, "100 KB to 1 MB")
            default: return (4, "Under 100 KB")
            }
        case .modified:
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.modified), to: calendar.startOfDay(for: now)).day ?? 0
            switch days {
            case ...0: return (0, "Today")
            case 1: return (1, "Yesterday")
            case 2...7: return (2, "Previous 7 Days")
            case 8...30: return (3, "Previous 30 Days")
            default:
                let year = calendar.component(.year, from: entry.modified)
                return (4 + max(0, calendar.component(.year, from: now) - year), String(year))
            }
        }
    }
}

struct BrowserTab: Identifiable, Codable {
    var id = UUID()
    var url: URL
    var mode: BrowserMode = .list
    var back: [URL] = []
    var forward: [URL] = []
}

struct PaneSnapshot: Codable {
    var id: UUID
    var tabs: [BrowserTab]
    var activeTab: UUID
}

indirect enum PaneLayout: Codable {
    case leaf(UUID)
    case split(vertical: Bool, first: PaneLayout, second: PaneLayout)
    var ids: [UUID] {
        switch self { case .leaf(let id): return [id]; case .split(_, let a, let b): return a.ids + b.ids }
    }
    func splitting(_ id: UUID, with new: UUID, vertical: Bool, before: Bool = false) -> PaneLayout {
        switch self {
        case .leaf(let current):
            guard current == id else { return self }
            return .split(vertical: vertical, first: .leaf(before ? new : id), second: .leaf(before ? id : new))
        case .split(let axis, let a, let b): return .split(vertical: axis, first: a.splitting(id, with: new, vertical: vertical, before: before), second: b.splitting(id, with: new, vertical: vertical, before: before))
        }
    }
    func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .leaf(let current): return current == id ? nil : self
        case .split(let axis, let a, let b):
            let left = a.removing(id), right = b.removing(id)
            if let left, let right { return .split(vertical: axis, first: left, second: right) }
            return left ?? right
        }
    }
}

struct WorkspaceSnapshot: Codable {
    var layout: PaneLayout
    var panes: [PaneSnapshot]
    var active: UUID
}

struct SidebarFavorite: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: URL
    var group: String
}
struct SavedSearch: Identifiable, Codable {
    var id = UUID()
    var name: String
    var query: String
    var roots: [URL]
}

@MainActor final class BrowserPane: ObservableObject, Identifiable {
    let id: UUID
    @Published var tabs: [BrowserTab]
    @Published var activeTab: UUID
    @Published var entries: [FileEntry] = [] { didSet { shownCache = nil } }
    @Published var slowLoad = false
    @Published var selection: Set<String> = [] {
        didSet {
            selectionCursor = nil
            if selection.count <= 1 { selectionAnchor = selection.first }
            else if let selectionAnchor, !selection.contains(selectionAnchor) { self.selectionAnchor = nil }
        }
    }
    @Published var error = ""
    @Published var loading = false
    @Published var query = "" { didSet { shownCache = nil; selection = [] } }
    @Published var filter = "" { didSet { shownCache = nil; selection = [] } }
    @Published var searchAllRoots = false
    @Published var savedSearchRoots: [URL]?
    var searchRoots: [URL] { savedSearchRoots ?? (searchAllRoots ? AppPreferences.shared.searchRoots : [url]) }
    @Published var sortKey = "Name" { didSet { shownCache = nil } }
    @Published var ascending = true { didSet { shownCache = nil } }
    @Published var columnFolders: [URL] = []
    @Published var columnEntries: [[FileEntry]] = []
    let search = SearchService(preferences: .shared)
    private var generation = UUID()
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadTimer: Timer?
    private var loadTask: Task<Result<[[FileEntry]], Error>, Never>?
    private var columnToken = UUID()
    private var searchTimer: Timer?
    private var searchObservation: AnyCancellable?
    var changed: (() -> Void)?
    var url: URL { tabs.first(where: { $0.id == activeTab })?.url ?? FileManager.default.homeDirectoryForCurrentUser }
    var mode: BrowserMode {
        get { tabs.first(where: { $0.id == activeTab })?.mode ?? .list }
        set { guard let index = tabs.firstIndex(where: { $0.id == activeTab }) else { return }; tabs[index].mode = newValue; changed?() }
    }
    init(snapshot: PaneSnapshot? = nil, url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        id = snapshot?.id ?? UUID()
        let tab = BrowserTab(url: url)
        tabs = snapshot?.tabs.isEmpty == false ? snapshot!.tabs : [tab]
        activeTab = snapshot?.activeTab ?? tab.id
        var seen = Set<UUID>()
        for index in tabs.indices where !seen.insert(tabs[index].id).inserted { tabs[index].id = UUID() }
        if !tabs.contains(where: { $0.id == activeTab }) { activeTab = tabs[0].id }
        searchObservation = search.objectWillChange.sink { [weak self] _ in self?.shownCache = nil; self?.objectWillChange.send() }
    }
    var snapshot: PaneSnapshot { PaneSnapshot(id: id, tabs: tabs, activeTab: activeTab) }
    var canGoBack: Bool { tabs.first(where: { $0.id == activeTab })?.back.isEmpty == false }
    var canGoForward: Bool { tabs.first(where: { $0.id == activeTab })?.forward.isEmpty == false }
    enum EmptyState: String {
        case folder = "This folder is empty"
        case filtered = "No files match this filter"
        case search = "No matching files"
        case searchNeedsAttention = "Search needs attention"
        case unavailable = "Couldn’t load this folder"
        var symbol: String {
            switch self {
            case .folder: return "folder"
            case .filtered: return "line.3.horizontal.decrease.circle"
            case .search: return "magnifyingglass"
            case .unavailable, .searchNeedsAttention: return "exclamationmark.triangle"
            }
        }
    }
    var emptyState: EmptyState? {
        guard shown.isEmpty, !loading, !search.isSearching else { return nil }
        if !error.isEmpty { return .unavailable }
        if !query.isEmpty, search.results.isEmpty, !search.plan.warnings.isEmpty { return .searchNeedsAttention }
        if !filter.isEmpty { return .filtered }
        return query.isEmpty ? .folder : .search
    }
    var selectionAnchor: String?
    private var selectionCursor: String?
    // Reveal the moving end of a keyboard range, not its stationary anchor.
    var selectionToReveal: String? { selectionCursor ?? (selection.count == 1 ? selection.first : nil) }
    var selected: [URL] { selection.sorted().map { URL(fileURLWithPath: $0) } }
    /// Sorted once per change of entries, results, filter or sort order, not on every redraw.
    private var shownCache: (foldersFirst: Bool, value: [FileEntry])?
    var shown: [FileEntry] {
        let foldersFirst = AppPreferences.shared.foldersFirst
        if let cache = shownCache, cache.foldersFirst == foldersFirst { return cache.value }
        let value = sorted(query.isEmpty ? entries : search.results)
        shownCache = (foldersFirst, value)
        return value
    }
    /// What the user sees, in order: grouped in List and Icons, so keyboard and shift-click follow the screen.
    var displayed: [FileEntry] { mode == .list || mode == .icons ? AppPreferences.shared.groupBy.groups(shown).flatMap(\.entries) : shown }
    func moveSelection(by delta: Int, extending: Bool) {
        let files = displayed
        guard !files.isEmpty else { return }
        let first = files.firstIndex { selection.contains($0.id) }
        let last = files.lastIndex { selection.contains($0.id) }
        let fallback: Int?
        if extending { fallback = selectionAnchor == first.map({ files[$0].id }) ? last : first }
        else { fallback = delta > 0 ? last : first }
        let old = files.firstIndex { $0.id == selectionCursor } ?? fallback ?? -1
        let next = min(max(old + delta, 0), files.count - 1)
        let anchorID = extending ? selectionAnchor ?? (old >= 0 ? files[old].id : files[next].id) : files[next].id
        let anchor = files.firstIndex { $0.id == anchorID } ?? next
        selection = Set(files[min(anchor, next)...max(anchor, next)].map(\.id))
        selectionAnchor = anchorID
        selectionCursor = files[next].id
    }
    /// Finder-style column keys: ↑↓ within the selected item's column, → into a folder, ← back to its parent column.
    func moveInColumns(_ key: UInt16) -> Bool {
        guard let column = selectedColumn, let id = selection.first else {
            guard [124, 125, 126].contains(key), let first = sorted(columnEntries.first ?? []).first else { return false }
            chooseColumn(first, at: 0); return true
        }
        let items = sorted(columnEntries[column])
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        switch key {
        case 125, 126: chooseColumn(items[min(max(index + (key == 125 ? 1 : -1), 0), items.count - 1)], at: column)
        case 124: if items[index].isDirectory { chooseColumn(items[index], at: column, selectFirst: true) } // works before its column has loaded
        case 123:
            if column > 0, let folder = try? FileEntry(url: columnFolders[column]) { chooseColumn(folder, at: column - 1) }
            else { navigate(url.deletingLastPathComponent()) }
        default: return false
        }
        return true
    }
    /// The column holding the single selected item.
    var selectedColumn: Int? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return columnEntries.lastIndex { $0.contains { $0.id == id } }
    }
    /// Type-to-select inside the column the user is working in, not always the first one.
    func typeSelectInColumns(_ prefix: String) {
        let column = selectedColumn ?? 0
        guard columnEntries.indices.contains(column),
              let match = sorted(columnEntries[column]).first(where: { $0.name.lowercased().hasPrefix(prefix.lowercased()) }) else { return }
        chooseColumn(match, at: column)
    }
    /// Lists a folder. An item that vanishes or can't be read between listing and reading is left out
    /// instead of failing the whole folder (Downloads does this whenever a download finishes).
    nonisolated static func listing(_ folder: URL, hidden: Bool) throws -> [FileEntry] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: FileEntry.resourceKeys, options: hidden ? [] : [.skipsHiddenFiles])
            .compactMap { try Task.checkCancellation(); return try? FileEntry(url: $0) }
    }
    func sorted(_ values: [FileEntry]) -> [FileEntry] {
        values.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.sorted {
            if AppPreferences.shared.foldersFirst && $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let less: Bool
            switch sortKey {
            case "Modified": less = $0.modified == $1.modified ? ($0.name, $0.id) < ($1.name, $1.id) : $0.modified < $1.modified
            case "Size": less = $0.size == $1.size ? ($0.name, $0.id) < ($1.name, $1.id) : $0.size < $1.size
            case "Kind": less = $0.kind == $1.kind ? ($0.name, $0.id) < ($1.name, $1.id) : $0.kind < $1.kind
            default:
                let order = $0.name.localizedStandardCompare($1.name)
                less = order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            return ascending ? less : !less && $0.id != $1.id
        }
    }
    @discardableResult func navigate(_ target: URL, record: Bool = true) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue else { error = "This folder is unavailable: \(target.path)"; return false }
        guard let index = tabs.firstIndex(where: { $0.id == activeTab }) else { return false }
        if record && target != url { tabs[index].back.append(url); tabs[index].forward = [] }
        tabs[index].url = target.standardizedFileURL
        query = ""; filter = ""; selection = []; savedSearchRoots = nil; search.cancel()
        load(); if record { changed?() }; return true
    }
    func history(_ backward: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTab }) else { return }
        let previous = url
        if backward, let next = tabs[i].back.last, navigate(next, record: false) {
            tabs[i].back.removeLast(); tabs[i].forward.append(previous); changed?()
        } else if !backward, let next = tabs[i].forward.last, navigate(next, record: false) {
            tabs[i].forward.removeLast(); tabs[i].back.append(previous); changed?()
        }
    }
    func newTab(_ target: URL? = nil) {
        let tab = BrowserTab(url: target ?? url, mode: mode)
        tabs.append(tab); activeTab = tab.id; query = ""; savedSearchRoots = nil; filter = ""; selection = []; search.cancel(); load(); changed?()
    }
    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        tabs.removeAll { $0.id == id }
        if activeTab == id { activeTab = tabs.last!.id; query = ""; savedSearchRoots = nil; filter = ""; selection = []; search.cancel(); load() }
        changed?()
    }
    func selectTab(_ id: UUID) { activeTab = id; query = ""; savedSearchRoots = nil; filter = ""; selection = []; search.cancel(); load(); changed?() }
    /// `refresh`: the same folder changed on disk, so keep the open columns and relist them instead of starting over.
    func load(refresh: Bool = false) {
        generation = UUID(); let token = generation, folder = url, hidden = AppPreferences.shared.showHidden
        if entries.first?.url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL { entries = []; selectionAnchor = nil }
        let open = refresh && columnFolders.first == folder ? columnFolders : [folder]
        loading = true; slowLoad = false; error = ""
        if open.count == 1 { columnFolders = [folder]; columnEntries = []; columnToken = UUID() }
        loadTask?.cancel()
        let work = Task.detached(priority: .userInitiated) { () -> Result<[[FileEntry]], Error> in
            Result {
                var lists = [try BrowserPane.listing(folder, hidden: hidden)]
                // A column whose folder was moved or deleted closes, with every column after it.
                for column in open.dropFirst() { guard let list = try? BrowserPane.listing(column, hidden: hidden) else { break }; lists.append(list) }
                return lists
            }
        }
        loadTask = work
        // A privacy prompt or a hung network disk blocks listing with no error; say so instead of spinning silently.
        Task { try? await Task.sleep(for: .seconds(3)); if generation == token && loading { slowLoad = true } }
        Task {
            let result = await work.value
            guard generation == token else { return }
            switch result {
            case .success(let lists):
                entries = lists[0]
                // Clicking another folder while relisting already replaced the columns; keep that newer choice.
                if columnFolders == open {
                    columnFolders = Array(open.prefix(lists.count)); columnEntries = lists; columnToken = UUID()
                    // Drop selected items that were renamed, moved or deleted, so later commands never act on stale paths.
                    let listed = Set(lists.joined().map(\.id))
                    if query.isEmpty, !selection.isSubset(of: listed) { selection = selection.intersection(listed) }
                } else if columnFolders.first == folder, !columnEntries.isEmpty { columnEntries[0] = lists[0] }
            case .failure(let failure): entries = []; error = failure.localizedDescription
            }
            loading = false; slowLoad = false
            watch(folder)
        }
    }
    private func watch(_ folder: URL) {
        watcher?.cancel(); watcher = nil
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: .main)
        // Coalesce bursts (a copy into this folder fires an event per file) into one reload.
        source.setEventHandler { [weak self] in
            self?.reloadTimer?.invalidate()
            self?.reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in Task { @MainActor in self?.load(refresh: true) } }
        }
        source.setCancelHandler { close(fd) }; watcher = source; source.resume()
    }
    func runSearch() {
        searchTimer?.invalidate()
        guard !query.isEmpty else { search.cancel(); return }
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let preferences = AppPreferences.shared
                let roots = self.searchRoots
                let approved = contentScopeApproved(roots)
                self.search.search(self.query, roots: roots, includeHidden: preferences.showHidden, contentEnabled: preferences.contentEnabled && approved, ocrEnabled: preferences.ocrEnabled && approved)
            }
        }
    }
    /// `selectFirst`: once the folder's column is showing, select its first item (→ in Columns).
    func chooseColumn(_ entry: FileEntry, at index: Int, selectFirst: Bool = false) {
        selection = [entry.id]
        let token = UUID(); columnToken = token
        // The folder's column is already open (← back to it, or → right after it loaded): keep it, don't list it again.
        if entry.isDirectory, columnFolders.indices.contains(index + 1), columnEntries.indices.contains(index + 1), columnFolders[index + 1] == entry.url {
            columnFolders = Array(columnFolders.prefix(index + 2)); columnEntries = Array(columnEntries.prefix(index + 2))
            if selectFirst, let first = sorted(columnEntries[index + 1]).first { chooseColumn(first, at: index + 1) }
            return
        }
        columnFolders = Array(columnFolders.prefix(index + 1)); columnEntries = Array(columnEntries.prefix(index + 1))
        guard entry.isDirectory else { return }
        let folder = entry.url, hidden = AppPreferences.shared.showHidden
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[FileEntry], Error> in
                Result { try BrowserPane.listing(folder, hidden: hidden) }
            }.value
            guard columnToken == token else { return }
            switch result {
            case .success(let files):
                columnFolders.append(folder); columnEntries.append(files)
                if selectFirst, let first = sorted(files).first { chooseColumn(first, at: index + 1) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    deinit { watcher?.cancel(); searchTimer?.invalidate(); reloadTimer?.invalidate() }
}

@MainActor func contentScopeApproved(_ roots: [URL]) -> Bool {
    roots.allSatisfy { root in
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        return AppPreferences.shared.searchRoots.contains { approved in
            let base = approved.resolvingSymlinksInPath().standardizedFileURL.path
            return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
        }
    }
}
