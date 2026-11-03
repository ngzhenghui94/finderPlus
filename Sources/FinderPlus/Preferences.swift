import AppKit
import SwiftUI
import Combine

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private let defaults: UserDefaults
    private var scopedRoots: [URL] = []
    @Published var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    @Published var foldersFirst: Bool { didSet { defaults.set(foldersFirst, forKey: "foldersFirst") } }
    @Published var iconSize: Double { didSet { defaults.set(iconSize, forKey: "iconSize") } }
    @Published var keyboardProfile: String { didSet { defaults.set(keyboardProfile, forKey: "keyboardProfile") } }
    @Published var searchRoots: [URL] { didSet { persistRoots() } }
    @Published var contentEnabled: Bool { didSet { defaults.set(contentEnabled, forKey: "contentEnabled") } }
    @Published var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") } }
    @Published var showCloud: Bool { didSet { defaults.set(showCloud, forKey: "showCloud") } }
    @Published var nearbyEnabled: Bool { didSet { defaults.set(nearbyEnabled, forKey: "nearbyEnabled"); NearbyShareService.shared.update(enabled: nearbyEnabled) } }
    @Published var groupBy: FileGrouping { didSet { defaults.set(groupBy.rawValue, forKey: "groupBy") } }
    @Published var settingsError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showHidden = defaults.bool(forKey: "showHidden")
        foldersFirst = defaults.object(forKey: "foldersFirst") as? Bool ?? true
        iconSize = min(160, max(32, defaults.object(forKey: "iconSize") as? Double ?? 64))
        let profile = defaults.string(forKey: "keyboardProfile") ?? "Finder"
        keyboardProfile = ["Finder", "Explorer", "Total Commander"].contains(profile) ? profile : "Finder"
        contentEnabled = defaults.bool(forKey: "contentEnabled")
        ocrEnabled = defaults.bool(forKey: "ocrEnabled")
        showCloud = defaults.object(forKey: "showCloud") as? Bool ?? true
        nearbyEnabled = defaults.bool(forKey: "nearbyEnabled")
        groupBy = FileGrouping(rawValue: defaults.string(forKey: "groupBy") ?? "") ?? .none
        var roots: [URL] = []
        var scoped: [URL] = []
        var failures: [String] = []
        for data in defaults.array(forKey: "searchRootBookmarks") as? [Data] ?? [] {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scoped.append(url) }
                roots.append(url)
                if stale { failures.append("Reapprove the moved or changed search folder: \(url.path)") }
            } catch { failures.append("Could not restore an approved search folder: \(error.localizedDescription)") }
        }
        searchRoots = roots
        scopedRoots = scoped
        settingsError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func persistRoots() {
        var bookmarks: [Data] = []
        var failures: [String] = []
        for url in searchRoots {
            do {
                bookmarks.append(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            } catch { failures.append("Could not save approved search folder \(url.path): \(error.localizedDescription)") }
        }
        // A missing remaining folder must never restore a removed approval on the next launch.
        defaults.set(bookmarks, forKey: "searchRootBookmarks")
        for root in scopedRoots { root.stopAccessingSecurityScopedResource() }
        scopedRoots = searchRoots.filter { $0.startAccessingSecurityScopedResource() }
        settingsError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func approveSearchRoots() {
        let panel = NSOpenPanel()
        panel.title = "Approve folders for local search"
        panel.message = "Only these folders will be indexed. Content search and OCR are separate opt-ins; online-only files are not downloaded by indexing."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var roots = searchRoots
        for url in panel.urls where !roots.contains(url) { roots.append(url) }
        searchRoots = roots
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        TabView {
            Form {
                Toggle("Show hidden files", isOn: $preferences.showHidden)
                Toggle("Keep folders first", isOn: $preferences.foldersFirst)
                LabeledContent("Icon size") {
                    Slider(value: $preferences.iconSize, in: 32...160, step: 8)
                    Text("\(Int(preferences.iconSize)) pt").monospacedDigit().frame(width: 55)
                }
                Picker("Keyboard profile", selection: $preferences.keyboardProfile) {
                    ForEach(["Finder", "Explorer", "Total Commander"], id: \.self) { Text($0) }
                }
                Text("Finder: Return renames. Explorer: F2 renames, Return opens. Total Commander: F5 copies, F6 moves, F7 creates a folder, F8 trashes.")
                    .font(.caption).foregroundStyle(.secondary)
                Section("Nearby Share") {
                    Toggle("Send and receive files with nearby Macs", isOn: $preferences.nearbyEnabled)
                    Text("While on, this Mac is visible to other FinderPlus Macs on the same network and can receive requests you must accept. Transfers are not encrypted and sender names are not verified; leave this off on public networks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            KeyboardShortcutsView().tabItem { Label("Keyboard", systemImage: "keyboard") }
            Form {
                Section("Approved search folders") {
                    if preferences.searchRoots.isEmpty { Text("No folders approved. Add a folder to enable search.").foregroundStyle(.secondary) }
                    ForEach(preferences.searchRoots, id: \.self) { root in
                        HStack {
                            Text(root.path).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { preferences.searchRoots.removeAll { $0 == root } }
                                .accessibilityLabel("Remove search folder \(root.lastPathComponent)")
                        }
                    }
                    Button("Add Folders…") { preferences.approveSearchRoots() }
                }
                Section("Privacy") {
                    Toggle("Search file contents locally", isOn: $preferences.contentEnabled)
                    Toggle("Recognize text in images locally (OCR)", isOn: $preferences.ocrEnabled)
                    Text("Opt-ins apply only to approved roots. OCR can use significant CPU. Search does not intentionally download online-only cloud files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = preferences.settingsError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).tabItem { Label("Search & Privacy", systemImage: "magnifyingglass") }
            Form {
                Toggle("Show cloud locations in sidebar", isOn: $preferences.showCloud)
                Section("Discovered locations") {
                    ForEach(CloudLocations.locations(), id: \.self) { url in
                        LabeledContent(url.lastPathComponent) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                    Text("iCloud download and eviction use macOS APIs. Other File Provider locations support coordinated downloads; provider-specific status and eviction may require Finder. No account credentials are stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Cloud", systemImage: "icloud") }
        }.padding(12).frame(width: 660, height: 470)
    }
}
