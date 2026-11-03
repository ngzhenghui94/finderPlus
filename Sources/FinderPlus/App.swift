import AppKit
import SwiftUI
import Combine

@main struct FinderPlusMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    var workspaces: [Workspace] = []
    var windows: [NSWindow] = []
    var actions: [MenuAction] = []
    var commands: [String: () -> Void] = [:]
    var originalKeys: [String: (String, NSEvent.ModifierFlags)] = [:]
    var cutURLs: [URL] = []
    var cutChange = -1
    var monitor: Any?
    var subscriptions: Set<AnyCancellable> = []
    weak var lastBrowser: Workspace?
    var restoringWindows = false
    var typedName = ""
    var lastTyped = Date.distantPast
    var active: Workspace? { workspaces.first { $0.window === NSApp.mainWindow } ?? (workspaces.contains(where: { $0 === lastBrowser }) ? lastBrowser : workspaces.last) }
    var commandTitles: [String] { commands.keys.sorted() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-check") {
            Task {
                do {
                    try BrowserSelfCheck.run()
                    try await BrowserSelfCheck.columns()
                    try await NaturalQuery.selfCheck()
                    try FolderComparison.selfCheck()
                    try BatchRenamePlan.selfCheck()
                    try await FileOperations.selfCheck()
                    try await NearbyShare.selfCheck()
                    print("FinderPlus self-check: PASS (search, comparison, rename, safe file operations, nearby share)")
                    exit(0)
                } catch { fputs("FinderPlus self-check FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        buildMenus()
        NearbyShareService.shared.update(enabled: AppPreferences.shared.nearbyEnabled)
        restoreWindows(Workspace.decode("sessions") ?? [])
        FileOperations.shared.$jobs.map(\.count).removeDuplicates().dropFirst().sink { [weak self] count in
            if count > 0 { DispatchQueue.main.async { self?.showOperations() } }
        }.store(in: &subscriptions)
        FileOperations.shared.$recoveryItems.sink { [weak self] items in
            if !items.isEmpty { DispatchQueue.main.async { self?.showOperations() } }
        }.store(in: &subscriptions)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseUp, .swipe]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    func newWindow(snapshot: WorkspaceSnapshot? = nil, tabbed: Bool = false) {
        let workspace = Workspace(snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FinderPlus"; window.toolbarStyle = .unified
        window.minSize = NSSize(width: 800, height: 520)
        window.tabbingMode = .preferred; window.tabbingIdentifier = "FinderPlusBrowser"
        let host = NSHostingView(rootView: BrowserRoot(workspace: workspace))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.isReleasedWhenClosed = false; window.delegate = self
        workspace.window = window
        if tabbed, let previous = active?.window { previous.addTabbedWindow(window, ordered: .above) }
        workspaces.append(workspace); windows.append(window)
        window.center(); window.makeKeyAndOrderFront(nil); workspace.persist()
    }
    func show(title: String, view: AnyView, size: NSSize) {
        if ["FinderPlus Settings", "File Operations", "FinderPlus Help"].contains(title), let existing = windows.first(where: { $0.title == title }) { existing.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.contentView = NSHostingView(rootView: view); window.isReleasedWhenClosed = false; window.delegate = self
        windows.append(window); window.center(); window.makeKeyAndOrderFront(nil)
    }
    func showSettings() { show(title: "FinderPlus Settings", view: AnyView(SettingsView()), size: NSSize(width: 684, height: 494)) }
    func showOperations() { show(title: "File Operations", view: AnyView(OperationsPanel()), size: NSSize(width: 680, height: 530)) }
    func restoreWindows(_ states: [WorkspaceSnapshot]) {
        restoringWindows = true
        let old = workspaces.compactMap(\.window)
        old.forEach { $0.close() }
        if states.isEmpty { newWindow() } else { states.forEach { newWindow(snapshot: $0) } }
        restoringWindows = false
        active?.persist()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { restoreWindows(Workspace.decode("sessions") ?? []) }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !FileOperations.shared.isBusy else { explain("File operations are still running or paused. Finish or stop them before quitting."); showOperations(); return .terminateCancel }
        active?.persist(); return .terminateNow
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let workspace = workspaces.first(where: { $0.window === window }) { workspace.persist(); workspaces.removeAll { $0 === workspace } }
        windows.removeAll { $0 === window }
    }
    func windowDidBecomeMain(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let workspace = workspaces.first(where: { $0.window === window }) { lastBrowser = workspace; workspace.objectWillChange.send() }
    }
    func connectServer() {
        guard let text = prompt("Connect to Server", message: "Enter an SMB, AFP or NFS server address.", value: "smb://"), let url = URL(string: text), ["smb", "afp", "nfs"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return }
        NSWorkspace.shared.open(url)
    }
    func runCommand(_ title: String) { commands[title]?() }
    func performTextCommand(_ title: String) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        switch title {
        case "Cut": editor.cut(nil)
        case "Copy": editor.copy(nil)
        case "Paste": editor.paste(nil)
        case "Select All": editor.selectAll(nil)
        case "Undo": if let manager = editor.undoManager, manager.canUndo { manager.undo() }
        case "Redo": if let manager = editor.undoManager, manager.canRedo { manager.redo() }
        default: return false
        }
        return true
    }
    func buildMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; let sub = NSMenu(title: title); item.submenu = sub; bar.addItem(item); return sub }
        func add(_ menu: NSMenu, _ title: String, _ key: String = "", _ flags: NSEvent.ModifierFlags = .command, _ action: @escaping () -> Void) {
            let dispatch = { if !self.performTextCommand(title) { action() } }
            let target = MenuAction(dispatch); actions.append(target); commands[title] = dispatch
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: key); item.target = target; item.keyEquivalentModifierMask = flags; menu.addItem(item); originalKeys[title] = (key, flags)
        }
        let app = menu("FinderPlus")
        add(app, "About FinderPlus") { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "FinderPlus", .applicationVersion: "1.0", .credits: NSAttributedString(string: "A native file manager. Local search. Your files stay yours.")]) }
        add(app, "Settings…", ",") { self.showSettings() }
        app.addItem(.separator())
        let services = NSMenu(); let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: ""); servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        let hide = NSMenuItem(title: "Hide FinderPlus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); app.addItem(hide)
        app.addItem(.separator()); add(app, "Quit FinderPlus", "q") { NSApp.terminate(nil) }
        let file = menu("File")
        add(file, "New Window", "n") { self.newWindow() }
        add(file, "New Window Tab", "t") { self.newWindow(tabbed: true) }
        add(file, "New Pane Tab", "t", [.command, .control, .option]) { self.active?.active.newTab() }
        add(file, "Open", "o") { self.active?.open() }
        add(file, "New Folder…", "n", [.command, .shift]) { self.active?.newFolder() }
        add(file, "New Folder with Selection…", "n", [.command, .control]) { self.active?.newFolder(withSelection: true) }
        add(file, "Rename…") { self.active?.rename() }
        add(file, "Duplicate", "d") { if let w = self.active { FileOperations.shared.duplicate(w.active.selected) } }
        add(file, "Compress") { if let w = self.active { FileOperations.shared.compress(w.active.selected, in: w.active.url) } }
        add(file, "Send to Nearby Mac…") { if let w = self.active { NearbyShareService.shared.send(w.active.selected) } }
        add(file, "Make Alias", "a", [.command, .control]) { if let w = self.active { FileOperations.shared.makeAlias(w.active.selected, in: w.active.url) } }
        add(file, "Move to Trash…", "\u{8}") { if let w = self.active { FileOperations.shared.trash(w.active.selected) } }
        add(file, "Put Back") { if let urls = self.active?.active.selected { FileOperations.shared.putBack(urls) } }
        file.addItem(.separator())
        add(file, "Get Info", "i") { self.active?.info() }
        add(file, "Quick Look", "y") { self.active?.preview() }
        add(file, "Show in Finder") { self.active?.reveal() }
        add(file, "Compare Folders…") { self.active?.compare() }
        add(file, "Download Now") { if let urls = self.active?.active.selected { CloudLocations.download(urls) } }
        add(file, "Remove Download…") { if let urls = self.active?.active.selected { CloudLocations.evict(urls) } }
        add(file, "Eject", "e") { self.active?.eject() }
        add(file, "Close", "w") { if let w = self.active, NSApp.keyWindow === w.window, w.active.tabs.count > 1 { w.active.closeTab(w.active.activeTab) } else { NSApp.keyWindow?.performClose(nil) } }
        let edit = menu("Edit")
        add(edit, "Undo", "z") { FileOperations.shared.undo() }
        add(edit, "Redo", "z", [.command, .shift]) { FileOperations.shared.redo() }
        edit.addItem(.separator())
        add(edit, "Cut", "x") { if AppPreferences.shared.keyboardProfile != "Finder" { self.active?.copy(cut: true) } }
        add(edit, "Copy", "c") { self.active?.copy() }
        add(edit, "Paste", "v") { self.active?.paste() }
        add(edit, "Move Item Here", "v", [.command, .option]) { self.active?.paste(move: true) }
        add(edit, "Copy as Pathname", "c", [.command, .option]) { self.active?.copy(path: true) }
        add(edit, "Select All", "a") { if let pane = self.active?.active { pane.selection = Set(pane.shown.map(\.id)) } }
        let view = menu("View")
        for (i, mode) in BrowserMode.allCases.enumerated() { add(view, "as " + mode.rawValue, String(i + 1)) { self.active?.active.mode = mode } }
        view.addItem(.separator())
        for key in ["Name", "Modified", "Size", "Kind"] { add(view, "Sort by " + key) { self.active?.active.sortKey = key } }
        add(view, "Reverse Sort") { self.active?.active.ascending.toggle() }
        for grouping in FileGrouping.allCases { add(view, grouping == .none ? "Don't Group" : "Group by " + grouping.rawValue) { AppPreferences.shared.groupBy = grouping } }
        add(view, "Show View Options", "j") { self.showSettings() }
        add(view, "Increase Icon Size", "+") { AppPreferences.shared.iconSize = min(160, AppPreferences.shared.iconSize + 8) }
        add(view, "Decrease Icon Size", "-") { AppPreferences.shared.iconSize = max(32, AppPreferences.shared.iconSize - 8) }
        add(view, "Toggle Hidden Files", ".", [.command, .shift]) { AppPreferences.shared.showHidden.toggle() }
        add(view, "Toggle Sidebar", "s", [.command, .option]) { self.active?.sidebarVisible.toggle() }
        add(view, "Toggle Preview", "p", [.command, .shift]) { self.active?.previewVisible.toggle() }
        add(view, "Toggle Path Bar", "p", [.command, .option]) { self.active?.pathVisible.toggle() }
        add(view, "Toggle Status Bar", "/") { self.active?.statusVisible.toggle() }
        add(view, "Filter Current Folder") { self.active?.focusFilter += 1 }
        add(view, "Find", "f") { self.active?.focusSearch += 1 }
        add(view, "Save Search…") { self.active?.saveSearch() }
        let go = menu("Go")
        add(go, "Back", "[") { self.active?.active.history(true) }
        add(go, "Forward", "]") { self.active?.active.history(false) }
        add(go, "Enclosing Folder", "\u{f700}") { if let p = self.active?.active { p.navigate(p.url.deletingLastPathComponent()) } }
        add(go, "Go to Folder…", "g", [.command, .shift]) { self.active?.goToFolder() }
        add(go, "Connect to Server…", "k") { self.connectServer() }
        add(go, "Quick Open…", "p", [.command, .control]) { self.active?.quickCommand = false; self.active?.showQuickOpen = true }
        add(go, "Command Palette…", "p", [.command, .control, .shift]) { self.active?.quickCommand = true; self.active?.showQuickOpen = true }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (name, path, key) in [("Home", home, "h"), ("Documents", home.appendingPathComponent("Documents"), "o"), ("Desktop", home.appendingPathComponent("Desktop"), "d"), ("Applications", URL(fileURLWithPath: "/Applications"), "a"), ("Utilities", URL(fileURLWithPath: "/Applications/Utilities"), "u"), ("Network", URL(fileURLWithPath: "/Network"), "k"), ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), "i")] { add(go, name, key, [.command, .shift]) { self.active?.active.navigate(path) } }
        add(go, "Downloads", "l", [.command, .option]) { self.active?.active.navigate(home.appendingPathComponent("Downloads")) }
        add(go, "Recents", "f", [.command, .shift]) { self.active?.active.searchAllRoots = true; self.active?.active.query = "past 30 days"; self.active?.active.runSearch() }
        add(go, "AirDrop", "r", [.command, .shift]) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")) }
        add(go, "Add to Sidebar", "t", [.command, .control]) { self.active?.addFavorite() }
        add(go, "New Sidebar Group…") { self.active?.newGroup() }
        let pane = menu("Pane")
        add(pane, "Split Right", "\u{f703}", [.command, .control, .option]) { self.active?.split(vertical: true) }
        add(pane, "Split Left", "\u{f702}", [.command, .control, .option]) { self.active?.split(vertical: true, before: true) }
        add(pane, "Split Down", "\u{f701}", [.command, .control, .option]) { self.active?.split(vertical: false) }
        add(pane, "Split Up", "\u{f700}", [.command, .control, .option]) { self.active?.split(vertical: false, before: true) }
        add(pane, "Next Pane", "]", [.command, .control]) { self.active?.nextPane(1) }
        add(pane, "Previous Pane", "[", [.command, .control]) { self.active?.nextPane(-1) }
        add(pane, "Next Pane Tab", "]", [.command, .option]) { self.active?.nextTab(1) }
        add(pane, "Previous Pane Tab", "[", [.command, .option]) { self.active?.nextTab(-1) }
        add(pane, "Zoom Pane", "\r", [.command, .shift]) { self.active?.zoomed.toggle() }
        add(pane, "Close Pane", "w", [.command, .control, .option]) { self.active?.closePane() }
        add(pane, "Copy to Other Pane", "c", [.command, .control, .shift]) { if let w = self.active, let other = w.other { FileOperations.shared.copy(w.active.selected, to: other.url) } }
        add(pane, "Move to Other Pane", "m", [.command, .control, .shift]) { if let w = self.active, let other = w.other { FileOperations.shared.copy(w.active.selected, to: other.url, move: true) } }
        add(pane, "Single Pane") { self.active?.preset(1) }; add(pane, "Side by Side") { self.active?.preset(2) }; add(pane, "Four Panes") { self.active?.preset(4) }
        add(pane, "Toggle Shelf") { self.active?.shelfVisible.toggle() }; add(pane, "Add Selection to Shelf") { self.active?.addShelf() }
        let window = menu("Window"); NSApp.windowsMenu = window
        add(window, "Minimize", "m") { NSApp.keyWindow?.miniaturize(nil) }
        add(window, "Save Workspace…") { self.active?.saveWorkspace() }
        add(window, "Open Workspace…") { self.active?.quickCommand = false; self.active?.showQuickOpen = true }
        add(window, "File Operations") { self.showOperations() }
        let help = menu("Help"); NSApp.helpMenu = help
        add(help, "FinderPlus Help") { self.show(title: "FinderPlus Help", view: AnyView(HelpView()), size: NSSize(width: 680, height: 580)) }
        NSApp.mainMenu = bar; applyCustomShortcuts()
    }
    func applyCustomShortcuts() {
        let values = UserDefaults.standard.dictionary(forKey: "customShortcuts") as? [String: String] ?? [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let original = originalKeys[item.title] { item.keyEquivalent = original.0; item.keyEquivalentModifierMask = original.1 }
                if let custom = values[item.title] {
                    let parts = custom.lowercased().split(separator: "+").map(String.init)
                    var flags: NSEvent.ModifierFlags = []
                    if parts.contains("cmd") { flags.insert(.command) }; if parts.contains("ctrl") { flags.insert(.control) }; if parts.contains("shift") { flags.insert(.shift) }; if parts.contains("alt") || parts.contains("option") { flags.insert(.option) }
                    item.keyEquivalent = parts.last ?? ""; item.keyEquivalentModifierMask = flags
                }
                if let child = item.submenu { walk(child) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let workspace = active, NSApp.keyWindow === workspace.window else { return event }
        if event.type == .otherMouseUp { if event.buttonNumber == 3 { workspace.paneUnderPointer.history(true); return nil }; if event.buttonNumber == 4 { workspace.paneUnderPointer.history(false); return nil }; return event }
        if event.type == .swipe { if event.deltaX != 0 { workspace.paneUnderPointer.history(event.deltaX > 0); return nil }; return event }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView || responder is NSTextField {
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let pane = workspace.active
        if event.keyCode == 125 && flags == .command { workspace.open(); return nil }
        if event.keyCode == 126 && flags == .command { pane.navigate(pane.url.deletingLastPathComponent()); return nil }
        guard flags.isEmpty || flags == .shift else { return event }
        let profile = AppPreferences.shared.keyboardProfile
        if event.keyCode == 53 { cutURLs = []; pane.query = ""; return nil }
        if event.keyCode == 49 { workspace.preview(); return nil }
        if event.keyCode == 36 { if profile == "Finder" { workspace.rename() } else { workspace.open() }; return nil }
        if event.keyCode == 120 && profile != "Finder" { workspace.rename(); return nil }
        if profile == "Total Commander" {
            switch event.keyCode {
            case 48: workspace.nextPane(1); return nil
            case 96: if let other = workspace.other { FileOperations.shared.copy(pane.selected, to: other.url) }; return nil
            case 97: if let other = workspace.other { FileOperations.shared.copy(pane.selected, to: other.url, move: true) }; return nil
            case 98: workspace.newFolder(); return nil
            case 100: FileOperations.shared.trash(pane.selected); return nil
            default: break
            }
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            if pane.mode == .columns && pane.query.isEmpty && !flags.contains(.shift) && pane.moveInColumns(event.keyCode) { return nil }
            let files = pane.displayed
            if !files.isEmpty { let old = files.firstIndex(where: { pane.selection.contains($0.id) }) ?? -1; let delta = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1; let next = min(max(old + delta, 0), files.count - 1); if flags.contains(.shift) { pane.selection.insert(files[next].id) } else { pane.selection = [files[next].id] } }
            return nil
        }
        if let chars = event.characters, chars.rangeOfCharacter(from: .alphanumerics) != nil {
            if Date().timeIntervalSince(lastTyped) > 0.8 { typedName = "" }; typedName += chars; lastTyped = Date()
            if pane.mode == .columns && pane.query.isEmpty { pane.typeSelectInColumns(typedName) }
            else if let file = pane.displayed.first(where: { $0.name.lowercased().hasPrefix(typedName.lowercased()) }) { pane.selection = [file.id] }
            return nil
        }
        return event
    }
}

struct HelpView: View {
    let shortcuts: [(String, String)] = [
        ("⌘1 – ⌘4", "Icons, List, Columns, Gallery"), ("⌘F", "Search"), ("⌃⌘P", "Quick Open (type > for commands)"),
        ("⇧⌘G", "Go to Folder"), ("⌘[  ⌘]", "Back, Forward"), ("⌃⌥⌘ arrow", "Split the pane"), ("⇧⌘Return", "Zoom the pane"),
        ("⌃⌘[  ⌃⌘]", "Previous, next pane"), ("⌃⇧⌘C  ⌃⇧⌘M", "Copy, move to the other pane"), ("⌘C  ⌘V  ⌥⌘V", "Copy, paste, move here"),
        ("Space", "Quick Look"), ("⌘I", "Get Info"), ("⌘Z", "Undo the last file operation"),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) { Text("FinderPlus").font(.largeTitle.bold()); Text("Browse familiar folders. Find files by what you remember.").foregroundStyle(.secondary) }
                }
                section("Browse and arrange", "rectangle.split.2x2", "Switch views with ⌘1–4 and group by kind, date, size or tags from the toolbar or View menu. Split any pane in four directions for up to 16 panes, zoom one with ⇧⌘Return, and save the arrangement as a workspace. Mouse side buttons and trackpad swipes go back and forward in the pane under the pointer.")
                section("Search", "magnifyingglass", "Type what you remember: screenshots last week, videos larger than 1 GB, downloaded from github, pdfs created this month, or content:\"project brief\". Each understood filter becomes a chip you can remove or right-click to edit. Approve folders in Settings › Search & Privacy; content and image-text search are separate opt-ins and nothing leaves your Mac.")
                section("Move files safely", "arrow.left.arrow.right", "When a name already exists you see both versions with the newer one marked, and Keep Both is the default. File Operations shows speed and time left, lets you pause, reorder and retry, and Undo works even after relaunching. Gather files from several folders on the Shelf, then copy or move them together. Keep a separate backup.")
                section("Cloud folders", "icloud", "Your provider’s Mac app handles sign-in and syncing; FinderPlus browses its local folder. Online-only files are never downloaded by browsing or search. Use Download Now before file operations.")
                VStack(alignment: .leading, spacing: 8) {
                    Label("Shortcuts", systemImage: "keyboard").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        ForEach(shortcuts, id: \.0) { keys, action in GridRow { Text(keys).font(.body.monospaced()).foregroundStyle(.secondary); Text(action) } }
                    }
                    Text("Return renames in the Finder keyboard profile and opens in Explorer and Total Commander. Change the profile or any shortcut in Settings › Keyboard.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
    func section(_ title: String, _ symbol: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: symbol).font(.headline); Text(text).fixedSize(horizontal: false, vertical: true) }
    }
}
