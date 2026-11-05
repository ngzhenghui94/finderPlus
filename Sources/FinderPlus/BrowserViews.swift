import AppKit
import SwiftUI
import Quartz
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct BrowserRoot: View {
    @ObservedObject var workspace: Workspace
    var body: some View { BrowserWindowContent(workspace: workspace, pane: workspace.active) }
}

struct BrowserWindowContent: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var pane: BrowserPane
    @ObservedObject var preferences = AppPreferences.shared
    @FocusState private var searchFocused: Bool
    var body: some View {
        HSplitView {
            if workspace.sidebarVisible { SidebarView(workspace: workspace, pane: pane).frame(minWidth: 170, idealWidth: 205, maxWidth: 300) }
            VStack(spacing: 0) {
                if workspace.zoomed { PaneView(workspace: workspace, pane: workspace.active) }
                else { LayoutView(workspace: workspace, layout: workspace.layout) }
                if workspace.shelfVisible { Divider(); ShelfView(workspace: workspace) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(pane.url.path == "/" ? "Macintosh HD" : pane.url.lastPathComponent)
        .toolbar { toolbar }
        .searchable(text: $pane.query, placement: .toolbar, prompt: "Search by name or natural language")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { pane.runSearch() }
        .sheet(isPresented: $workspace.showQuickOpen) { QuickOpenView(workspace: workspace) }
        .onChange(of: preferences.showHidden) { _, _ in workspace.panes.forEach { $0.load(refresh: true) } }
        .onChange(of: pane.query) { _, _ in pane.runSearch() }
        .onChange(of: workspace.focusSearch) { _, _ in searchFocused = true }
    }
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { workspace.sidebarVisible.toggle() } label: { Label("Sidebar", systemImage: "sidebar.left") }.help("Toggle Sidebar")
            Button { pane.history(true) } label: { Label("Back", systemImage: "chevron.left") }.help("Back (⌘[)").disabled(!pane.canGoBack)
            Button { pane.history(false) } label: { Label("Forward", systemImage: "chevron.right") }.help("Forward (⌘])").disabled(!pane.canGoForward)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: Binding(get: { pane.mode }, set: { pane.mode = $0 })) {
                ForEach(BrowserMode.allCases, id: \.self) { mode in Label(mode.rawValue, systemImage: mode.symbol).tag(mode) }
            }.pickerStyle(.segmented).labelStyle(.iconOnly).help("View as Icons, List, Columns or Gallery")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Group By", selection: $preferences.groupBy) { ForEach(FileGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
                Divider()
                Picker("Sort By", selection: $pane.sortKey) { ForEach(["Name", "Modified", "Size", "Kind"], id: \.self) { Text($0 == "Modified" ? "Date Modified" : $0).tag($0) } }.pickerStyle(.inline)
                Toggle("Reverse Order", isOn: Binding(get: { !pane.ascending }, set: { pane.ascending = !$0 }))
            } label: { Label("Group and Sort", systemImage: "square.grid.3x1.below.line.grid.1x2") }.help("Group and Sort")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Single Pane") { workspace.preset(1) }
                Button("Side by Side") { workspace.preset(2) }
                Button("Four Panes") { workspace.preset(4) }
                Divider()
                Button("Split Right") { workspace.split(vertical: true) }
                Button("Split Left") { workspace.split(vertical: true, before: true) }
                Button("Split Down") { workspace.split(vertical: false) }
                Button("Split Up") { workspace.split(vertical: false, before: true) }
                Button(workspace.zoomed ? "Restore Panes" : "Zoom Active Pane") { workspace.zoomed.toggle() }
                Button("Close Active Pane") { workspace.closePane() }.disabled(workspace.panes.count == 1)
            } label: { Label("Pane Layout", systemImage: "rectangle.split.2x2") }.help("Pane Layout")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { workspace.addShelf() } label: { Label("Shelf", systemImage: "tray") }.help("Add Selection to Shelf")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { workspace.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .labelStyle(.titleAndIcon).help("New Folder (⇧⌘N)").accessibilityLabel("New Folder")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Folder…") { workspace.newFolder() }
                Button("Get Info") { workspace.info() }.disabled(pane.selection.isEmpty)
                Button("Quick Look") { workspace.preview() }.disabled(pane.selection.isEmpty)
                Button(workspace.previewVisible ? "Hide Preview" : "Show Preview") { workspace.previewVisible.toggle() }
                Divider()
                Button("Compare Folders…") { workspace.compare() }
                Button("Save Workspace…") { workspace.saveWorkspace() }
                Button("File Operations") { AppDelegate.shared.showOperations() }
                Divider()
                Button("Settings…") { AppDelegate.shared.showSettings() }
            } label: { Label("More", systemImage: "ellipsis.circle") }.help("More Actions")
        }
    }
}

struct LayoutView: View {
    @ObservedObject var workspace: Workspace
    let layout: PaneLayout
    var body: some View {
        switch layout {
        case .leaf(let id):
            if let pane = workspace.panes.first(where: { $0.id == id }) { PaneView(workspace: workspace, pane: pane) }
        case .split(let vertical, let first, let second):
            if vertical { HSplitView { AnyView(LayoutView(workspace: workspace, layout: first)); AnyView(LayoutView(workspace: workspace, layout: second)) } }
            else { VSplitView { AnyView(LayoutView(workspace: workspace, layout: first)); AnyView(LayoutView(workspace: workspace, layout: second)) } }
        }
    }
}

struct PaneView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var pane: BrowserPane
    @ObservedObject var preferences = AppPreferences.shared
    @FocusState private var filterFocused: Bool
    @State private var showFilter = false
    var body: some View {
        VStack(spacing: 0) {
            if pane.tabs.count > 1 || workspace.panes.count > 1 { tabStrip; Divider() }
            if workspace.pathVisible { breadcrumbs }
            if !pane.query.isEmpty { SearchSummary(pane: pane, workspace: workspace) }
            if showFilter {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter this folder", text: $pane.filter).textFieldStyle(.roundedBorder).focused($filterFocused)
                    Button("Clear") { workspace.activate(pane); pane.filter = "" }.disabled(pane.filter.isEmpty)
                    Button { workspace.activate(pane); pane.filter = ""; showFilter = false } label: {
                        Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Close Filter (Esc)").accessibilityLabel("Close Filter")
                }.padding(8)
                    .onExitCommand { pane.filter = ""; showFilter = false }
            }
            if !pane.error.isEmpty && pane.emptyState != .unavailable {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(pane.error).font(.callout); Spacer(); Button("Retry") { pane.load() } }.padding(12).foregroundStyle(.orange)
            }
            HSplitView {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .contextMenu { folderMenu }
                if workspace.previewVisible, let path = pane.selection.sorted().first {
                    FilePreview(entry: try? FileEntry(url: URL(fileURLWithPath: path)), compact: true).frame(minWidth: 200, idealWidth: 260, maxWidth: 400)
                }
            }
            if workspace.statusVisible {
                Divider()
                HStack(spacing: 8) {
                    if pane.loading || pane.search.isSearching { ProgressView().controlSize(.mini) }
                    if pane.slowLoad { Text("Waiting for macOS permission or a slow disk…").foregroundStyle(.orange).help("macOS may be asking for access to this folder, or a network disk is not responding.") }
                    else { Text(statusText) }
                    Spacer()
                    if pane.query.isEmpty { Text(availableSpace).lineLimit(1) }
                    else { Text(pane.search.status).lineLimit(1) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
            }
        }
        .frame(minWidth: 200, minHeight: 160)
        .background(Color(nsColor: .textBackgroundColor))
        .simultaneousGesture(TapGesture().onEnded { workspace.activate(pane) })
        .onHover { inside in if inside { workspace.hoveredPane = pane.id } else if workspace.hoveredPane == pane.id { workspace.hoveredPane = nil } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in acceptDrop(providers, destination: pane.url) }
        .onChange(of: workspace.focusFilter) { _, _ in if workspace.activeID == pane.id { showFilter.toggle(); if !showFilter { pane.filter = "" }; filterFocused = showFilter } }
    }
    var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs) { tab in
                        HStack(spacing: 0) {
                            Button { workspace.activate(pane); pane.selectTab(tab.id) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder.fill").foregroundStyle(.tint).font(.system(size: 12))
                                    Text(tab.url.path == "/" ? "Macintosh HD" : tab.url.lastPathComponent).lineLimit(1).truncationMode(.middle).font(.system(size: 12))
                                }.padding(.horizontal, 10).frame(minWidth: 90, maxWidth: 200, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.primary)
                                .accessibilityAddTraits(tab.id == pane.activeTab ? .isSelected : [])
                            if pane.tabs.count > 1 {
                                Button { workspace.activate(pane); pane.closeTab(tab.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 26, height: 30).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Close Tab").accessibilityLabel("Close \(tab.url.lastPathComponent) tab")
                            }
                        }.help(tab.url.path)
                            .background(tab.id == pane.activeTab ? Color(nsColor: .textBackgroundColor) : Color.clear)
                            .overlay(alignment: .top) { if tab.id == pane.activeTab && workspace.activeID == pane.id { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                            .contextMenu { Button("Close Tab") { pane.closeTab(tab.id) }; Button("Move Tab to New Pane") { workspace.activate(pane); pane.selectTab(tab.id); workspace.split(vertical: true, moveTab: true) } }
                    }
                }
            }
            Button { workspace.activate(pane); pane.newTab() } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("New Pane Tab").accessibilityLabel("New Pane Tab")
            Button { workspace.activate(pane); workspace.split(vertical: true) } label: { Image(systemName: "rectangle.split.2x1").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("Split Right").accessibilityLabel("Split Right")
            Button { workspace.activate(pane); workspace.split(vertical: false) } label: { Image(systemName: "rectangle.split.1x2").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("Split Down").accessibilityLabel("Split Down")
        }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 9).background(Color(nsColor: .controlBackgroundColor))
    }
    var statusText: String {
        let column = pane.mode == .columns && pane.query.isEmpty ? pane.columnEntries.last { $0.contains { pane.selection.contains($0.id) } } : nil
        let count = column.map { pane.sorted($0).count } ?? pane.shown.count
        return pane.selection.isEmpty ? "\(count) item\(count == 1 ? "" : "s")" : "\(pane.selection.count) of \(count) selected"
    }
    var availableSpace: String { if let value = try? pane.url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity { return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + " available" }; return "" }
    var breadcrumbs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(ancestors.enumerated()), id: \.offset) { index, url in
                        Button { workspace.activate(pane); pane.navigate(url) } label: {
                            HStack(spacing: 5) { if index == 0 { Image(systemName: "internaldrive") }; Text(url.path == "/" ? "Macintosh HD" : url.lastPathComponent) }
                                .font(.system(size: 11, weight: index == ancestors.count - 1 ? .semibold : .regular))
                                .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(index == ancestors.count - 1 ? Color.primary : Color.secondary).help(url.path).id(url.path)
                        if index < ancestors.count - 1 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary).accessibilityHidden(true) }
                    }
                }
                .padding(.horizontal, 6).frame(height: 34)
            }
            .onAppear { proxy.scrollTo(pane.url.path, anchor: .trailing) }
            .onChange(of: pane.url) { _, url in proxy.scrollTo(url.path, anchor: .trailing) }
        }
    }
    var ancestors: [URL] {
        var result: [URL] = [], url = pane.url
        while url.path != "/" && result.count < 30 { result.insert(url, at: 0); url.deleteLastPathComponent() }
        result.insert(URL(fileURLWithPath: "/"), at: 0); return result
    }
    @ViewBuilder var content: some View {
        if let emptyState = pane.emptyState {
            VStack(spacing: 12) {
                Image(systemName: emptyState.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(emptyState.rawValue).font(.headline)
                switch emptyState {
                case .folder:
                    Button("Create New Folder…") { workspace.activate(pane); workspace.newFolder() }
                case .filtered:
                    Text("No names match “\(pane.filter)”.").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    Button("Clear Filter") { workspace.activate(pane); pane.filter = "" }
                case .search, .searchNeedsAttention:
                    Text(emptyState == .searchNeedsAttention ? "Review the search warnings above, then try again or clear the search." : "Try fewer search terms or return to this folder.").font(.callout).foregroundStyle(.secondary)
                    if emptyState == .searchNeedsAttention { Button("Retry Search") { workspace.activate(pane); pane.runSearch() } }
                    Button("Clear Search") { workspace.activate(pane); pane.query = "" }
                case .unavailable:
                    Text(pane.error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Retry") { workspace.activate(pane); pane.load() }
                }
            }.multilineTextAlignment(.center).frame(maxWidth: 360).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pane.shown.isEmpty && (pane.loading || pane.search.isSearching) {
            ProgressView(pane.query.isEmpty ? "Loading folder…" : "Searching…").controlSize(.small).font(.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch pane.mode {
            case .list: list
            case .icons: icons
            case .columns: columns
            case .gallery: gallery
            }
        }
    }
    @ViewBuilder var folderMenu: some View {
        Button("New Folder…") { workspace.activate(pane); workspace.newFolder() }
        Button("Paste Here") { workspace.activate(pane); workspace.paste() }
    }
    var list: some View {
        Table(of: FileEntry.self, selection: $pane.selection) {
            TableColumn("Name") { item in
                HStack(spacing: 6) {
                    FileIcon(url: item.url, size: 18); Text(item.name).lineLimit(1); TagDots(tags: item.tags, colors: item.tagColors); cloud(item)
                    if !pane.query.isEmpty, item.url.deletingLastPathComponent().path != kernelPath(pane.url) { Text("in " + item.url.deletingLastPathComponent().lastPathComponent).foregroundStyle(.tertiary).lineLimit(1).help(item.url.deletingLastPathComponent().path) }
                }
                    .contextMenu { FileContextMenu(workspace: workspace, pane: pane, entry: item) }.onDrag { drag(item) }
            }.width(min: 140, ideal: 250)
            TableColumn("Date Modified") { item in Text(item.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).font(.system(size: 11)) }.width(min: 110, ideal: 160)
            TableColumn("Size") { item in Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary).font(.system(size: 11)) }.width(min: 55, ideal: 70)
            TableColumn("Kind") { item in Text(item.kind).foregroundStyle(.secondary).font(.system(size: 11)).lineLimit(1) }.width(min: 70, ideal: 115)
            TableColumn("Tags") { item in Text(item.tags.joined(separator: ", ")).foregroundStyle(.secondary).font(.system(size: 11)).lineLimit(1) }.width(min: 40, ideal: 90)
        } rows: {
            ForEach(groups, id: \.name) { group in
                if preferences.groupBy == .none { ForEach(group.entries) { TableRow($0) } }
                else { Section { ForEach(group.entries) { TableRow($0) } } header: { Text("\(group.name)  ·  \(group.entries.count)") } }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let entry = pane.shown.first(where: { $0.id == id }) { FileContextMenu(workspace: workspace, pane: pane, entry: entry) }
            else { Button("New Folder…") { workspace.activate(pane); workspace.newFolder() } }
        } primaryAction: { ids in workspace.activate(pane); workspace.open(ids.map { URL(fileURLWithPath: $0) }) }
    }
    var groups: [(name: String, entries: [FileEntry])] { preferences.groupBy.groups(pane.shown) }
    var icons: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: preferences.iconSize + 46), spacing: 14)], spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(group.entries) { item in
                            VStack(spacing: 6) { FileIcon(url: item.url, size: preferences.iconSize); HStack(spacing: 4) { TagDots(tags: item.tags, colors: item.tagColors); Text(item.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center) }; cloud(item) }
                                .padding(8).frame(maxWidth: .infinity).frame(height: preferences.iconSize + 65, alignment: .top)
                                .background(pane.selection.contains(item.id) ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle()).onTapGesture(count: 2) { workspace.activate(pane); workspace.open([item.url]) }
                                .onTapGesture { workspace.activate(pane); workspace.select(item) }
                                .help(item.url.path)
                                .contextMenu { FileContextMenu(workspace: workspace, pane: pane, entry: item) }.onDrag { drag(item) }
                                .onDrop(of: [.fileURL], isTargeted: nil) { item.isDirectory && acceptDrop($0, destination: item.url) }
                        }
                    } header: {
                        if preferences.groupBy != .none {
                            HStack { Text(group.name).font(.system(size: 11, weight: .semibold)); Text("\(group.entries.count)").font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }
                                .padding(.horizontal, 4).padding(.vertical, 5).background(.bar)
                        }
                    }
                }
            }.padding(18)
        }
    }
    var columns: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(pane.columnEntries.enumerated()), id: \.offset) { index, entries in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(pane.sorted(index == 0 && !pane.query.isEmpty ? pane.shown : entries)) { item in
                                HStack(spacing: 6) { FileIcon(url: item.url, size: 17); Text(item.name).font(.system(size: 12)).lineLimit(1); Spacer(); cloud(item); if item.isDirectory { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) } }
                                    .padding(.horizontal, 7).frame(height: 28).background(pane.selection.contains(item.id) || pane.columnFolders.contains(item.url) ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle()).onTapGesture(count: 2) { workspace.activate(pane); workspace.open([item.url]) }
                                    .onTapGesture { workspace.activate(pane); pane.chooseColumn(item, at: index) }
                                    .help(item.url.path)
                                    .contextMenu { FileContextMenu(workspace: workspace, pane: pane, entry: item) }.onDrag { drag(item) }
                            }
                        }.padding(6)
                    }.frame(width: 235)
                    Divider()
                }
                if let path = pane.selection.sorted().first { FilePreview(entry: try? FileEntry(url: URL(fileURLWithPath: path)), compact: true).frame(width: 280) }
            }
        }
    }
    var gallery: some View {
        VStack(spacing: 0) {
            FilePreview(entry: pane.shown.first(where: { pane.selection.contains($0.id) }) ?? pane.shown.first).frame(maxHeight: .infinity)
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(pane.shown) { item in
                        VStack { FileIcon(url: item.url, size: 64); Text(item.name).font(.system(size: 11)).lineLimit(1) }.padding(7).frame(width: 95).background(pane.selection.contains(item.id) ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle()).onTapGesture(count: 2) { workspace.activate(pane); workspace.open([item.url]) }.onTapGesture { workspace.activate(pane); workspace.select(item) }.help(item.url.path).contextMenu { FileContextMenu(workspace: workspace, pane: pane, entry: item) }.onDrag { drag(item) }
                    }
                }.padding(10)
            }.frame(height: 115)
        }
    }
    @ViewBuilder func cloud(_ item: FileEntry) -> some View {
        if !item.cloudStatus.isEmpty && item.cloudStatus != "Local" && item.cloudStatus != "Downloaded" {
            Image(systemName: "icloud").font(.system(size: 11)).foregroundStyle(.secondary).help(item.cloudStatus)
        }
    }
    func drag(_ item: FileEntry) -> NSItemProvider {
        workspace.activate(pane)
        if !pane.selection.contains(item.id) { pane.selection = [item.id] }
        let provider = NSItemProvider(object: item.url as NSURL)
        let urls = pane.selected
        provider.registerDataRepresentation(forTypeIdentifier: finderPlusFileListType, visibility: .ownProcess) { completion in
            do { completion(try JSONEncoder().encode(urls), nil) } catch { completion(nil, error) }
            return nil
        }
        return provider
    }
    func acceptDrop(_ providers: [NSItemProvider], destination: URL) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        return receiveFileDrop(providers) { urls in
            let destinationVolume = try? destination.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            let sameVolume = destinationVolume != nil && urls.allSatisfy { (try? $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject) == destinationVolume }
            FileOperations.shared.copy(urls, to: destination, move: flags.contains(.command) || (!flags.contains(.option) && sameVolume))
        }
    }
}

struct SearchSummary: View {
    @ObservedObject var pane: BrowserPane
    @ObservedObject var workspace: Workspace
    @ObservedObject var search: SearchService
    init(pane: BrowserPane, workspace: Workspace) { self.pane = pane; self.workspace = workspace; search = pane.search }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Search:").foregroundStyle(.secondary)
                if let roots = pane.savedSearchRoots {
                    Text("Saved scope: \(roots.count) folder(s)").help(roots.map(\.path).joined(separator: "\n"))
                    Button("This Folder") { pane.savedSearchRoots = nil; pane.searchAllRoots = false; pane.runSearch() }
                } else {
                    Picker("Scope", selection: $pane.searchAllRoots) { Text("This folder").tag(false); Text("Approved folders").tag(true) }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth: 240).onChange(of: pane.searchAllRoots) { _, _ in pane.runSearch() }
                }
                Spacer()
                Image(systemName: "info.circle").foregroundStyle(.secondary).help(search.plan.explanation).accessibilityLabel(search.plan.explanation)
                Button("Save Search…") { workspace.saveSearch() }.buttonStyle(.borderless)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(search.plan.filters) { filter in
                        HStack(spacing: 4) { Text(filter.label); Button { pane.query = pane.query.replacingOccurrences(of: filter.expression, with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove filter \(filter.label)") }.padding(.horizontal, 8).padding(.vertical, 4).background(Color.accentColor.opacity(0.12), in: Capsule()).contextMenu { Button("Edit Filter…") { if let text = prompt("Edit Filter", message: "Use natural language or an explicit operator.", value: filter.expression) { pane.query = pane.query.replacingOccurrences(of: filter.expression, with: text) } } }.help(filter.expression)
                    }
                }
            }
            if !search.plan.warnings.isEmpty { Text(search.plan.warnings.joined(separator: " · ")).foregroundStyle(.orange) }
        }.font(.system(size: 11)).padding(10).background(Color.accentColor.opacity(0.025))
    }
}

struct TagDots: View {
    let tags: [String]
    var colors: [String: Int] = [:]
    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: -3) {
                ForEach(tags.prefix(3), id: \.self) { tag in Circle().fill(tagColor(tag, index: colors[tag])).overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1)).frame(width: 9, height: 9) }
            }.help(tags.joined(separator: ", ")).accessibilityLabel("Tags: " + tags.joined(separator: ", "))
        }
    }
}
/// Uses the colour recorded with the tag; falls back to matching Finder's standard tag names; colourless tags are grey.
@MainActor func tagColor(_ name: String, index: Int? = nil) -> Color {
    let labels = NSWorkspace.shared.fileLabels, colors = NSWorkspace.shared.fileLabelColors
    // 0 means no colour was recorded (some tools write plain names), so fall back to the standard name.
    let resolved = index.flatMap { $0 > 0 ? $0 : nil } ?? labels.firstIndex(of: name) ?? 0
    return resolved > 0 && resolved < colors.count ? Color(nsColor: colors[resolved]) : .gray
}

struct FileIcon: View {
    let url: URL
    let size: Double
    @State private var thumbnail: NSImage?
    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size, height: size).accessibilityHidden(true)
            .overlay { if let glyph = folderGlyph(for: url) { Image(systemName: glyph).font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.black.opacity(0.3)).offset(y: size * 0.06) } }
            .task(id: "\(url.path)-\(size)") {
                guard size > 32, localPreviewAllowed(url) else { return }
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
                do { thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage }
                catch { thumbnail = nil }
            }
    }
}
/// SF Symbol for a plain folder whose name suggests its contents, like the glyphs on macOS's own Downloads or Pictures folders.
private let folderGlyphs: [(String, Set<String>)] = [
    ("photo", ["photo", "picture", "pic", "image", "img", "screenshot", "wallpaper", "camera"]),
    ("film", ["video", "movie", "film", "clip", "recording"]),
    ("music.note", ["music", "audio", "song", "podcast", "sound"]),
    ("arrow.down.circle", ["download"]),
    ("dollarsign.circle", ["invoice", "receipt", "finance", "tax", "taxes", "bank", "budget", "money"]),
    ("chevron.left.forwardslash.chevron.right", ["code", "src", "source", "dev", "developer", "repo", "git", "github"]),
    ("archivebox", ["backup", "archive"]),
    ("book", ["book", "ebook", "reading"]),
    ("graduationcap", ["school", "homework", "class", "course", "study", "university"]),
    ("briefcase", ["work", "office", "business", "client"]),
    ("airplane", ["travel", "trip", "vacation", "holiday"]),
    ("gamecontroller", ["game", "gaming"]),
    ("paintbrush", ["design", "art", "drawing", "sketch", "font"]),
    ("lock", ["private", "secret", "password", "key"]),
    ("doc.text", ["document", "doc", "report", "paper", "note", "letter", "contract"]),
]
func folderGlyph(named name: String) -> String? {
    let words = name.lowercased().split { !$0.isLetter }.map(String.init)
    return folderGlyphs.first { _, keys in words.contains { keys.contains($0) || ($0.hasSuffix("s") && keys.contains(String($0.dropLast()))) } }?.0
}
// macOS already draws glyphs on these folders.
private let systemGlyphFolders = Set([FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory, .moviesDirectory, .musicDirectory, .picturesDirectory, .applicationDirectory, .libraryDirectory, .developerDirectory, .sharedPublicDirectory]
    .flatMap { FileManager.default.urls(for: $0, in: [.userDomainMask, .localDomainMask]) }.map(\.standardizedFileURL.path))
private func folderGlyph(for url: URL) -> String? {
    guard let glyph = folderGlyph(named: url.lastPathComponent), !systemGlyphFolders.contains(url.standardizedFileURL.path),
          let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), values.isDirectory == true, values.isPackage != true else { return nil }
    return glyph
}
struct QuickPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PreviewHostView { let view = PreviewHostView(); view.url = url; return view }
    func updateNSView(_ view: PreviewHostView, context: Context) { view.url = url; view.updatePreview() }
    static func dismantleNSView(_ view: PreviewHostView, coordinator: ()) { view.closePreview() }
}

final class PreviewHostView: NSView {
    var url: URL?
    private var preview: QLPreviewView?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        closePreview()
        updatePreview()
    }
    func updatePreview() {
        guard window != nil, let url, localPreviewAllowed(url) else { closePreview(); return }
        if preview == nil {
            let child = QLPreviewView(frame: bounds, style: .normal)!
            child.shouldCloseWithWindow = false
            child.autostarts = true
            child.autoresizingMask = [.width, .height]
            addSubview(child)
            preview = child
        }
        if (preview?.previewItem as? NSURL) != url as NSURL { preview?.previewItem = url as NSURL }
    }
    func closePreview() {
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
    }
}
func localPreviewAllowed(_ url: URL) -> Bool {
    guard CloudLocations.isReadableLocally(url) else { return false }
    let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    return values?.ubiquitousItemDownloadingStatus != .notDownloaded
}

struct FilePreview: View {
    let entry: FileEntry?
    /// Side panels keep details right under a fixed-height preview; Gallery lets the preview fill the space.
    var compact = false
    var body: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 10) {
                if compact { QuickPreview(url: entry.url).frame(height: 240) } else { QuickPreview(url: entry.url).frame(minHeight: 100, maxHeight: .infinity) }
                Text(entry.name).font(.headline).textSelection(.enabled)
                Text(entry.kind + (entry.isDirectory ? "" : " · " + ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow { Text("Modified").foregroundStyle(.secondary); Text(entry.modified.formatted(date: .abbreviated, time: .shortened)) }
                    GridRow { Text("Created").foregroundStyle(.secondary); Text(entry.created.formatted(date: .abbreviated, time: .shortened)) }
                    if !entry.tags.isEmpty { GridRow { Text("Tags").foregroundStyle(.secondary); Text(entry.tags.joined(separator: ", ")) } }
                    if !entry.cloudStatus.isEmpty { GridRow { Text("Status").foregroundStyle(.secondary); Text(entry.cloudStatus) } }
                }.font(.system(size: 10))
                if compact { Spacer(minLength: 0) }
            }.padding(16)
        } else { Text("Select a file to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}
struct PreviewWindow: View {
    let urls: [URL]
    @State var initial: URL
    var body: some View { VStack { QuickPreview(url: initial); if urls.count > 1 { Picker("File", selection: $initial) { ForEach(urls, id: \.self) { Text($0.lastPathComponent).tag($0) } }.padding() } }.frame(minWidth: 400, minHeight: 300) }
}

struct FileContextMenu: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var pane: BrowserPane
    let entry: FileEntry
    func prepare() { workspace.activate(pane); if !pane.selection.contains(entry.id) { pane.selection = [entry.id] } }
    var body: some View {
        Button("Open") { prepare(); workspace.open() }
        if entry.isDirectory { Button("Open in New Tab") { prepare(); pane.newTab(entry.url) } }
        Button("Quick Look") { prepare(); workspace.preview() }
        Button("Get Info") { prepare(); workspace.info() }
        Divider()
        Button("New Folder…") { workspace.activate(pane); workspace.newFolder() }
        Button("Copy") { prepare(); workspace.copy() }
        Button("Paste Here") { prepare(); workspace.paste() }
        Button("Rename…") { prepare(); workspace.rename() }
        Button("Duplicate") { prepare(); FileOperations.shared.duplicate(pane.selected) }
        Button("Compress") { prepare(); FileOperations.shared.compress(pane.selected, in: pane.url) }
        Button("Make Alias") { prepare(); FileOperations.shared.makeAlias(pane.selected, in: pane.url) }
        Divider()
        Button("Add to Shelf") { prepare(); workspace.addShelf() }
        Button("Add to Sidebar") { workspace.addFavorite(entry.url) }
        if !entry.isDirectory { Button("Send to Nearby Mac…") { prepare(); NearbyShareService.shared.send(pane.selected) } }
        if let other = workspace.panes.first(where: { $0.id != pane.id }) {
            Button("Copy to Other Pane") { prepare(); FileOperations.shared.copy(pane.selected, to: other.url) }
            Button("Move to Other Pane") { prepare(); FileOperations.shared.copy(pane.selected, to: other.url, move: true) }
        }
        Button("Show in Finder") { prepare(); workspace.reveal() }
        Button("Copy Pathname") { prepare(); workspace.copy(path: true) }
        if CloudLocations.locations().contains(where: { entry.url.path.hasPrefix($0.path + "/") }) {
            Button("Download Now") { prepare(); CloudLocations.download(pane.selected) }
            Button("Remove Download…") { prepare(); CloudLocations.evict(pane.selected) }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { prepare(); FileOperations.shared.trash(pane.selected) }
    }
}

private let finderPlusFileListType = "com.icelemontees.finderplus.file-list"

/// One action for the whole drop: Finder sends one provider per file, and each must not become its own job and undo step.
@MainActor func receiveFileDrop(_ providers: [NSItemProvider], action: @escaping @MainActor ([URL]) -> Void) -> Bool {
    Task {
        do {
            var urls: [URL] = []
            for provider in providers { urls += try await droppedURLs(provider) }
            if !urls.isEmpty { action(urls) }
        } catch { explain("Cannot read the dragged files: \(error.localizedDescription)") }
    }
    return !providers.isEmpty
}

private func droppedURLs(_ provider: NSItemProvider) async throws -> [URL] {
    if provider.hasItemConformingToTypeIdentifier(finderPlusFileListType) {
        let data: Data = try await withCheckedThrowingContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: finderPlusFileListType) { data, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        let urls = try JSONDecoder().decode([URL].self, from: data)
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return urls
    }
    return try await withCheckedThrowingContinuation { done in
        _ = provider.loadObject(ofClass: NSURL.self) { value, error in
            if let error { done.resume(throwing: error) }
            else { done.resume(returning: (value as? URL).map { $0.isFileURL ? [$0] : [] } ?? []) }
        }
    }
}
