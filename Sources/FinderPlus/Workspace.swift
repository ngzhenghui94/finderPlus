import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class Workspace: ObservableObject {
    @Published var panes: [BrowserPane]
    @Published var layout: PaneLayout
    @Published var activeID: UUID
    @Published var zoomed = false
    @Published var sidebarVisible = true
    @Published var shelfVisible = false
    @Published var previewVisible = false
    @Published var statusVisible = true
    @Published var pathVisible = true
    @Published var shelf: [URL] = []
    @Published var favorites: [SidebarFavorite] = []
    @Published var savedSearches: [SavedSearch] = []
    @Published var groups: [String] = []
    @Published var hiddenLocations: [String] = []
    @Published var recent: [URL] = []
    @Published var focusSearch = 0
    @Published var focusFilter = 0
    @Published var showQuickOpen = false
    @Published var quickCommand = false
    @Published var showOperations = false
    var hoveredPane: UUID?  // not published: hover must not re-render the window
    var paneUnderPointer: BrowserPane { panes.first { $0.id == hoveredPane } ?? active }
    private var observations: [NSObjectProtocol] = []
    private var persistTask: Task<Void, Never>?
    var active: BrowserPane { panes.first(where: { $0.id == activeID }) ?? panes[0] }
    var other: BrowserPane? { panes.first(where: { $0.id != activeID }) }
    var window: NSWindow?
    var availableWorkspaces: [String] { (UserDefaults.standard.dictionary(forKey: "workspaces") ?? [:]).keys.sorted() }
    init(snapshot: WorkspaceSnapshot? = nil) {
        let initial = BrowserPane()
        panes = snapshot?.panes.map { BrowserPane(snapshot: $0) } ?? [initial]
        layout = snapshot?.layout ?? .leaf(initial.id)
        activeID = snapshot?.active ?? initial.id
        favorites = Self.decode("favorites") ?? []
        savedSearches = Self.decode("savedSearches") ?? []
        groups = UserDefaults.standard.stringArray(forKey: "sidebarGroups") ?? []
        hiddenLocations = UserDefaults.standard.stringArray(forKey: "hiddenLocations") ?? []
        recent = Self.decode("recentFolders") ?? []
        attach()
        observations.append(NotificationCenter.default.addObserver(forName: Notification.Name("FinderPlusFilesChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.shelf.removeAll { !FileManager.default.fileExists(atPath: $0.path) } // moved, trashed or renamed away
                self?.panes.forEach { $0.search.cancel() }
                await SearchService.invalidateCache()
                self?.panes.forEach { $0.load(); if !$0.query.isEmpty { $0.runSearch() } }
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.favorites = Self.decode("favorites") ?? []
                self.savedSearches = Self.decode("savedSearches") ?? []
                self.groups = UserDefaults.standard.stringArray(forKey: "sidebarGroups") ?? []
                self.hiddenLocations = UserDefaults.standard.stringArray(forKey: "hiddenLocations") ?? []
                self.objectWillChange.send()
            }
        })
    }
    func attach() {
        for pane in panes { pane.changed = { [weak self] in self?.persist() }; pane.load() }
    }
    var snapshot: WorkspaceSnapshot { WorkspaceSnapshot(layout: layout, panes: panes.map(\.snapshot), active: activeID) }
    static func decode<T: Decodable>(_ key: String) -> T? { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    static func store<T: Encodable>(_ value: T, _ key: String) { if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) } }
    func persist() {
        if AppDelegate.shared?.restoringWindows != true { Self.store(AppDelegate.shared?.workspaces.map(\.snapshot) ?? [snapshot], "sessions") }
        let url = active.url
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(30))
        Self.store(recent, "recentFolders")
        objectWillChange.send()
    }
    func activate(_ pane: BrowserPane) { if activeID != pane.id { activeID = pane.id; persist() } }
    func split(vertical: Bool, before: Bool = false, moveTab: Bool = false) {
        guard panes.count < 16 else { explain("A window supports up to 16 panes."); return }
        let pane = BrowserPane(url: active.url); pane.mode = active.mode
        if moveTab && active.tabs.count > 1 { active.closeTab(active.activeTab) }
        pane.changed = { [weak self] in self?.persist() }; pane.load()
        layout = layout.splitting(activeID, with: pane.id, vertical: vertical, before: before)
        panes.append(pane); activeID = pane.id; zoomed = false; persist()
    }
    func closePane() {
        guard panes.count > 1, let next = layout.removing(activeID) else { return }
        panes.removeAll { $0.id == activeID }; layout = next; activeID = next.ids[0]; zoomed = false; persist()
    }
    func preset(_ count: Int) {
        while panes.count > 1 { closePane() }
        if count >= 2 { split(vertical: true) }
        if count == 4 { let first = panes[0].id; split(vertical: false); activeID = first; split(vertical: false) }
        persist()
    }
    func nextPane(_ offset: Int) { let ids = layout.ids; let i = ids.firstIndex(of: activeID) ?? 0; activeID = ids[(i + offset + ids.count) % ids.count]; persist() }
    func nextTab(_ offset: Int) { let tabs = active.tabs; let i = tabs.firstIndex(where: { $0.id == active.activeTab }) ?? 0; active.selectTab(tabs[(i + offset + tabs.count) % tabs.count].id) }
    func open(_ urls: [URL]? = nil) {
        for url in urls ?? active.selected {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map({ $0.isDirectory == true && $0.isPackage != true }) == true { active.navigate(url) }
            else if !NSWorkspace.shared.open(url) { explain("macOS could not open \(url.lastPathComponent).") }
        }
    }
    func preview() { guard let url = active.selected.first else { return }; AppDelegate.shared.show(title: url.lastPathComponent, view: AnyView(PreviewWindow(urls: active.selected, initial: url)), size: NSSize(width: 850, height: 620)) }
    func info() { guard let url = active.selected.first else { return }; AppDelegate.shared.show(title: "Information", view: AnyView(InfoView(url: url)), size: NSSize(width: 520, height: 650)) }
    func rename() {
        let urls = active.selected
        if urls.count > 1 { AppDelegate.shared.show(title: "Rename \(urls.count) Items", view: AnyView(BatchRenameView(urls: urls)), size: NSSize(width: 700, height: 480)) }
        else if let url = urls.first, let name = prompt("Rename", message: "Choose a new name for \(url.lastPathComponent).", value: url.lastPathComponent) { FileOperations.shared.rename(url, to: name) }
    }
    func newFolder(withSelection: Bool = false) {
        let parent = active.url
        let selected = withSelection ? active.selected : []
        guard let name = prompt("New Folder", message: "Create a folder in:\n\(parent.path)", value: "Untitled Folder", action: "Create") else { return }
        if withSelection {
            let destination = parent.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { explain("A folder with this name already exists."); return }
            FileOperations.shared.createFolder(in: parent, name: name)
            FileOperations.shared.copy(selected, to: destination, move: true)
        } else { FileOperations.shared.createFolder(in: parent, name: name) }
    }
    func copy(cut: Bool = false, path: Bool = false) {
        let urls = active.selected
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if path { NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
        else { NSPasteboard.general.writeObjects(urls as [NSURL]) }
        AppDelegate.shared.cutURLs = cut ? urls : []; AppDelegate.shared.cutChange = NSPasteboard.general.changeCount
    }
    func paste(move: Bool = false) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let cut = AppDelegate.shared.cutChange == board.changeCount && !AppDelegate.shared.cutURLs.isEmpty
            FileOperations.shared.copy(urls, to: active.url, move: move || cut)
            AppDelegate.shared.cutURLs = []
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff), let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) {
            savePasted(png, extension: "png")
        } else if let data = board.data(forType: .pdf) { savePasted(data, extension: "pdf") }
    }
    private func savePasted(_ data: Data, extension ext: String) {
        let url = active.url.appendingPathComponent("Pasted \(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")) \(UUID().uuidString.prefix(4)).\(ext)")
        do { try data.write(to: url, options: .withoutOverwriting); active.load() } catch { explain(error.localizedDescription) }
    }
    func goToFolder() {
        AppDelegate.shared.show(title: "Go to Folder", view: AnyView(GoToFolderView(workspace: self)), size: NSSize(width: 620, height: 390))
    }
    func addFavorite(_ url: URL? = nil) {
        let target = url ?? active.url
        favorites.append(SidebarFavorite(name: target.lastPathComponent, url: target, group: "Favorites")); saveSidebar()
    }
    func saveSidebar() { Self.store(favorites, "favorites"); Self.store(savedSearches, "savedSearches"); UserDefaults.standard.set(groups, forKey: "sidebarGroups"); UserDefaults.standard.set(hiddenLocations, forKey: "hiddenLocations") }
    func newGroup() { if let name = prompt("New Sidebar Group", message: "Group favorites without changing folders on disk.", value: "Projects"), !groups.contains(name), name != "Favorites" { groups.append(name); saveSidebar() } }
    func saveSearch() {
        guard !active.query.isEmpty, let name = prompt("Save Search", message: "Save this query and its search scope.", value: active.query) else { return }
        savedSearches.append(SavedSearch(name: name, query: active.query, roots: active.searchRoots)); saveSidebar()
    }
    func applySearch(_ search: SavedSearch) {
        if let root = search.roots.first { active.navigate(root) }
        active.savedSearchRoots = search.roots
        active.query = search.query
        active.runSearch()
    }
    func saveWorkspace() {
        guard let name = prompt("Save Workspace", message: "Remember all open browser windows, folders, tabs, views and split layouts.", value: "Workspace") else { return }
        var values = UserDefaults.standard.dictionary(forKey: "workspaces") ?? [:]
        if values[name] != nil && !confirm("Replace workspace “\(name)” ?", detail: "Only the saved layout is replaced. Your files are unchanged.") { return }
        values[name] = try? JSONEncoder().encode(AppDelegate.shared.workspaces.map(\.snapshot)); UserDefaults.standard.set(values, forKey: "workspaces"); objectWillChange.send()
    }
    func openWorkspace(_ name: String) {
        guard let data = UserDefaults.standard.dictionary(forKey: "workspaces")?[name] as? Data, let states = try? JSONDecoder().decode([WorkspaceSnapshot].self, from: data), !states.isEmpty else { explain("The saved workspace cannot be read."); return }
        AppDelegate.shared.restoreWindows(states)
    }
    func compare() {
        guard let other else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = "Choose a folder to compare with \(active.url.lastPathComponent)."
            if panel.runModal() == .OK, let url = panel.url { showCompare(url) }; return
        }
        showCompare(other.url)
    }
    func showCompare(_ right: URL) { AppDelegate.shared.show(title: "Compare Folders", view: AnyView(CompareFoldersView(left: active.url, right: right)), size: NSSize(width: 950, height: 600)) }
    func addShelf() { for url in active.selected where !shelf.contains(url) { shelf.append(url) }; shelfVisible = true }
    func eject(_ url: URL? = nil) {
        guard !FileOperations.shared.isBusy else { explain("Finish or stop file operations before ejecting a disk."); return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: url ?? active.url) } catch { explain(error.localizedDescription) }
    }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(active.selected.isEmpty ? [active.url] : active.selected) }
    func select(_ entry: FileEntry) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { if active.selection.contains(entry.id) { active.selection.remove(entry.id) } else { active.selection.insert(entry.id) }; active.selectionAnchor = entry.id }
        else if flags.contains(.shift), let anchor = active.selectionAnchor ?? active.selection.sorted().first, let a = active.displayed.firstIndex(where: { $0.id == anchor }), let b = active.displayed.firstIndex(of: entry) { active.selection = Set(active.displayed[min(a,b)...max(a,b)].map(\.id)) }
        else { active.selection = [entry.id]; active.selectionAnchor = entry.id }
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor func explain(_ text: String) { let alert = NSAlert(); alert.messageText = "FinderPlus"; alert.informativeText = text; alert.runModal() }
@MainActor func confirm(_ title: String, detail: String) -> Bool { let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel"); return alert.runModal() == .alertFirstButtonReturn }
@MainActor func prompt(_ title: String, message: String, value: String = "", action: String = "Save") -> String? {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
    let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 360, height: 24); alert.accessoryView = field
    field.setAccessibilityLabel("Name")
    alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
