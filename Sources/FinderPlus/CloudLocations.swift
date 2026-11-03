import AppKit
import Foundation

// Metadata queries never open file contents; only explicit Download requests coordinate reads.
enum CloudLocations {
    static func locations() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var urls: [URL] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) { urls.append(iCloud) }
        let providers = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: providers, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            urls.append(contentsOf: children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static let statusKeys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey]

    static func status(_ url: URL) -> String {
        do {
            let values = try url.resourceValues(forKeys: Set(statusKeys))
            if values.isUbiquitousItem == true {
                if let error = values.ubiquitousItemDownloadingError ?? values.ubiquitousItemUploadingError { return "iCloud error: \(error.localizedDescription)" }
                if values.ubiquitousItemIsDownloading == true { return "Downloading" }
                if values.ubiquitousItemIsUploading == true { return "Uploading" }
                switch values.ubiquitousItemDownloadingStatus {
                case .current: return "iCloud · Downloaded"
                case .downloaded: return "iCloud · Downloaded (update available)"
                case .notDownloaded: return "iCloud · Online only"
                default: return "iCloud"
                }
            }
            return isProviderURL(url) ? "File Provider · Status in Finder" : "Local"
        } catch { return "Status unavailable: \(error.localizedDescription)" }
    }

    /// Darwin's SF_DATALESS marks File Provider / iCloud placeholders; reading one would download it.
    static func isPlaceholder(_ info: stat) -> Bool { info.st_flags & UInt32(SF_DATALESS) != 0 }

    /// Only ordinary files and folders can be read locally; pipes/devices can block or have side effects.
    static func isReadableLocally(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, !isPlaceholder(info) else { return false }
        let type = info.st_mode & S_IFMT
        return type == S_IFREG || type == S_IFDIR
    }

    static func isProviderURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage").path
        return path.hasPrefix(root + "/")
    }

    static func containsCloudItems(_ urls: [URL]) -> Bool {
        let roots = locations().map { $0.standardizedFileURL.path }
        return urls.contains { url in
            let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
            return roots.contains { root in paths.contains { $0 == root || $0.hasPrefix(root + "/") } }
        }
    }

    @MainActor static func download(_ urls: [URL]) { perform(urls, evict: false) }
    @MainActor static func evict(_ urls: [URL]) { perform(urls, evict: true) }

    @MainActor private static func perform(_ urls: [URL], evict: Bool) {
        guard !urls.isEmpty else { return }
        if evict {
            let alert = NSAlert()
            alert.messageText = "Remove local downloads?"
            alert.informativeText = "macOS will remove local copies of \(urls.count) selected iCloud items. Cloud originals remain. Files with unsynced changes will not be evicted."
            alert.addButton(withTitle: "Remove Downloads")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            let errors = await Task.detached(priority: .utility) {
                var errors: [String] = []
                for url in urls {
                    do {
                        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .isDirectoryKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey])
                        if values.isUbiquitousItem == true {
                            if evict {
                                guard values.ubiquitousItemIsUploaded == true, values.ubiquitousItemIsUploading != true, values.ubiquitousItemHasUnresolvedConflicts != true else {
                                    throw OperationFailure.message("Not fully uploaded or has unresolved conflicts; local copy preserved.")
                                }
                                try FileManager.default.evictUbiquitousItem(at: url)
                            } else { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
                        } else if isProviderURL(url), !evict {
                            guard values.isDirectory != true else { throw OperationFailure.message("For provider folders, select individual files to download or use Finder's provider actions.") }
                            var coordinationError: NSError?
                            var readError: Error?
                            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                                do {
                                    let handle = try FileHandle(forReadingFrom: coordinatedURL)
                                    defer { try? handle.close() }
                                    _ = try handle.read(upToCount: 1)
                                } catch { readError = error }
                            }
                            if let error = coordinationError ?? readError as NSError? { throw error }
                        } else {
                            throw OperationFailure.message(evict ? "Eviction is supported only for iCloud items. Use this provider's Finder action for other clouds." : "This item is not recognized as an iCloud or File Provider item.")
                        }
                    } catch { errors.append("\(url.path): \(error.localizedDescription)") }
                }
                return errors
            }.value
            if !errors.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = evict ? "Some downloads could not be removed" : "Some downloads could not be requested"
                alert.informativeText = errors.joined(separator: "\n\n")
                alert.runModal()
            }
            NotificationCenter.default.post(name: .cloudLocationsChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let cloudLocationsChanged = Notification.Name("FinderPlusCloudLocationsChanged")
}
