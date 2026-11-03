import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import CoreServices
import PDFKit
import Vision
import ImageIO
import Darwin

struct SearchFilter: Identifiable {
    let id = UUID()
    let label: String
    let expression: String
}

private enum SearchDateField { case modified, created, downloaded }
private enum SearchComparison { case less, lessEqual, equal, greaterEqual, greater }
private indirect enum SearchPredicate {
    case all([SearchPredicate]), any([SearchPredicate]), not(SearchPredicate)
    case text(String), name(String), path(String), ext(String), kind(String), tag(String), source(String), content(String)
    case size(SearchComparison, Int64), date(SearchDateField, Date?, Date?)
}

private extension SearchPredicate {
    var needsContent: Bool {
        switch self {
        case .content: return true
        case .all(let values), .any(let values): return values.contains { $0.needsContent }
        case .not(let value): return value.needsContent
        default: return false
        }
    }
    /// Spotlight and xattr lookups cost an IPC per file; fetch them only for filters that read them.
    var needsMetadata: Bool {
        switch self {
        case .source, .date(.downloaded, _, _): return true
        case .kind(let kind): return kind.hasPrefix("screenshot")
        case .all(let values), .any(let values): return values.contains { $0.needsMetadata }
        case .not(let value): return value.needsMetadata
        default: return false
        }
    }
}

struct SearchPlan {
    var filters: [SearchFilter]
    var explanation: String
    var warnings: [String]
    fileprivate var predicate: SearchPredicate = .all([])

    func matches(_ entry: FileEntry) -> Bool {
        SearchMatcher(plan: self, contentEnabled: false, ocrEnabled: false, roots: []).matches(SearchRecord(entry: entry))
    }
}

private func searchFold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased().replacingOccurrences(of: "đ", with: "d")
}

private struct SearchToken {
    let raw: String
    let value: String
    let quoted: Bool
    let offset: Int
    var folded: String { searchFold(value) }
}

enum NaturalQuery {
    static func parse(_ text: String, now: Date = Date()) -> SearchPlan {
        var parser = QueryParser(text: text, now: now)
        return parser.parse()
    }
}

private struct QueryParser {
    var tokens: [SearchToken] = []
    var index = 0
    var filters: [SearchFilter] = []
    var warnings: [String] = []
    var invalidBoolean = false
    let now: Date
    let original: String
    var calendar = Calendar(identifier: .gregorian)

    init(text: String, now: Date) {
        self.now = now
        self.original = text
        var position = 0, tokenOffset = 0
        var raw = "", value = "", inQuote = false, hadQuote = false, escaped = false
        func appendToken() {
            guard !raw.isEmpty else { return }
            tokens.append(SearchToken(raw: raw, value: value, quoted: hadQuote, offset: tokenOffset))
            raw = ""; value = ""; hadQuote = false
        }
        for character in text {
            defer { position += String(character).utf16.count }
            if raw.isEmpty { tokenOffset = position }
            if escaped { raw.append(character); value.append(character); escaped = false; continue }
            if character == "\\", inQuote { raw.append(character); escaped = true; continue }
            if character == "\"" || character == "“" || character == "”" {
                raw.append(character); inQuote.toggle(); hadQuote = true; continue
            }
            if !inQuote && character.isWhitespace { appendToken(); continue }
            if !inQuote && (character == "(" || character == ")") {
                appendToken(); tokens.append(SearchToken(raw: String(character), value: String(character), quoted: false, offset: position)); continue
            }
            raw.append(character); value.append(character)
        }
        if escaped { value.append("\\") }
        appendToken()
        if inQuote { warnings.append("Unclosed quote: the remaining text is treated literally.") }
    }

    mutating func parse() -> SearchPlan {
        var predicate = parseOr()
        if index < tokens.count {
            warnings.append("Unmatched closing parenthesis: this query is treated as a literal name.")
            invalidBoolean = true
        }
        if invalidBoolean {
            predicate = .name(original)
            filters = [SearchFilter(label: "Literal name", expression: original)]
        }
        return SearchPlan(filters: filters,
                          explanation: "Local search; symlinks and package descendants are excluded. AND is implicit; OR, NOT and parentheses are supported. Quotes preserve literal words. Dates use the local calendar; last week means the previous calendar week. KB/MB/GB/TB use binary units. Download source requires recorded metadata. Content and OCR require explicit opt-in. Limits: text 8 MiB; PDF 32 MiB/200 pages; OCR 32 MiB/4096 px and 20 PDF pages. Metadata cache expires after 10 seconds.",
                          warnings: warnings, predicate: predicate)
    }

    func isOperator(_ value: String) -> Bool {
        index < tokens.count && !tokens[index].quoted && tokens[index].folded == value
    }

    mutating func parseOr() -> SearchPredicate {
        let start = index
        let filterStart = filters.count
        if isOperator("or") || isOperator("hoac") || isOperator("|") {
            warnings.append("OR needs a left-hand condition.")
            invalidBoolean = true
            index += 1
        }
        var values = [parseAnd()]
        while isOperator("or") || isOperator("hoac") || isOperator("|") {
            index += 1
            if index == tokens.count || isOperator(")") { warnings.append("OR needs a right-hand condition."); invalidBoolean = true; break }
            values.append(parseAnd())
        }
        if values.count > 1 {
            filters.removeSubrange(filterStart...)
            filters.append(SearchFilter(label: "Any: \(expression(start, index))", expression: expression(start, index)))
        }
        return values.count == 1 ? values[0] : .any(values)
    }

    mutating func parseAnd() -> SearchPredicate {
        var values: [SearchPredicate] = []
        while index < tokens.count && !isOperator(")") && !isOperator("or") && !isOperator("hoac") && !isOperator("|") {
            if isOperator("and") || isOperator("va") || isOperator("&") { index += 1; continue }
            values.append(parseUnary())
        }
        if values.isEmpty && !tokens.isEmpty {
            warnings.append("Boolean group needs a condition; this query is treated as a literal name.")
            invalidBoolean = true
        }
        return .all(values)
    }

    mutating func parseUnary() -> SearchPredicate {
        if isOperator("not") || isOperator("except") || isOperator("excluding") || isOperator("without") || isOperator("!") || phrase(["ngoai", "tru"]) {
            let start = index
            let exclusionLength = phrase(["ngoai", "tru"]) ? 2 : 1
            index += exclusionLength
            if index == tokens.count || isOperator(")") || isOperator("or") || isOperator("hoac") || isOperator("|") {
                warnings.append("Exclusion needs a condition."); invalidBoolean = true; return .any([])
            }
            let filterStart = filters.count
            let result = parseUnary()
            // Keep NOT attached to its chip so removing a chip never leaves a dangling exclusion.
            if filters.count > filterStart {
                filters.removeSubrange(filterStart...)
                filters.append(SearchFilter(label: expression(start, index), expression: expression(start, index)))
            }
            return .not(result)
        }
        if isOperator("(") {
            let start = index
            let filterStart = filters.count
            index += 1
            let result = parseOr()
            if isOperator(")") { index += 1 } else { warnings.append("Missing closing parenthesis."); invalidBoolean = true }
            filters.removeSubrange(filterStart...)
            filters.append(SearchFilter(label: expression(start, index), expression: expression(start, index)))
            return result
        }
        let start = index
        let token = tokens[index]
        index += 1
        let result: SearchPredicate
        var label = "Name / text: \(token.value)"
        if !token.raw.hasPrefix("\"") && !token.raw.hasPrefix("“") && (token.value.hasPrefix("-") || token.value.hasPrefix("!")) && token.value.count > 1 {
            let inner = String(token.value.dropFirst())
            result = .not(operatorPredicate(inner) ?? .text(inner))
            label = "Exclude: \(inner)"
        } else if !token.raw.hasPrefix("\"") && !token.raw.hasPrefix("“"), let parsed = operatorPredicate(token.value) {
            result = parsed; label = token.value
        } else if !token.quoted, let natural = naturalPredicate(start: start) {
            result = natural.0; label = natural.1
        } else {
            result = .text(token.value)
        }
        filters.append(SearchFilter(label: label, expression: expression(start, index)))
        return result
    }

    func expression(_ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        let first = tokens[start]
        let last = tokens[end - 1]
        return (original as NSString).substring(with: NSRange(location: first.offset, length: last.offset + last.raw.utf16.count - first.offset))
    }
    func phrase(_ words: [String], at start: Int? = nil) -> Bool {
        let offset = start ?? index
        return offset + words.count <= tokens.count && words.enumerated().allSatisfy {
            !tokens[offset + $0.offset].quoted && tokens[offset + $0.offset].folded == $0.element
        }
    }

    mutating func operatorPredicate(_ text: String) -> SearchPredicate? {
        guard let colon = text.firstIndex(of: ":") else {
            if let first = text.first, first == ">" || first == "<", let size = parseSize(text) { return .size(size.0, size.1) }
            return nil
        }
        let key = searchFold(String(text[..<colon]))
        let argumentStart = index
        var value = String(text[text.index(after: colon)...])
        if value.isEmpty, index < tokens.count, !isOperator(")") {
            value = tokens[index].value; index += 1
        }
        guard !value.isEmpty else {
            warnings.append("Empty \(key): filter is treated as a literal name."); index = argumentStart; return nil
        }
        switch key {
        case "name", "ten": return .name(value)
        case "path", "duongdan": return .path(value)
        case "ext", "extension": return .ext(value.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        case "kind", "type", "loai": return .kind(searchFold(value))
        case "tag", "tags", "nhan": return .tag(value)
        case "source", "from", "nguon": return .source(value)
        case "content", "contains", "text", "noidung": return .content(value)
        case "size", "kichthuoc":
            if index < tokens.count, ["b", "kb", "mb", "gb", "tb", "kib", "mib", "gib", "tib"].contains(tokens[index].folded) {
                value += tokens[index].value; index += 1
            }
            if let parsed = parseSize(value) { return .size(parsed.0, parsed.1) }
            warnings.append("Invalid size '\(value)'. Use size:>1GB or size:<=500MiB.")
        case "modified", "mtime", "created", "ctime", "downloaded", "after", "before", "date":
            let field: SearchDateField = ["created", "ctime"].contains(key) ? .created : key == "downloaded" ? .downloaded : .modified
            if let range = relativeDate(searchFold(value)) { return .date(field, range.0, range.1) }
            var dateText = value
            var relation = key == "before" ? "<" : key == "after" ? ">=" : "="
            for prefix in [">=", "<=", ">", "<", "="] where value.hasPrefix(prefix) {
                relation = prefix; dateText = String(value.dropFirst(prefix.count)); break
            }
            if dateText.hasSuffix("d"), let days = Int(dateText.dropLast()), days > 0, days <= 36500, let cutoff = calendar.date(byAdding: .day, value: -days, to: now) {
                return relation.hasPrefix("<") ? .date(field, cutoff, now.addingTimeInterval(0.001)) : .date(field, nil, cutoff)
            }
            if let date = isoDate(dateText), let next = calendar.date(byAdding: .day, value: 1, to: date) {
                switch relation {
                case ">": return .date(field, next, nil)
                case ">=": return .date(field, date, nil)
                case "<": return .date(field, nil, date)
                case "<=": return .date(field, nil, next)
                default: return .date(field, date, next)
                }
            }
            warnings.append("Invalid date '\(value)'. Use YYYY-MM-DD, today, yesterday, last-week or last-month.")
        default: warnings.append("Unknown operator '\(key):' is treated literally.")
        }
        index = argumentStart
        return nil
    }

    mutating func naturalPredicate(start: Int) -> (SearchPredicate, String)? {
        let word = tokens[start].folded
        for words in [["downloaded", "from"], ["tai", "tu"], ["duoc", "tai", "tu"]] {
            if phrase(words, at: start), start + words.count < tokens.count {
                index = start + words.count + 1
                let source = tokens[index - 1].value
                return (.source(source), "Downloaded from: \(source)")
            }
        }
        for words in [["anh", "chup", "man", "hinh"], ["screen", "shots"]] where phrase(words, at: start) {
            index = start + words.count; return (.kind("screenshot"), "Kind: screenshot")
        }
        let kinds: [String: String] = ["screenshots":"screenshot", "screenshot":"screenshot", "videos":"video", "video":"video", "movies":"video", "images":"image", "photos":"image", "pictures":"image", "anh":"image", "hinh":"image", "audio":"audio", "music":"audio", "nhac":"audio", "documents":"document", "document":"document", "pdfs":"pdf", "pdf":"pdf", "archives":"archive", "folders":"folder", "folder":"folder", "thu-muc":"folder", "spreadsheets":"spreadsheet", "presentations":"presentation", "code":"code", "apps":"app"]
        if ["file", "files", "tep"].contains(word) { return (.kind("file"), "Kind: file") }
        if phrase(["tap", "tin"], at: start) { index = start + 2; return (.kind("file"), "Kind: file") }
        if let kind = kinds[word] { return (.kind(kind), "Kind: \(kind)") }
        if phrase(["thu", "muc"], at: start) { index = start + 2; return (.kind("folder"), "Kind: folder") }
        if phrase(["tai", "lieu"], at: start) { index = start + 2; return (.kind("document"), "Kind: document") }
        if phrase(["tep", "pdf"], at: start) { index = start + 2; return (.kind("pdf"), "Kind: pdf") }
        if phrase(["hinh", "anh"], at: start) { index = start + 2; return (.kind("image"), "Kind: image") }
        var field: SearchDateField = .modified
        var dateStart = start
        if ["modified", "changed", "edited", "updated", "created", "made"].contains(word) {
            field = ["created", "made"].contains(word) ? .created : .modified
            dateStart += 1
        } else if phrase(["duoc", "tao"], at: start) { field = .created; dateStart += 2 }
        else if phrase(["sua", "doi"], at: start) { dateStart += 2 }
        else if ["from", "during", "in", "tu", "trong"].contains(word) { dateStart += 1 }
        if word == "downloaded", start + 1 < tokens.count {
            warnings.append("Download dates are not consistently recorded. Use modified or created dates, or downloaded:YYYY-MM-DD when metadata is available.")
        }
        if phrase(["older", "than"], at: dateStart), dateStart + 3 < tokens.count, let days = Int(tokens[dateStart + 2].value), days > 0, days <= 36500, ["day", "days"].contains(tokens[dateStart + 3].folded), let cutoff = calendar.date(byAdding: .day, value: -days, to: now) {
            index = dateStart + 4
            return (.date(field, nil, cutoff), "Older than \(days) days")
        }
        let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        if dateStart > start, dateStart < tokens.count, let monthIndex = monthNames.firstIndex(of: tokens[dateStart].folded) {
            var year = calendar.component(.year, from: now)
            let explicitYear = dateStart + 1 < tokens.count ? Int(tokens[dateStart + 1].value) : nil
            if let explicitYear, (1...9999).contains(explicitYear) { year = explicitYear }
            else if monthIndex + 1 > calendar.component(.month, from: now) { year -= 1 }
            if let beginning = calendar.date(from: DateComponents(year: year, month: monthIndex + 1, day: 1)), let end = calendar.date(byAdding: .month, value: 1, to: beginning) {
                index = dateStart + (explicitYear == nil ? 1 : 2)
                if explicitYear == nil { warnings.append("Month year inferred as \(year); inspect this filter.") }
                return (.date(field, beginning, end), "\(monthNames[monthIndex].capitalized) \(year)\(explicitYear == nil ? " ?" : "")")
            }
        }
        for length in [3, 2, 1] where dateStart + length <= tokens.count {
            guard !tokens[dateStart..<(dateStart + length)].contains(where: \.quoted) else { continue }
            let value = tokens[dateStart..<(dateStart + length)].map(\.folded).joined(separator: " ")
            if let range = relativeDate(value) {
                index = dateStart + length; return (.date(field, range.0, range.1), "Date: \(value)")
            }
        }
        if dateStart + 2 < tokens.count, ["past", "last"].contains(tokens[dateStart].folded),
           let count = Int(tokens[dateStart + 1].value), count > 0, count <= 36500 {
            let unit = tokens[dateStart + 2].folded
            let component: Calendar.Component? = ["day", "days"].contains(unit) ? .day : ["week", "weeks"].contains(unit) ? .weekOfYear : ["month", "months"].contains(unit) ? .month : nil
            if let component, let lower = calendar.date(byAdding: component, value: -count, to: now) {
                index = dateStart + 3; return (.date(field, lower, now.addingTimeInterval(0.001)), "Past \(count) \(unit)")
            }
        }
        if dateStart + 2 < tokens.count, let count = Int(tokens[dateStart].value), count > 0, count <= 36500,
           tokens[dateStart + 1].folded == "ngay", tokens[dateStart + 2].folded == "qua",
           let lower = calendar.date(byAdding: .day, value: -count, to: now) {
            index = dateStart + 3; return (.date(field, lower, now.addingTimeInterval(0.001)), "Past \(count) days")
        }
        for (words, comparison) in [(["larger", "than"], ">"), (["bigger", "than"], ">"), (["smaller", "than"], "<"), (["less", "than"], "<"), (["at", "least"], ">="), (["at", "most"], "<="), (["lon", "hon"], ">"), (["nho", "hon"], "<"), (["over"], ">"), (["under"], "<"), (["tren"], ">"), (["duoi"], "<")] {
            if phrase(words, at: start), start + words.count < tokens.count {
                let sizeStart = start + words.count
                var sizeText = tokens[sizeStart].value
                var end = sizeStart + 1
                if end < tokens.count, ["b", "kb", "mb", "gb", "tb", "kib", "mib", "gib", "tib"].contains(tokens[end].folded) {
                    sizeText += tokens[end].value; end += 1
                }
                if sizeText.rangeOfCharacter(from: .letters) != nil, let parsed = parseSize(comparison + sizeText) {
                    index = end; return (.size(parsed.0, parsed.1), "Size: \(comparison)\(sizeText)")
                }
            }
        }
        for (words, before) in [(["before"], true), (["after"], false), (["truoc", "ngay"], true), (["sau", "ngay"], false)] {
            if phrase(words, at: dateStart), dateStart + words.count < tokens.count,
               let date = isoDate(tokens[dateStart + words.count].value) {
                index = dateStart + words.count + 1
                return (.date(field, before ? nil : date, before ? date : nil), "Date: \(expression(start, index))")
            }
        }
        if phrase(["containing", "text"], at: start), start + 2 < tokens.count {
            index = start + 3; return (.content(tokens[start + 2].value), "Content: \(tokens[start + 2].value)")
        }
        return nil
    }

    func isoDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    func relativeDate(_ value: String) -> (Date, Date)? {
        let value = value.replacingOccurrences(of: "-", with: " ")
        let today = calendar.startOfDay(for: now)
        if ["today", "hom nay"].contains(value), let end = calendar.date(byAdding: .day, value: 1, to: today) { return (today, end) }
        if ["yesterday", "hom qua"].contains(value), let start = calendar.date(byAdding: .day, value: -1, to: today) { return (start, today) }
        let component: Calendar.Component
        let previous: Bool
        switch value {
        case "this week", "tuan nay": component = .weekOfYear; previous = false
        case "last week", "tuan truoc": component = .weekOfYear; previous = true
        case "this month", "thang nay": component = .month; previous = false
        case "last month", "thang truoc": component = .month; previous = true
        case "this year", "nam nay": component = .year; previous = false
        case "last year", "nam truoc": component = .year; previous = true
        default: return nil
        }
        guard let interval = calendar.dateInterval(of: component, for: now) else { return nil }
        if !previous { return (interval.start, interval.end) }
        guard let earlier = calendar.date(byAdding: component, value: -1, to: interval.start),
              let prior = calendar.dateInterval(of: component, for: earlier) else { return nil }
        return (prior.start, prior.end)
    }

    func parseSize(_ value: String) -> (SearchComparison, Int64)? {
        let pattern = #"^(>=|<=|>|<|=)?([0-9]+(?:[.,][0-9]+)?)(b|kb|mb|gb|tb|kib|mib|gib|tib)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func group(_ number: Int) -> String {
            guard let range = Range(match.range(at: number), in: value) else { return "" }
            return String(value[range])
        }
        guard let number = Double(group(2).replacingOccurrences(of: ",", with: ".")) else { return nil }
        let multipliers: [String: Double] = ["":1, "b":1, "kb":1024, "mb":1048576, "gb":1073741824, "tb":1099511627776, "kib":1024, "mib":1048576, "gib":1073741824, "tib":1099511627776]
        let bytes = number * (multipliers[group(3).lowercased()] ?? 1)
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        let comparison: SearchComparison
        switch group(1) { case "<": comparison = .less; case "<=": comparison = .lessEqual; case ">": comparison = .greater; case ">=": comparison = .greaterEqual; default: comparison = .equal }
        return (comparison, Int64(bytes))
    }
}

private struct SearchRecord {
    let entry: FileEntry
    var sources: [String] = []
    var downloaded: Date? = nil
    var screenshot = false
    var local = true
}

private final class SearchMatcher {
    let plan: SearchPlan
    let contentEnabled: Bool
    let ocrEnabled: Bool
    /// Approved roots; contents are read only from files still inside them.
    let roots: [URL]
    var issues: [String] = []
    private var activeText: String?
    private var textLoaded = false

    init(plan: SearchPlan, contentEnabled: Bool, ocrEnabled: Bool, roots: [URL]) {
        self.plan = plan; self.contentEnabled = contentEnabled; self.ocrEnabled = ocrEnabled; self.roots = roots
    }

    func matches(_ record: SearchRecord) -> Bool {
        activeText = nil; textLoaded = false
        return evaluate(plan.predicate, record)
    }

    private func contains(_ text: String, _ needle: String) -> Bool { searchFold(text).contains(searchFold(needle)) }

    private func evaluate(_ predicate: SearchPredicate, _ record: SearchRecord) -> Bool {
        let entry = record.entry
        switch predicate {
        case .all(let children): return children.allSatisfy { evaluate($0, record) }
        case .any(let children): return children.contains { evaluate($0, record) }
        case .not(let child): return !evaluate(child, record)
        case .text(let text): return contains(entry.name, text) || containsContent(text, record)
        case .name(let text): return contains(entry.name, text)
        case .path(let text): return contains(entry.url.path, text)
        case .ext(let value): return searchFold(entry.url.pathExtension) == searchFold(value)
        case .tag(let text): return entry.tags.contains { contains($0, text) }
        case .source(let text): return record.sources.contains { matchesSource($0, text) }
        case .content(let text): return containsContent(text, record)
        case .kind(let kind): return matchesKind(kind, record)
        case .size(let relation, let size):
            guard !entry.isDirectory else { return false }
            switch relation { case .less: return entry.size < size; case .lessEqual: return entry.size <= size; case .equal: return entry.size == size; case .greaterEqual: return entry.size >= size; case .greater: return entry.size > size }
        case .date(let field, let start, let end):
            let date: Date?
            switch field { case .modified: date = entry.modified; case .created: date = entry.created; case .downloaded: date = record.downloaded }
            guard let date else { return false }
            return (start == nil || date >= start!) && (end == nil || date < end!)
        }
    }

    private func matchesSource(_ source: String, _ query: String) -> Bool {
        let needle = searchFold(query).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !needle.contains("/"), let host = URL(string: source)?.host?.lowercased() else { return contains(source, query) }
        if needle.contains(".") { return host == needle || host.hasSuffix("." + needle) }
        return host.split(separator: ".").contains { $0 == needle }
    }

    private func matchesKind(_ kind: String, _ record: SearchRecord) -> Bool {
        let entry = record.entry
        if ["folder", "folders", "directory", "thu muc"].contains(kind) { return entry.isDirectory }
        if ["file", "files", "tep"].contains(kind) { return !entry.isDirectory }
        guard !entry.isDirectory else { return false }
        let ext = entry.url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        switch kind {
        case "screenshot", "screenshots": return record.screenshot || ["screenshot", "screen shot", "anh chup man hinh"].contains { contains(entry.name, $0) }
        case "image", "images", "photo", "photos", "picture", "anh": return type?.conforms(to: .image) == true
        case "video", "videos", "movie", "movies": return type?.conforms(to: .movie) == true
        case "audio", "music", "nhac": return type?.conforms(to: .audio) == true
        case "pdf", "pdfs": return ext == "pdf"
        case "text": return type?.conforms(to: .text) == true
        case "archive", "archives": return type?.conforms(to: .archive) == true || ["zip", "7z", "rar", "gz", "tar", "bz2", "xz"].contains(ext)
        case "document", "documents": return type?.conforms(to: .text) == true || ["pdf", "doc", "docx", "pages", "odt", "xls", "xlsx", "numbers", "ppt", "pptx", "key"].contains(ext)
        case "spreadsheet", "spreadsheets": return ["csv", "tsv", "xls", "xlsx", "numbers", "ods"].contains(ext)
        case "presentation", "presentations": return ["ppt", "pptx", "key", "odp"].contains(ext)
        case "app", "apps": return ext == "app"
        case "code": return type?.conforms(to: .sourceCode) == true || ["swift", "py", "js", "ts", "tsx", "jsx", "c", "cpp", "h", "rs", "go", "java", "html", "css", "sh"].contains(ext)
        default: return ext == kind || contains(entry.kind, kind)
        }
    }

    private func containsContent(_ text: String, _ record: SearchRecord) -> Bool {
        guard contentEnabled || ocrEnabled, !record.entry.isDirectory, record.local, !Task.isCancelled else { return false }
        if !textLoaded {
            textLoaded = true
            do { activeText = try loadText(record).map(searchFold) }
            catch { if issues.count < 12 { issues.append("\(record.entry.name): \(error.localizedDescription)") } }
        }
        return activeText?.contains(searchFold(text)) ?? false
    }

    private func loadText(_ record: SearchRecord) throws -> String? {
        try Task.checkCancellation()
        let url = record.entry.url
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let isText = type?.conforms(to: .text) == true || ["md", "csv", "log", "json", "yaml", "yml", "swift", "js", "ts", "py", "sh", "toml", "xml"].contains(ext)
        guard ext == "pdf" || (contentEnabled && isText) || (ocrEnabled && type?.conforms(to: .image) == true) else { return nil }
        // Scanned metadata can be up to 10 s old: a folder may since have become a symlink out of scope, or gone online-only.
        let current = URL(fileURLWithPath: url.path) // a fresh URL, so no cached resource values
        guard roots.contains(where: { isInside(current.resolvingSymlinksInPath().standardizedFileURL, root: $0) }),
              isLocallyAvailable(current, values: try? current.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .volumeIsLocalKey])) else { return nil }
        let fileSize = Int64(try current.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        // shortcut: bounded extraction keeps interactive search responsive; use a dedicated indexer for larger documents.
        if (contentEnabled || ocrEnabled) && ext == "pdf" {
            guard fileSize <= 32 * 1024 * 1024 else { note("\(url.lastPathComponent): PDF exceeds the 32 MiB search limit."); return nil }
            guard let document = PDFDocument(url: url) else { throw OperationFailure.message("Cannot read PDF (possibly encrypted).") }
            guard !document.isLocked else { throw OperationFailure.message("PDF is password protected.") }
            let pageLimit = contentEnabled ? 200 : 20
            if document.pageCount > pageLimit { note("\(url.lastPathComponent): only the first \(pageLimit) PDF pages were searched.") }
            if ocrEnabled && document.pageCount > 20 { note("\(url.lastPathComponent): PDF OCR is limited to the first 20 pages.") }
            var text = ""
            var byteCount = 0
            for pageIndex in 0..<min(document.pageCount, pageLimit) {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex) else { continue }
                let nativeText = contentEnabled ? (page.string ?? "") : ""
                var pageText = nativeText
                if ocrEnabled && pageIndex < 20 && nativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let thumbnail = page.thumbnail(of: NSSize(width: 2048, height: 2048), for: .mediaBox)
                    if let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) { pageText = try recognize(image) }
                }
                byteCount += pageText.utf8.count + 1
                if byteCount > 8 * 1024 * 1024 { note("\(url.lastPathComponent): extracted text reached the 8 MiB limit."); break }
                text += pageText + "\n"
            }
            return text
        }
        if contentEnabled && isText {
            guard fileSize <= 8 * 1024 * 1024 else { note("\(url.lastPathComponent): text exceeds the 8 MiB search limit."); return nil }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let text = String(data: data, encoding: .utf8) { return text }
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
            throw OperationFailure.message("Unsupported text encoding; use UTF-8 or BOM-marked UTF-16.")
        }
        if ocrEnabled && type?.conforms(to: .image) == true {
            guard fileSize <= 32 * 1024 * 1024 else { note("\(url.lastPathComponent): image exceeds the 32 MiB OCR limit."); return nil }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                throw OperationFailure.message("Cannot decode image for OCR.")
            }
            return try recognize(image)
        }
        return nil
    }

    private func note(_ message: String) { if issues.count < 12 { issues.append(message) } }

    private func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
}

struct SearchOutput {
    let entries: [FileEntry]
    let issues: [String]
    let usedCache: Bool
}

actor LocalSearchIndex {
    static let shared = LocalSearchIndex()
    private struct Snapshot { let date: Date; let records: [SearchRecord]; let issues: [String] }
    private var cache: [String: Snapshot] = [:]

    func invalidateCache() { cache.removeAll() }
    /// Snapshots are reused for 10 s only; past that they just hold memory (a Home scan is ~1M records).
    func evictExpired() { cache = cache.filter { Date().timeIntervalSince($0.value.date) < 10 } }

    func search(plan: SearchPlan, roots: [URL], includeHidden: Bool, contentEnabled: Bool, ocrEnabled: Bool) throws -> SearchOutput {
        try Task.checkCancellation()
        guard !roots.isEmpty else {
            cache.removeAll()
            return SearchOutput(entries: [], issues: ["Choose an approved search folder first."], usedCache: false)
        }
        var records: [SearchRecord] = []
        var issues: [String] = []
        var usedCache = false
        var acceptedRoots: [URL] = []
        for raw in roots {
            guard raw.isFileURL else { issues.append("Search scope is not a local file URL: \(raw.absoluteString)"); continue }
            let root = raw.resolvingSymlinksInPath().standardizedFileURL
            if acceptedRoots.contains(where: { root.path == $0.path || root.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }) { continue }
            acceptedRoots.removeAll { $0.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") }
            acceptedRoots.append(root)
        }
        let scopedRoots = acceptedRoots.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() } }
        // Retain metadata only for currently approved roots; never persist content or OCR text.
        let needsMetadata = plan.predicate.needsMetadata
        func cacheKey(_ root: URL, metadata: Bool) -> String { root.path + (includeHidden ? "|hidden" : "|visible") + (metadata ? "|meta" : "") }
        let allowedKeys = Set(acceptedRoots.flatMap { [cacheKey($0, metadata: false), cacheKey($0, metadata: true)] })
        cache = cache.filter { allowedKeys.contains($0.key) }
        guard !plan.predicate.needsContent || contentEnabled || ocrEnabled else {
            return SearchOutput(entries: [], issues: ["Content filters require the Text/PDF or OCR opt-in in Settings."], usedCache: false)
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .volumeIsLocalKey]
        for root in acceptedRoots {
            try Task.checkCancellation()
            let key = cacheKey(root, metadata: needsMetadata)
            do {
                let rootValues = try root.resourceValues(forKeys: Set(keys))
                guard isLocallyAvailable(root, values: rootValues) else {
                    cache.removeValue(forKey: key)
                    issues.append("Skipped online-only, unavailable or non-local search folder without enumerating descendants: \(root.path)")
                    continue
                }
            } catch {
                cache.removeValue(forKey: key)
                issues.append("\(root.path): \(error.localizedDescription)")
                continue
            }
            if let snapshot = cache[key], Date().timeIntervalSince(snapshot.date) < 10 {
                records += snapshot.records; issues += snapshot.issues; usedCache = true; continue
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
                issues.append("Search folder is missing or is not a directory: \(root.path)"); continue
            }
            var scanIssues: [String] = []
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys + FileEntry.resourceKeys, options: options, errorHandler: { url, error in
                if scanIssues.count < 12 { scanIssues.append("\(url.path): \(error.localizedDescription)") }
                return true
            }) else { issues.append("Cannot enumerate \(root.path)"); continue }
            var rootRecords: [SearchRecord] = []
            let scanRoot = URL(fileURLWithPath: kernelPath(root))
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                do {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    // The enumerator never follows links. skipDescendants() only after a folder: after a file or link
                    // it can skip the contents of a folder returned just before, silently dropping results.
                    if values.isSymbolicLink == true { continue }
                    guard isInside(url, root: scanRoot) else { if values.isDirectory == true { enumerator.skipDescendants() }; continue }
                    let local = isLocallyAvailable(url, values: values)
                    if values.isDirectory == true && !local {
                        enumerator.skipDescendants()
                        if scanIssues.count < 12 { scanIssues.append("Skipped descendants of online-only, unavailable or non-local folder: \(url.path)") }
                    }
                    let entry = try FileEntry(url: url)
                    var record = SearchRecord(entry: entry)
                    record.local = local
                    if local, needsMetadata {
                        // Spotlight takes these from the file's own attributes; reading them directly costs microseconds, not a Spotlight round trip.
                        record.sources = metadataAttribute(url, "kMDItemWhereFroms") as? [String] ?? []
                        record.downloaded = (metadataAttribute(url, "kMDItemDownloadedDate") as? [Date])?.first
                        record.screenshot = metadataAttribute(url, "kMDItemIsScreenCapture") as? Bool ?? false
                    }
                    rootRecords.append(record)
                } catch {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { enumerator.skipDescendants() }
                    if scanIssues.count < 12 { scanIssues.append("\(url.path): \(error.localizedDescription)") }
                }
            }
            try Task.checkCancellation()
            cache[key] = Snapshot(date: Date(), records: rootRecords, issues: scanIssues)
            records += rootRecords; issues += scanIssues
        }
        // OCR is costly per image: plain words search names and text/PDF contents, only content: filters run OCR.
        let matcher = SearchMatcher(plan: plan, contentEnabled: contentEnabled, ocrEnabled: ocrEnabled && plan.predicate.needsContent, roots: acceptedRoots)
        var entries: [FileEntry] = []
        var seen = Set<String>()
        for record in records {
            try Task.checkCancellation()
            if seen.insert(record.entry.id).inserted && matcher.matches(record) { entries.append(record.entry) }
        }
        if (contentEnabled || ocrEnabled) && records.contains(where: { !$0.local }) {
            issues.append("Online-only files were not downloaded or searched for content.")
        }
        issues += matcher.issues.prefix(12)
        entries.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return SearchOutput(entries: entries, issues: Array(issues.prefix(20)), usedCache: usedCache)
    }
    /// A `com.apple.metadata:<name>` attribute (a property list), as written by browsers and screencapture.
    private func metadataAttribute(_ url: URL, _ name: String) -> Any? {
        let key = "com.apple.metadata:" + name
        let count = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard count > 0 && count <= 1024 * 1024 else { return nil }
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
        guard actual == count else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

}

/// The path as the kernel spells it (`/private/var/…`, the form directory enumerators return), unlike
/// `resolvingSymlinksInPath()`, which strips `/private`.
func kernelPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A plain path check: the scan never follows links, so resolving every result again
/// (about 47 µs each) would only repeat what the scan guarantees.
private func isInside(_ url: URL, root: URL) -> Bool {
    url.path == root.path || url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
}

private func isLocallyAvailable(_ url: URL, values: URLResourceValues?) -> Bool {
    guard values?.volumeIsLocal == true else { return false }
    if values?.isUbiquitousItem == true {
        guard values?.ubiquitousItemDownloadingStatus == .current || values?.ubiquitousItemDownloadingStatus == .downloaded else { return false }
    }
    return CloudLocations.isReadableLocally(url)
}

@MainActor
final class SearchService: ObservableObject {
    @Published var results: [FileEntry] = []
    @Published var isSearching = false
    @Published var status = "Choose search folders in Settings."
    @Published var plan = NaturalQuery.parse("")
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var privacyObservation: AnyCancellable?

    init(preferences: AppPreferences) {
        privacyObservation = Publishers.CombineLatest3(preferences.$searchRoots, preferences.$contentEnabled, preferences.$ocrEnabled)
            .dropFirst()
            .sink { [weak self] _ in
                self?.cancel()
                self?.results = []
                Task { await LocalSearchIndex.shared.invalidateCache() }
            }
    }

    deinit { task?.cancel() }

    static func invalidateCache() async {
        await LocalSearchIndex.shared.invalidateCache()
    }

    func search(_ text: String, roots: [URL], includeHidden: Bool, contentEnabled: Bool, ocrEnabled: Bool) {
        task?.cancel()
        let token = UUID()
        generation = token
        let parsed = NaturalQuery.parse(text)
        plan = parsed
        results = []
        isSearching = true
        status = "Searching approved folders locally…"
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let output = try await LocalSearchIndex.shared.search(plan: parsed, roots: roots, includeHidden: includeHidden, contentEnabled: contentEnabled, ocrEnabled: ocrEnabled)
                try Task.checkCancellation()
                await self?.complete(output, token: token)
            } catch is CancellationError {
                // A newer search owns the UI; cancelled work never publishes partial results.
            } catch {
                await self?.failed(error.localizedDescription, token: token)
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil; generation = UUID()
        isSearching = false
        status = "Search cancelled."
    }

    private func complete(_ output: SearchOutput, token: UUID) {
        Task { try? await Task.sleep(for: .seconds(11)); await LocalSearchIndex.shared.evictExpired() }
        guard generation == token else { return }
        results = output.entries
        isSearching = false; task = nil
        plan.warnings += output.issues
        status = "\(results.count) results · local approved scopes" + (output.usedCache ? " · metadata cached up to 10 s" : "")
        if !output.issues.isEmpty { status += " · \(output.issues.count) issues (see filters)" }
    }

    private func failed(_ message: String, token: UUID) {
        guard generation == token else { return }
        isSearching = false; task = nil
        status = "Search failed: \(message)"
        plan.warnings.append(message)
    }
}
