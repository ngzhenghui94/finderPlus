import Foundation
import CoreGraphics
import CoreText
import Darwin

private func requireSearch(_ condition: Bool, _ message: String) throws {
    guard condition else { throw OperationFailure.message("Search self-check: " + message) }
    assert(condition, message)
}

private func canonicalSearchURLs(_ urls: [URL]) -> [URL] {
    urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }
}

extension NaturalQuery {
    /// Isolated temporary fixtures only; no configured folders, network, downloads or OCR requests.
    static func selfCheck() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FinderPlus-search-check-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Approved", isDirectory: true)
        let outside = base.appendingPathComponent("NotApproved", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let calendar = Calendar(identifier: .gregorian)
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
        let priorWeek = calendar.date(byAdding: .day, value: -3, to: currentWeek.start)!

        func file(_ name: String, text: String = "", directory: URL? = nil) throws -> URL {
            let url = (directory ?? root).appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        let report = try file("report.txt", text: "An amber orchard is searchable only with permission.")
        let screenshot = try file("Screenshot sample.png")
        try manager.setAttributes([.modificationDate: priorWeek], ofItemAtPath: screenshot.path)
        let movie = try file("launch.mov")
        let handle = try FileHandle(forWritingTo: movie)
        try handle.truncate(atOffset: 1_100_000_000)
        try handle.close()
        let literal = try file("screenshots last week.txt")
        let operatorLiteral = try file("kind:pdf notes.txt")
        _ = try file(".hidden.txt", text: "hidden fixture")
        let outsideSecret = try file("outside-secret.txt", text: "never include unapproved scope", directory: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("outside-link.txt"), withDestinationURL: outsideSecret)
        let package = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        _ = try file("package-secret.txt", directory: package)
        let pdf = root.appendingPathComponent("document.pdf")
        try makeSearchPDF(at: pdf, text: "cobalt meridian")
        let pipe = root.appendingPathComponent("blocked.txt")
        try requireSearch(mkfifo(pipe.path, 0o600) == 0, "cannot create temporary FIFO")
        try requireSearch(!CloudLocations.isReadableLocally(pipe), "FIFO is not safe local content or preview input")
        try requireSearch(CloudLocations.isReadableLocally(report) && CloudLocations.isReadableLocally(root), "ordinary local files and folders remain readable")
        let sources = try PropertyListSerialization.data(fromPropertyList: ["https://github.com/example/project/releases"], format: .binary, options: 0)
        let attributeResult = sources.withUnsafeBytes {
            setxattr(report.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, sources.count, 0, XATTR_NOFOLLOW)
        }
        try requireSearch(attributeResult == 0, "cannot write temporary source metadata")

        let screenshotEntry = try FileEntry(url: screenshot)
        let movieEntry = try FileEntry(url: movie)
        let literalEntry = try FileEntry(url: literal)
        let operatorEntry = try FileEntry(url: operatorLiteral)
        let reportEntry = try FileEntry(url: report)
        try requireSearch(parse("screenshots last week", now: now).matches(screenshotEntry), "English screenshot/date phrase")
        try requireSearch(parse("ảnh chụp màn hình tuần trước", now: now).matches(screenshotEntry), "Vietnamese screenshot/date phrase")
        try requireSearch(!parse("screenshots this week", now: now).matches(screenshotEntry), "calendar week boundary")
        try requireSearch(parse("videos larger than 1 GB", now: now).matches(movieEntry), "English kind/size phrase")
        try requireSearch(parse("video lớn hơn 1 GB", now: now).matches(movieEntry), "Vietnamese size phrase")
        try requireSearch(parse("screenshots from last week", now: now).matches(screenshotEntry), "English date preposition")
        try requireSearch(parse("size:>=1GiB", now: now).matches(movieEntry), "binary size units")
        try requireSearch(!parse("size:<1 GB", now: now).matches(movieEntry), "operator with separated unit")
        let smallerMovie = try file("below-binary-gb.mov")
        let smallerHandle = try FileHandle(forWritingTo: smallerMovie)
        try smallerHandle.truncate(atOffset: 1_050_000_000); try smallerHandle.close()
        try requireSearch(!parse("videos larger than 1 GB", now: now).matches(try FileEntry(url: smallerMovie)), "GB uses binary boundary")
        let sheet = try file("planning.csv")
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: sheet.path)
        try requireSearch(parse("spreadsheets edited today", now: now).matches(try FileEntry(url: sheet)), "spreadsheet modified date phrase")
        let slides = try file("roadmap.pptx")
        let previousYear = calendar.date(byAdding: .year, value: -1, to: now)!
        try manager.setAttributes([.modificationDate: previousYear], ofItemAtPath: slides.path)
        try requireSearch(parse("presentations from last year", now: now).matches(try FileEntry(url: slides)), "presentation calendar year phrase")
        let archive = try file("backup.zip")
        try manager.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86400)], ofItemAtPath: archive.path)
        try requireSearch(parse("archives older than 30 days", now: now).matches(try FileEntry(url: archive)), "archive age phrase")
        try requireSearch(parse("mtime:<7d", now: now).matches(try FileEntry(url: sheet)), "relative modified-date operator")
        try requireSearch(parse("after:7d", now: now).matches(try FileEntry(url: sheet)) && !parse("after:7d", now: now).matches(try FileEntry(url: archive)), "after:Nd finds newer files")
        try requireSearch(parse("before:7d", now: now).matches(try FileEntry(url: archive)) && !parse("before:7d", now: now).matches(try FileEntry(url: sheet)), "before:Nd finds older files")
        try requireSearch(!parse("!planning", now: now).matches(try FileEntry(url: sheet)), "bang exclusion")
        try requireSearch(parse("\"screenshots last week\"", now: now).matches(literalEntry), "quoted phrase stays literal")
        try requireSearch(!parse("\"screenshots last week\"", now: now).matches(screenshotEntry), "quoted phrase does not become date predicates")
        try requireSearch(parse("\"kind:pdf\"", now: now).matches(operatorEntry), "quoted operator stays literal")
        try requireSearch(parse("name:\"report.txt\"", now: now).matches(reportEntry), "quoted operator argument")
        try requireSearch(parse("(ext:txt OR ext:pdf) NOT name:secret", now: now).matches(reportEntry), "boolean grouping")
        try requireSearch(!parse("NOT ext:txt", now: now).matches(reportEntry), "NOT predicate")
        try requireSearch(!parse("NOT", now: now).matches(reportEntry), "dangling exclusion fails closed")
        try requireSearch(!parse(") name:report", now: now).matches(reportEntry), "unmatched closing parenthesis does not broaden search")
        let bareOr = parse("OR", now: now)
        try requireSearch(bareOr.matches(reportEntry) && !bareOr.matches(movieEntry) && !bareOr.warnings.isEmpty, "bare OR matches only names containing the literal word")
        for query in ["()", "NOT ()", "name:missing OR OR name:absent", "name:report OR", "(name:report"] {
            let malformed = parse(query, now: now)
            try requireSearch(!malformed.matches(reportEntry) && !malformed.warnings.isEmpty, "malformed boolean query stays literal: \(query)")
        }
        try requireSearch(parse("", now: now).matches(reportEntry), "empty query still enumerates the scope")
        try requireSearch(!parse("-ext:txt", now: now).matches(reportEntry), "minus exclusion")
        try requireSearch(!parse("-name:\"report.txt\"", now: now).matches(reportEntry), "quoted operator exclusion")
        try requireSearch(parse("ext:mov OR ext:txt AND name:report", now: now).matches(movieEntry), "AND precedence over OR")
        try requireSearch(!parse("modified:<2000-01-01", now: now).matches(screenshotEntry), "absolute before date")
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        try requireSearch(parse("modified:\(dateFormatter.string(from: priorWeek))", now: now).matches(screenshotEntry), "absolute date day interval")
        try requireSearch(!parse("modified:2026-99-99", now: now).warnings.isEmpty, "invalid date warning")
        try requireSearch(!parse("size:999999999999999999999TB", now: now).warnings.isEmpty, "overflow size warning")
        try requireSearch(!parse("\"unfinished", now: now).warnings.isEmpty, "unclosed quote warning")
        try requireSearch(!parse("unknown: report", now: now).matches(try FileEntry(url: file("unknown:.txt"))), "unknown operator keeps the next word as a required search term")
        try requireSearch(!parse("size: invalid", now: now).matches(try FileEntry(url: file("size:.txt"))), "invalid operator keeps the next word as a required search term")
        let spaced = parse("screenshots   last   week", now: now)
        try requireSearch(spaced.filters.map(\.expression) == ["screenshots", "last   week"], "chips retain original whitespace")
        try requireSearch(parse("NOT   ext:txt", now: now).filters.first?.expression == "NOT   ext:txt", "exclusion chip retains NOT")
        try requireSearch(parse("ext:txt OR ext:pdf", now: now).filters.count == 1, "OR chip removes without dangling operators")
        try requireSearch(parse("name:\"a \\\"quoted\\\" name\"", now: now).filters.count == 1, "escaped quote tokenization")

        let capture = try file("capture.png")
        let captureFlag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        _ = captureFlag.withUnsafeBytes { setxattr(capture.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, captureFlag.count, 0, XATTR_NOFOLLOW) }
        let deep = root.appendingPathComponent("deep", isDirectory: true)
        try manager.createDirectory(at: deep, withIntermediateDirectories: false)
        let needle = try file("needle.txt", directory: deep)
        for index in 0..<12 { try manager.createSymbolicLink(at: root.appendingPathComponent("link\(index)"), withDestinationURL: deep) }
        let index = LocalSearchIndex()
        func search(_ query: String, hidden: Bool = false, content: Bool = false, roots: [URL]? = nil) async throws -> SearchOutput {
            try await index.search(plan: parse(query, now: now), roots: roots ?? [root], includeHidden: hidden, contentEnabled: content, ocrEnabled: false)
        }
        let all = try await search("")
        let names = Set(all.entries.map(\.name))
        try requireSearch(names.contains("report.txt") && names.contains("document.pdf"), "approved root enumeration")
        try requireSearch(!names.contains("outside-secret.txt") && !names.contains("outside-link.txt") && !names.contains("escape"), "symlinks cannot escape approved scope")
        try requireSearch(!names.contains("package-secret.txt"), "package descendants excluded")
        try requireSearch(!names.contains(".hidden.txt"), "hidden files are opt-in")
        try requireSearch(canonicalSearchURLs(try await search("name:needle").entries.map(\.url)) == canonicalSearchURLs([needle]), "links next to a folder do not hide its files")
        try requireSearch(try await search("screenshots").entries.contains { $0.name == "capture.png" }, "screenshot flag read from the file's metadata attribute")
        let cached = try await search("name:report")
        try requireSearch(cached.usedCache && cached.entries.count == 1, "scoped metadata cache")
        let freshFile = try file("cache-refresh.txt")
        await index.invalidateCache()
        let refreshed = try await search("name:cache-refresh")
        try requireSearch(!refreshed.usedCache && canonicalSearchURLs(refreshed.entries.map(\.url)) == canonicalSearchURLs([freshFile]), "invalidation discovers new files immediately")
        try manager.removeItem(at: freshFile)
        await index.invalidateCache()
        let deleted = try await search("name:cache-refresh")
        try requireSearch(!deleted.usedCache && deleted.entries.isEmpty, "invalidation removes deleted results immediately")
        let disabled = try await search("content:\"amber orchard\"")
        try requireSearch(disabled.entries.isEmpty && !disabled.issues.isEmpty, "content requires explicit opt-in")
        let disabledExclusion = try await search("NOT content:secret")
        try requireSearch(disabledExclusion.entries.isEmpty && !disabledExclusion.issues.isEmpty, "disabled content exclusion cannot silently match everything")
        let content = try await search("content:\"amber orchard\"", content: true)
        try requireSearch(canonicalSearchURLs(content.entries.map(\.url)) == canonicalSearchURLs([report]), "UTF-8 content extraction")
        let pdfResult = try await search("content:\"cobalt meridian\"", content: true)
        try requireSearch(canonicalSearchURLs(pdfResult.entries.map(\.url)) == canonicalSearchURLs([pdf]), "PDF native text extraction")
        let bareContent = try await search("\"amber orchard\"", content: true)
        try requireSearch(canonicalSearchURLs(bareContent.entries.map(\.url)) == canonicalSearchURLs([report]), "opted-in bare phrase content matching")
        let source = try await search("downloaded from github")
        try requireSearch(canonicalSearchURLs(source.entries.map(\.url)) == canonicalSearchURLs([report]), "recorded source metadata")
        let vietnameseSource = try await search("tải từ github")
        try requireSearch(canonicalSearchURLs(vietnameseSource.entries.map(\.url)) == canonicalSearchURLs([report]), "Vietnamese source phrase")
        let sourcePath = try await search("source:example")
        try requireSearch(sourcePath.entries.isEmpty, "source site names do not match arbitrary URL paths")
        let hidden = try await search("", hidden: true)
        try requireSearch(hidden.entries.contains { $0.name == ".hidden.txt" }, "hidden option uses separate cache")
        let otherRoot = try await search("name:outside-secret", roots: [outside])
        try requireSearch(otherRoot.entries.count == 1, "explicitly approved second scope")
        let missing = try await search("", roots: [base.appendingPathComponent("Missing")])
        try requireSearch(missing.entries.isEmpty && !missing.issues.isEmpty, "missing root error is visible")
        let resetRoot = try await search("name:outside-secret")
        try requireSearch(resetRoot.entries.isEmpty, "removed scopes do not leak cached results")
        let noRoots = try await search("", roots: [])
        try requireSearch(noRoots.entries.isEmpty && !noRoots.issues.isEmpty, "no implicit default search roots")
        let overlapping = try await search("name:report", roots: [root, root])
        try requireSearch(overlapping.entries.count == 1, "overlapping scopes deduplicate results")
        let cancelled = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await index.search(plan: parse(""), roots: [root], includeHidden: false, contentEnabled: false, ocrEnabled: false)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let didCancel = await cancelled.value
        try requireSearch(didCancel, "cancelled searches stop before scanning")
        try await checkSearchPreferences(root: root, base: base)
    }
}

@MainActor
private func checkSearchPreferences(root: URL, base: URL) throws {
    let suite = "FinderPlus-search-preferences-check-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw OperationFailure.message("Search self-check: cannot isolate preferences") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.searchRoots = [root]
    try requireSearch(preferences.settingsError == nil, "temporary approved root can be bookmarked")
    preferences.contentEnabled = true
    preferences.ocrEnabled = true
    let service = SearchService(preferences: preferences)
    func start() {
        service.search("name:report", roots: [root], includeHidden: false, contentEnabled: false, ocrEnabled: false)
    }
    start()
    preferences.contentEnabled = false
    try requireSearch(!service.isSearching && service.results.isEmpty, "text opt-out immediately cancels active search")
    start()
    preferences.ocrEnabled = false
    try requireSearch(!service.isSearching && service.results.isEmpty, "OCR opt-out immediately cancels active search")
    start()
    preferences.searchRoots = []
    try requireSearch(!service.isSearching && service.results.isEmpty, "root revocation immediately cancels active search")

    let disappearing = base.appendingPathComponent("Disappearing", isDirectory: true)
    try FileManager.default.createDirectory(at: disappearing, withIntermediateDirectories: false)
    preferences.searchRoots = [root, disappearing]
    try requireSearch(preferences.settingsError == nil, "temporary roots persist before removal")
    try FileManager.default.removeItem(at: disappearing)
    preferences.searchRoots = [disappearing]
    try requireSearch(preferences.settingsError != nil, "missing root persistence failure is visible")
    let restored = AppPreferences(defaults: defaults)
    try requireSearch(!canonicalSearchURLs(restored.searchRoots).contains(canonicalSearchURLs([root])[0]), "another missing root cannot restore a revoked approval")
}

private func makeSearchPDF(at url: URL, text: String) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
        throw OperationFailure.message("Search self-check: cannot create temporary PDF")
    }
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
    let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    context.textPosition = CGPoint(x: 72, y: 720)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
}
