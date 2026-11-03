import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences = AppPreferences.shared
    let home = FileManager.default.homeDirectoryForCurrentUser
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Button { workspace.active.query = "past 30 days"; workspace.active.searchAllRoots = true; workspace.active.runSearch() } label: { Label("Recents", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(SidebarButtonStyle(selected: false))
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
                            Button { workspace.applySearch(search) } label: { Label(search.name, systemImage: "line.3.horizontal.decrease.circle").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(SidebarButtonStyle(selected: false)).contextMenu { Button("Remove Saved Search") { workspace.savedSearches.removeAll { $0.id == search.id }; workspace.saveSidebar() } }
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
            HStack(spacing: 8) { Image(systemName: "folder.badge.plus").font(.system(size: 20)).foregroundStyle(.tint); Text("FinderPlus").font(.system(size: 12, weight: .semibold)); Spacer(); Button { AppDelegate.shared.showSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings") }.padding(14)
        }.background(.ultraThinMaterial)
        .contextMenu { Button("New Sidebar Group…") { workspace.newGroup() }; Button("Add Current Folder") { workspace.addFavorite() }; Button("Show Hidden Locations") { workspace.hiddenLocations = []; workspace.saveSidebar() } }
    }
    var volumes: [URL] { (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey], options: [.skipHiddenVolumes]) ?? []).filter { $0.path != "/" && !$0.path.hasPrefix("/System/") && !workspace.hiddenLocations.contains($0.path) } }
    func heading(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 19).padding(.bottom, 5).padding(.leading, 8) }
    func row(_ name: String, _ url: URL, _ icon: String, location: Bool = false) -> some View {
        Button { workspace.active.navigate(url) } label: { Label(name, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(SidebarButtonStyle(selected: workspace.active.url.standardizedFileURL == url.standardizedFileURL))
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
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 7).background(selected ? Color.primary.opacity(0.09) : configuration.isPressed ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6)) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Folder, tab, workspace — or > command", text: $query).textFieldStyle(.plain).focused($focused).onSubmit { if query.hasPrefix(">") || workspace.quickCommand { if let command = commands.first { runCommand(command) } } else if let url = folders.first { workspace.active.navigate(url); dismiss() } }; Button("Done") { dismiss() } }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if query.hasPrefix(">") || workspace.quickCommand { ForEach(commands, id: \.self) { title in Button(title) { runCommand(title) }.buttonStyle(.plain).padding(7).frame(maxWidth: .infinity, alignment: .leading) } }
                    else {
                        ForEach(folders, id: \.self) { url in Button { workspace.active.navigate(url); dismiss() } label: { HStack { Image(systemName: "folder"); VStack(alignment: .leading) { Text(url.lastPathComponent); Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(7) }.buttonStyle(.plain) }
                        ForEach(ranked(workspace.availableWorkspaces) { fuzzyScore(query.trimmingCharacters(in: .whitespaces), $0) }, id: \.self) { name in Button("Workspace: " + name) { workspace.openWorkspace(name); dismiss() }.buttonStyle(.plain).padding(7) }
                    }
                }
            }
        }.padding(20).frame(width: 560, height: 400).onAppear { focused = true; if workspace.quickCommand { query = "> " } }
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
