import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var pane: BrowserPane
    @ObservedObject var preferences = AppPreferences.shared
    let home = FileManager.default.homeDirectoryForCurrentUser
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Button { pane.savedSearchRoots = nil; pane.query = "past 30 days"; pane.searchAllRoots = true; pane.runSearch() } label: { Label("Recents", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(SidebarButtonStyle(selected: pane.query == "past 30 days" && pane.searchAllRoots && pane.savedSearchRoots == nil)).help("Files from the past 30 days in your approved search folders")
                    heading("Favorites")
                    row("Home", home, "house")
                    row("Desktop", home.appendingPathComponent("Desktop"), "desktopcomputer")
                    row("Applications", URL(fileURLWithPath: "/Applications"), "square.grid.2x2")
                    row("Documents", home.appendingPathComponent("Documents"), "doc")
                    row("Downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle")
                    row("Pictures", home.appendingPathComponent("Pictures"), "photo.on.rectangle")
                    ForEach(workspace.favorites.filter { $0.group == "Favorites" }) { favorite in favoriteRow(favorite) }
                    if !workspace.savedSearches.isEmpty {
                        heading("Saved Searches")
                        ForEach(workspace.savedSearches) { search in
                            Button { workspace.applySearch(search) } label: { Label(search.name, systemImage: "line.3.horizontal.decrease.circle").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(SidebarButtonStyle(selected: pane.query == search.query && pane.savedSearchRoots == search.roots)).help(search.query).contextMenu { Button("Remove Saved Search") { workspace.savedSearches.removeAll { $0.id == search.id }; workspace.saveSidebar() } }
                        }
                    }
                    ForEach(workspace.groups, id: \.self) { group in
                        heading(group).contextMenu { Button("Rename Group…") { if let name = prompt("Rename Group", message: "Only the sidebar changes.", value: group), !workspace.groups.contains(name) { workspace.groups = workspace.groups.map { $0 == group ? name : $0 }; for i in workspace.favorites.indices where workspace.favorites[i].group == group { workspace.favorites[i].group = name }; workspace.saveSidebar() } }; Button("Remove Group") { workspace.groups.removeAll { $0 == group }; for i in workspace.favorites.indices where workspace.favorites[i].group == group { workspace.favorites[i].group = "Favorites" }; workspace.saveSidebar() } }
                        ForEach(workspace.favorites.filter { $0.group == group }) { favorite in favoriteRow(favorite) }
                    }
                    heading("Locations")
                    row("Macintosh HD", URL(fileURLWithPath: "/"), "internaldrive")
                    ForEach(volumes, id: \.self) { url in row(url.lastPathComponent, url, "externaldrive", location: true) }
                    if preferences.showCloud {
                        ForEach(CloudLocations.locations().filter { !workspace.hiddenLocations.contains($0.path) }, id: \.self) { url in row(url.lastPathComponent == "com~apple~CloudDocs" ? "iCloud Drive" : url.lastPathComponent, url, "icloud", location: true) }
                    }
                    row("Network", URL(fileURLWithPath: "/Network"), "network")
                    Button { AppDelegate.shared.connectServer() } label: { Label("Connect to Server…", systemImage: "server.rack").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(SidebarButtonStyle(selected: false))
                    row("Trash", home.appendingPathComponent(".Trash"), "trash")
                    if !workspace.availableWorkspaces.isEmpty {
                        heading("Workspaces")
                        ForEach(workspace.availableWorkspaces, id: \.self) { name in Button { workspace.openWorkspace(name) } label: { Label(name, systemImage: "rectangle.split.2x2").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(SidebarButtonStyle(selected: false)).contextMenu { Button("Remove Workspace") { var values = UserDefaults.standard.dictionary(forKey: "workspaces") ?? [:]; values.removeValue(forKey: name); UserDefaults.standard.set(values, forKey: "workspaces"); workspace.objectWillChange.send() } } }
                    }
                }.padding(.horizontal, 10).padding(.top, 12)
            }
            Divider().padding(.horizontal, 12)
            HStack(spacing: 8) { Image(systemName: "folder.badge.plus").font(.system(size: 20)).foregroundStyle(.tint); Text("FinderPlus").font(.system(size: 12, weight: .semibold)); Spacer(); Button { AppDelegate.shared.showSettings() } label: { Image(systemName: "gearshape").frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings") }.padding(12)
        }.background(.ultraThinMaterial)
        .contextMenu { Button("New Sidebar Group…") { workspace.newGroup() }; Button("Add Current Folder") { workspace.addFavorite() }; Button("Show Hidden Locations") { workspace.hiddenLocations = []; workspace.saveSidebar() } }
    }
    var volumes: [URL] { (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey], options: [.skipHiddenVolumes]) ?? []).filter { $0.path != "/" && !$0.path.hasPrefix("/System/") && !workspace.hiddenLocations.contains($0.path) } }
    func heading(_ title: String) -> some View { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 4).padding(.leading, 8).accessibilityAddTraits(.isHeader) }
    func row(_ name: String, _ url: URL, _ icon: String, location: Bool = false) -> some View {
        Button { pane.navigate(url) } label: { Label(name, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(SidebarButtonStyle(selected: pane.query.isEmpty && pane.url.standardizedFileURL == url.standardizedFileURL))
            .help(url.path)
            .contextMenu {
                Button("Open in New Tab") { workspace.active.newTab(url) }
                Button("Get Info") { AppDelegate.shared.show(title: "Information", view: AnyView(InfoView(url: url)), size: NSSize(width: 520, height: 650)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if location { Button("Hide Location") { workspace.hiddenLocations.append(url.path); workspace.saveSidebar() }; Button("Eject") { workspace.eject(url) } }
            }
    }
    func favoriteRow(_ favorite: SidebarFavorite) -> some View {
        row(favorite.name, favorite.url, "folder").contextMenu {
            Button("Open in New Tab") { workspace.active.newTab(favorite.url) }
            Button("Rename Favorite…") { if let name = prompt("Rename Favorite", message: "The folder on disk keeps its name.", value: favorite.name), let index = workspace.favorites.firstIndex(where: { $0.id == favorite.id }) { workspace.favorites[index].name = name; workspace.saveSidebar() } }
            Menu("Move to Group") { ForEach(["Favorites"] + workspace.groups, id: \.self) { group in Button(group) { if let index = workspace.favorites.firstIndex(where: { $0.id == favorite.id }) { workspace.favorites[index].group = group; workspace.saveSidebar() } } } }
            Button("Remove from Sidebar") { workspace.favorites.removeAll { $0.id == favorite.id }; workspace.saveSidebar() }
        }
    }
}
struct SidebarButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(SidebarLabelStyle())
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 32)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.16) : Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 14)).foregroundStyle(.tint).frame(width: 20)
            configuration.title
        }
    }
}

struct ShelfView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Shelf", systemImage: "tray").font(.system(size: 12, weight: .semibold)); Text("\(workspace.shelf.count) collected").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Copy Here") { FileOperations.shared.copy(workspace.shelf, to: workspace.active.url) }.disabled(workspace.shelf.isEmpty); Button("Move Here…") { if confirm("Move \(workspace.shelf.count) collected items?", detail: "Files will leave their original folders and move into \(workspace.active.url.path).") { FileOperations.shared.copy(workspace.shelf, to: workspace.active.url, move: true) } }.disabled(workspace.shelf.isEmpty); Button("Clear") { workspace.shelf = [] }; Button { workspace.shelfVisible = false } label: { Image(systemName: "xmark") } }
            if workspace.shelf.isEmpty { Text("Collect files from different folders, then copy or move them together.").font(.caption).foregroundStyle(.secondary) }
            else { ScrollView(.horizontal) { HStack(spacing: 12) { ForEach(workspace.shelf, id: \.self) { url in HStack { FileIcon(url: url, size: 22); Text(url.lastPathComponent).font(.caption); Button { workspace.shelf.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }.padding(7).background(.background, in: RoundedRectangle(cornerRadius: 6)).help(url.path).onDrag { NSItemProvider(object: url as NSURL) } } } } }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            receiveFileDrop(providers) { urls in
                for url in urls where !workspace.shelf.contains(url) { workspace.shelf.append(url) }
            }
        }
    }
}

struct QuickOpenView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool
    var commands: [String] {
        let text = query.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
        return ranked(AppDelegate.shared.commandTitles) { fuzzyScore(text, $0) }
    }
    var folders: [URL] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return ranked(Array(Set(workspace.recent + workspace.favorites.map(\.url) + workspace.panes.flatMap { $0.tabs.map(\.url) })).sorted { $0.path < $1.path }) { url in
            fuzzyScore(text, url.lastPathComponent).map { $0 + 1 } ?? (text.isEmpty || url.path.localizedCaseInsensitiveContains(text) ? 0 : nil)
        }
    }
    enum Item: Hashable { case folder(URL), workspace(String), command(String) }
    /// Typing ">" switches to commands, like the command palette.
    var commandMode: Bool { query.hasPrefix(">") }
    var items: [Item] {
        if commandMode { return commands.map(Item.command) }
        return folders.map(Item.folder) + ranked(workspace.availableWorkspaces) { fuzzyScore(query.trimmingCharacters(in: .whitespaces), $0) }.map(Item.workspace)
    }
    @State private var highlighted = 0
    var body: some View {
        let results = items
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: commandMode ? "command" : "magnifyingglass").foregroundStyle(.secondary)
                TextField("Folder, tab, workspace — or > command", text: $query).textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { if results.indices.contains(highlighted) { run(results[highlighted]) } }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, results.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                Button("Done") { dismiss() }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element) { index, item in
                            Button { run(item) } label: { row(item).padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                                .background(index == highlighted ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .id(index)
                        }
                        if results.isEmpty { Text(commandMode ? "No matching commands" : "No matching folders or workspaces").foregroundStyle(.secondary).padding(8) }
                    }
                }.onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
            }
            Text("↑↓ to choose · Return to open · type > for commands").font(.caption).foregroundStyle(.tertiary)
        }.padding(20).frame(width: 560, height: 420)
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onAppear { focused = true; if workspace.quickCommand { query = "> " } }
    }
    @ViewBuilder func row(_ item: Item) -> some View {
        switch item {
        case .folder(let url): HStack { Image(systemName: "folder").foregroundStyle(.tint); VStack(alignment: .leading) { Text(url.path == "/" ? "Macintosh HD" : url.lastPathComponent); Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) } }
        case .workspace(let name): Label("Workspace: " + name, systemImage: "rectangle.split.2x2")
        case .command(let title): Label(title, systemImage: "command").labelStyle(.titleOnly)
        }
    }
    func run(_ item: Item) {
        switch item {
        case .folder(let url): workspace.active.navigate(url); dismiss()
        case .workspace(let name): workspace.openWorkspace(name); dismiss()
        case .command(let title): runCommand(title)
        }
    }
    func runCommand(_ title: String) { dismiss(); DispatchQueue.main.async { AppDelegate.shared.runCommand(title) } }
}

/// 3 prefix, 2 substring, 1 in-order letters ("dwn" → "Downloads"), nil no match. Case-insensitive.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let needle = query.lowercased(), haystack = text.lowercased()
    if needle.isEmpty { return 0 }
    if haystack.hasPrefix(needle) { return 3 }
    if haystack.contains(needle) { return 2 }
    var rest = Substring(needle)
    for character in haystack where character == rest.first { rest = rest.dropFirst(); if rest.isEmpty { return 1 } }
    return nil
}
/// Best score first; ties keep the input order.
func ranked<T>(_ items: [T], by score: (T) -> Int?) -> [T] {
    items.enumerated().compactMap { index, item in score(item).map { (item, $0, index) } }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
}

struct GoToFolderView: View {
    @ObservedObject var workspace: Workspace
    @State private var path = ""
    @State private var error = ""
    @FocusState private var focused: Bool
    var expanded: String { (path as NSString).expandingTildeInPath }
    var suggestions: [URL] {
        let url = URL(fileURLWithPath: expanded)
        let parent = path.hasSuffix("/") ? url : url.deletingLastPathComponent()
        let prefix = path.hasSuffix("/") ? "" : url.lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && (prefix.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(prefix)) }.sorted { $0.path < $1.path }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder").font(.headline)
            HStack { TextField("~/Documents", text: $path).focused($focused).onSubmit { go() }; Button("Go") { go() }.keyboardShortcut(.defaultAction) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            List(suggestions, id: \.self) { url in Button { path = url.path + "/" } label: { Label(url.lastPathComponent, systemImage: "folder") }.buttonStyle(.plain) }
        }.padding(20).onAppear { path = workspace.active.url.path + "/"; focused = true }
    }
    func go() { let url = URL(fileURLWithPath: expanded); var directory: ObjCBool = false; if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { workspace.active.navigate(url); NSApp.keyWindow?.close() } else { error = "This folder does not exist or is not accessible." } }
}
