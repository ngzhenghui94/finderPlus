import AppKit
import Network

/// Peer-to-peer file sharing between Macs running FinderPlus on the same network (Spacedrop-style).
/// Wire format: [UInt32 header length][JSON Offer] → receiver replies 1 byte (1 accept, 0 decline)
/// → sender streams each file's bytes in order → receiver replies 1 byte (1 saved).
// shortcut: plain TCP, not encrypted; add TLS with a pairing code before using on untrusted networks.
enum NearbyShare {
    static let serviceType = "_finderplus-drop._tcp"
    struct Offer: Codable { var sender: String; var files: [Item] }
    struct Item: Codable { var name: String; var size: Int64 }
    static let chunk = 1 << 20

    /// Trust boundary: names come from the network and must stay a single path component.
    static func safeName(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: ":", with: "-")
        return (try? OperationsEngine.validName(name)) == nil ? nil : name
    }

    /// Trust boundary: the offer's safe names, or nil when it must be refused.
    static func validNames(_ offer: Offer) -> [String]? {
        let names = offer.files.compactMap { safeName($0.name) }
        // 1 TiB per file: 10,000 of them total ~2^53, far below Int64's 2^63, so summing sizes cannot overflow.
        guard !offer.files.isEmpty, offer.files.count <= 10_000, names.count == offer.files.count,
              offer.files.allSatisfy({ (0...(1 << 40)).contains($0.size) }) else { return nil }
        return names
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 10
        // A peer that sleeps or drops off the network mid-transfer fails the connection in about a minute,
        // so the pending read throws and the partial file is removed instead of waiting forever.
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 20; tcp.keepaliveInterval = 10; tcp.keepaliveCount = 4
        return NWParameters(tls: nil, tcp: tcp)
    }

    static func send(_ files: [URL], from sender: String, to endpoint: NWEndpoint) async throws {
        let items = try files.map { Item(name: $0.lastPathComponent, size: Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)) }
        let connection = NWConnection(to: endpoint, using: parameters())
        connection.start(queue: .global())
        defer { connection.cancel() }
        let header = try JSONEncoder().encode(Offer(sender: sender, files: items))
        try await connection.write(withUnsafeBytes(of: UInt32(header.count).bigEndian) { Data($0) } + header)
        guard try await connection.read(1).first == 1 else { throw OperationFailure.message("The other Mac declined the files.") }
        for (url, item) in zip(files, items) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var remaining = item.size
            while remaining > 0 {
                guard let data = try handle.read(upToCount: Int(min(remaining, Int64(chunk)))), !data.isEmpty else { throw OperationFailure.message("\(item.name) changed while sending.") }
                try await connection.write(data); remaining -= Int64(data.count)
            }
        }
        guard try await connection.read(1).first == 1 else { throw OperationFailure.message("The other Mac could not save the files.") }
    }

    /// Returns the saved files, or [] when declined.
    static func receive(_ connection: NWConnection, into folder: URL, accept: @escaping (Offer) async -> Bool) async throws -> (Offer, [URL]) {
        defer { connection.cancel() }
        let length = try await connection.read(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= chunk else { throw OperationFailure.message("Invalid share request.") }
        let offer = try JSONDecoder().decode(Offer.self, from: await connection.read(length))
        guard let names = validNames(offer) else { throw OperationFailure.message("Invalid share request.") }
        let accepted = await withTaskCancellationHandler {
            await accept(offer)
        } onCancel: { connection.cancel() }
        try Task.checkCancellation()
        guard accepted else { try? await connection.write(Data([0])); return (offer, []) }
        try await connection.write(Data([1]))
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).finderplus-part")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var parts: [URL] = []
        for (index, item) in offer.files.enumerated() {
            let part = staging.appendingPathComponent(String(index))
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw OperationFailure.message("Cannot write to \(folder.path).") }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            var remaining = item.size
            while remaining > 0 {
                let data = try await connection.read(Int(min(remaining, Int64(chunk))))
                try handle.write(contentsOf: data); remaining -= Int64(data.count)
            }
            try handle.close()
            // Mark as downloaded so Gatekeeper checks received apps and scripts, like AirDrop does.
            var values = URLResourceValues(); values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "FinderPlus", kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload]
            var partURL = part; try partURL.setResourceValues(values)
            parts.append(part)
        }
        // Do not publish any files until the complete transfer has arrived.
        var saved: [URL] = []
        do {
            for (part, name) in zip(parts, names) {
                try Task.checkCancellation()
                saved.append(try moveToUniqueName(part, name: name, in: folder))
            }
        } catch {
            for url in saved { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        // The files are saved even if the sender disconnects before receiving its acknowledgement.
        try? await connection.write(Data([1]))
        return (offer, saved)
    }

    static func moveToUniqueName(_ source: URL, name: String, in folder: URL) throws -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...10_000 {
            let candidate = folder.appendingPathComponent(n == 1 ? name : ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            do { try FileManager.default.moveItem(at: source, to: candidate); return candidate }
            catch CocoaError.fileWriteFileExists { continue }
        }
        throw OperationFailure.message("Too many files named \(name).")
    }

    static func selfCheck() async throws {
        guard safeName("a.pdf") == "a.pdf", safeName("x:y") == "x-y", ["", ".", "..", "../etc", "a/b", "/abs", "a\0b", String(repeating: "a", count: 256)].allSatisfy({ safeName($0) == nil }),
              safeName(String(repeating: "a", count: 255)) != nil,
              validNames(Offer(sender: "x", files: [])) == nil,
              validNames(Offer(sender: "x", files: [Item(name: "a", size: -1)])) == nil,
              validNames(Offer(sender: "x", files: [Item(name: "a", size: .max), Item(name: "b", size: .max)])) == nil,
              validNames(Offer(sender: "x", files: Array(repeating: Item(name: "a", size: 1 << 50), count: 10_000))) == nil,
              validNames(Offer(sender: "x", files: Array(repeating: Item(name: "a", size: 1 << 40), count: 10_000)))?.count == 10_000,
              validNames(Offer(sender: "x", files: [Item(name: "a", size: 1)])) == ["a"] else { throw OperationFailure.message("Nearby share name check failed.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderPlus-share-\(UUID().uuidString)")
        let source = root.appendingPathComponent("out"), inbox = root.appendingPathComponent("in")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let big = Data((0..<(chunk * 2 + 7)).map { UInt8($0 % 251) })
        try big.write(to: source.appendingPathComponent("big.bin")); try Data().write(to: source.appendingPathComponent("empty.txt"))
        try Data("old".utf8).write(to: inbox.appendingPathComponent("big.bin"))
        let listener = try NWListener(using: parameters(), on: .any)
        defer { listener.cancel() }
        let (received, sink) = AsyncThrowingStream<[URL], Error>.makeStream()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task { do { sink.yield(try await receive(connection, into: inbox) { _ in true }.1); sink.finish() } catch { sink.finish(throwing: error) } }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port { ready.resume(returning: port) }
                if case .failed(let error) = state { ready.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
        try await send([source.appendingPathComponent("big.bin"), source.appendingPathComponent("empty.txt")], from: "check", to: .hostPort(host: "127.0.0.1", port: port))
        var results = received.makeAsyncIterator()
        guard let urls = try await results.next(), urls.map(\.lastPathComponent) == ["big 2.bin", "empty.txt"], try Data(contentsOf: urls[0]) == big, try Data(contentsOf: urls[1]).isEmpty,
              try Data(contentsOf: inbox.appendingPathComponent("big.bin")) == Data("old".utf8),
              try urls[0].resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil else { throw OperationFailure.message("Nearby share loopback check failed.") }
        for cancel in [false, true] {
            let interruptedInbox = root.appendingPathComponent(cancel ? "cancelled" : "truncated")
            try FileManager.default.createDirectory(at: interruptedInbox, withIntermediateDirectories: false)
            let (connections, pending) = AsyncStream<(NWConnection, Task<[URL], Error>)>.makeStream()
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                let task = Task { try await receive(connection, into: interruptedInbox) { _ in true }.1 }
                pending.yield((connection, task)); pending.finish()
            }
            let client = NWConnection(to: .hostPort(host: .ipv4(.loopback), port: port), using: parameters())
            client.start(queue: .global())
            defer { client.cancel() }
            let header = try JSONEncoder().encode(Offer(sender: "check", files: [Item(name: "first.txt", size: 0), Item(name: "second.txt", size: 2)]))
            try await client.write(withUnsafeBytes(of: UInt32(header.count).bigEndian) { Data($0) } + header)
            guard try await client.read(1).first == 1 else { throw OperationFailure.message("Interrupted share was not accepted.") }
            var iterator = connections.makeAsyncIterator()
            guard let (connection, task) = await iterator.next() else { throw OperationFailure.message("Interrupted share did not connect.") }
            defer { task.cancel(); connection.cancel() }
            // A failing cancellation regression must report a failure rather than hang the self-check.
            let watchdog = Task { try await Task.sleep(for: .seconds(2)); connection.cancel() }
            defer { watchdog.cancel() }
            try await client.write(Data([7]))
            if cancel { task.cancel() }
            else { client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in }) }
            let result = await task.result
            watchdog.cancel()
            let timeout = await watchdog.result
            guard case .failure = result, case .failure = timeout,
                  try FileManager.default.contentsOfDirectory(atPath: interruptedInbox.path).isEmpty else {
                throw OperationFailure.message("Nearby share interrupted-transfer cleanup failed (cancelled: \(cancel)).")
            }
        }
        print("Nearby share: name validation, loopback transfer, no overwrite, quarantine, interruption cleanup PASS")
    }
}

extension NWConnection {
    func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                send(content: data, completion: .contentProcessed { error in if let error { done.resume(throwing: error) } else { done.resume() } })
            }
            try Task.checkCancellation()
        } onCancel: { self.cancel() }
    }
    func read(_ count: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let data: Data = try await withCheckedThrowingContinuation { done in
                receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { done.resume(throwing: error) } else if let data, data.count == count { done.resume(returning: data) } else { done.resume(throwing: OperationFailure.message("The connection closed early.")) }
                }
            }
            try Task.checkCancellation()
            return data
        } onCancel: { self.cancel() }
    }
}

/// Advertises this Mac, discovers peers, and drives the send/receive UI.
@MainActor final class NearbyShareService {
    static let shared = NearbyShareService()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var ownName = Host.current().localizedName ?? "Mac"
    private var peers: [String: NWEndpoint] = [:]
    private var prompting = false
    private var transfers: [UUID: Task<Void, Never>] = [:]

    /// Opens the network inbox only while the user has turned Nearby Share on in Settings.
    func update(enabled: Bool) { if enabled { start() } else { stop() } }
    private func stop() {
        listener?.cancel(); browser?.cancel(); listener = nil; browser = nil; peers = [:]
        for task in transfers.values { task.cancel() }
        transfers = [:]
    }
    private func start() {
        guard listener == nil, let listener = try? NWListener(using: NearbyShare.parameters()) else { return }
        listener.service = NWListener.Service(name: ownName, type: NearbyShare.serviceType)
        listener.serviceRegistrationUpdateHandler = { change in
            if case .add(.service(let name, _, _, _)) = change { Task { @MainActor in self.ownName = name } }
        }
        listener.newConnectionHandler = { [weak listener] connection in
            guard let listener else { connection.cancel(); return }
            Task { @MainActor in
                guard self.listener === listener else { connection.cancel(); return }
                self.incoming(connection)
            }
        }
        listener.start(queue: .main)
        let browser = NWBrowser(for: .bonjour(type: NearbyShare.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak browser] results, _ in
            guard let browser else { return }
            Task { @MainActor in
                guard self.browser === browser else { return }
                self.peers = [:]
                for result in results { if case .service(let name, _, _, _) = result.endpoint, name != self.ownName { self.peers[name] = result.endpoint } }
            }
        }
        browser.start(queue: .main)
        self.listener = listener; self.browser = browser
    }

    func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard listener != nil else { explain("Turn on Nearby Share in Settings › General on both Macs, then try again."); return }
        guard urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) else { explain("Send to Nearby Mac sends files only. Compress folders first."); return }
        guard !peers.isEmpty else { explain("No nearby Macs found. Open FinderPlus on the other Mac and connect both Macs to the same network."); return }
        let names = peers.keys.sorted()
        let alert = NSAlert(); alert.messageText = "Send \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files") to:"
        alert.informativeText = "The other Mac must accept. Files are sent unencrypted over your local network."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26)); picker.addItems(withTitles: names); alert.accessoryView = picker
        alert.addButton(withTitle: "Send"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let name = picker.titleOfSelectedItem, let endpoint = peers[name] else { return }
        let sender = ownName
        let id = UUID()
        transfers[id] = Task {
            defer { transfers.removeValue(forKey: id) }
            do { try await NearbyShare.send(urls, from: sender, to: endpoint); explain("Sent \(urls.count) file\(urls.count == 1 ? "" : "s") to \(name).") }
            catch { if !Task.isCancelled { explain("Could not send to \(name): \(error.localizedDescription)") } }
        }
    }

    private func incoming(_ connection: NWConnection) {
        connection.start(queue: .global())
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let id = UUID()
        transfers[id] = Task {
            defer { transfers.removeValue(forKey: id) }
            do {
                let (offer, saved) = try await NearbyShare.receive(connection, into: downloads) { offer in self.ask(offer) }
                guard !saved.isEmpty, !Task.isCancelled else { return }
                let alert = NSAlert(); alert.messageText = "Received \(saved.count) file\(saved.count == 1 ? "" : "s") from \(offer.sender)"
                alert.informativeText = "Saved to Downloads."; alert.addButton(withTitle: "Show"); alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(saved) }
            } catch { if !Task.isCancelled { explain("Receiving files failed: \(error.localizedDescription)") } }
        }
    }

    private func ask(_ offer: NearbyShare.Offer) -> Bool {
        guard !prompting else { return false } // one request at a time; extra requests are declined
        prompting = true; defer { prompting = false }
        let total = ByteCountFormatter.string(fromByteCount: offer.files.reduce(0) { $0 + $1.size }, countStyle: .file)
        let list = offer.files.prefix(8).map(\.name).joined(separator: "\n") + (offer.files.count > 8 ? "\n…and \(offer.files.count - 8) more" : "")
        NSApp.requestUserAttention(.informationalRequest)
        let alert = NSAlert(); alert.messageText = "“\(offer.sender)” wants to send you \(offer.files.count) file\(offer.files.count == 1 ? "" : "s") (\(total))"
        alert.informativeText = list + "\n\nThe sender's name is not verified; accept only if you expect these files. Accepted files are saved to Downloads."
        alert.addButton(withTitle: "Accept"); alert.addButton(withTitle: "Decline")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
