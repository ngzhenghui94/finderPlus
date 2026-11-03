import AppKit
import SwiftUI

@MainActor
struct KeyboardShortcutsView: View {
    @State private var draft: [String: String] = [:]
    @State private var commands: [Command] = []
    @State private var error: String?
    @State private var message = ""

    private struct Command: Identifiable {
        let title: String
        let shortcut: String
        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom shortcuts override menu shortcuts. Use cmd, ctrl, option, shift and one character, for example cmd+shift+k. Leave a field empty to keep its profile default.")
                .font(.caption).foregroundStyle(.secondary)
            List(commands) { command in
                HStack {
                    Text(command.title).frame(maxWidth: .infinity, alignment: .leading)
                    TextField(command.shortcut.isEmpty ? "Default" : command.shortcut, text: Binding(
                        get: { draft[command.title] ?? "" },
                        set: { draft[command.title] = $0 }
                    )).frame(width: 180)
                        .accessibilityLabel("Shortcut for \(command.title)")
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button("Import…") { importShortcuts() }
                Button("Export…") { exportShortcuts() }
                Button("Reset Customizations") { draft = [:]; error = nil; message = "Choose Apply to restore menu defaults." }
                Spacer()
                Button("Apply") { apply() }
            }
        }.padding(16).onAppear {
            commands = menuCommands()
            draft = UserDefaults.standard.dictionary(forKey: "customShortcuts") as? [String: String] ?? [:]
        }
    }

    private func menuCommands() -> [Command] {
        var found: [Command] = []
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { visit(submenu) }
                else if item.action != nil && !item.isSeparatorItem && AppDelegate.shared.commandTitles.contains(item.title) {
                    var parts: [String] = []
                    let flags = item.keyEquivalentModifierMask
                    if flags.contains(.command) { parts.append("cmd") }
                    if flags.contains(.control) { parts.append("ctrl") }
                    if flags.contains(.option) { parts.append("option") }
                    if flags.contains(.shift) { parts.append("shift") }
                    if !item.keyEquivalent.isEmpty { parts.append(item.keyEquivalent) }
                    if !found.contains(where: { $0.title == item.title }) {
                        found.append(Command(title: item.title, shortcut: item.keyEquivalent.isEmpty ? "" : parts.joined(separator: "+")))
                    }
                }
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func validated(_ input: [String: String]) throws -> [String: String] {
        try Self.validated(input, validTitles: Set(commands.map(\.title)), originalKeys: AppDelegate.shared.originalKeys)
    }

    static func shortcutParts(_ value: String) -> [String] {
        var parts = value.components(separatedBy: "+")
        if value.hasSuffix("++") {
            parts.removeLast()
            parts[parts.count - 1] = "+"
        }
        return parts
    }

    private static func validated(_ input: [String: String], validTitles: Set<String>, originalKeys: [String: (String, NSEvent.ModifierFlags)]) throws -> [String: String] {
        var output: [String: String] = [:]
        var used: [String: String] = [:]
        for (title, value) in input {
            guard validTitles.contains(title) else { throw OperationFailure.message("Unknown command in shortcuts: \(title)") }
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty { continue }
            let parts = shortcutParts(value)
            let modifiers = Array(parts.dropLast())
            guard let key = parts.last, key.count == 1, key.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }),
                  !modifiers.isEmpty, Set(modifiers).count == modifiers.count,
                  modifiers.allSatisfy({ ["cmd", "ctrl", "shift", "option", "alt"].contains($0) }),
                  modifiers.contains("cmd") || modifiers.contains("ctrl") || modifiers.contains("option") || modifiers.contains("alt") else {
                throw OperationFailure.message("Invalid shortcut for \(title). Use cmd/ctrl/option with one character; shift is optional.")
            }
            let normalized = Set(modifiers.map { $0 == "alt" ? "option" : $0 })
            let canonical = ["cmd", "ctrl", "option", "shift"].filter { normalized.contains($0) }.joined(separator: "+") + "+" + key
            var requestedFlags: NSEvent.ModifierFlags = []
            if normalized.contains("cmd") { requestedFlags.insert(.command) }
            if normalized.contains("ctrl") { requestedFlags.insert(.control) }
            if normalized.contains("option") { requestedFlags.insert(.option) }
            if normalized.contains("shift") { requestedFlags.insert(.shift) }
            let relevantFlags: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            for (other, original) in originalKeys where other != title {
                if original.0.lowercased() == key && original.1.intersection(relevantFlags) == requestedFlags {
                    throw OperationFailure.message("\(value) is reserved for \(other). Choose an unused shortcut.")
                }
            }
            if let other = used[canonical] { throw OperationFailure.message("\(title) and \(other) use the same shortcut.") }
            used[canonical] = title
            output[title] = canonical
        }
        return output
    }

    private func apply() {
        do {
            let shortcuts = try validated(draft)
            UserDefaults.standard.set(shortcuts, forKey: "customShortcuts")
            AppDelegate.shared.applyCustomShortcuts()
            draft = shortcuts
            commands = menuCommands()
            error = nil
            message = "Custom shortcuts applied. A shortcut that duplicates a built-in system shortcut may be intercepted by macOS."
        } catch { self.error = error.localizedDescription; message = "" }
    }

    private func importShortcuts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Import a FinderPlus shortcut JSON dictionary. Review and Apply before activation."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 1_048_576 else { throw OperationFailure.message("Shortcut files must be smaller than 1 MB.") }
            let imported = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
            draft = try validated(imported)
            error = nil
            message = "Imported for review. Choose Apply to activate."
        } catch { self.error = error.localizedDescription }
    }

    private func exportShortcuts() {
        do {
            let shortcuts = try validated(draft)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "FinderPlus-Shortcuts.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(shortcuts).write(to: url, options: .atomic)
            error = nil
            message = "Shortcuts exported."
        } catch { self.error = error.localizedDescription }
    }

    static func selfCheck() throws {
        let titles: Set<String> = ["Increase Icon Size", "Other", "Third"]
        let originals: [String: (String, NSEvent.ModifierFlags)] = ["Increase Icon Size": ("+", .command)]
        let imported = try JSONDecoder().decode([String: String].self, from: Data(#"{"Increase Icon Size":"cmd++","Other":"ctrl+shift++"}"#.utf8))
        let shortcuts = try validated(imported, validTitles: titles, originalKeys: originals)
        guard shortcuts == imported, shortcutParts(shortcuts["Increase Icon Size"]!) == ["cmd", "+"],
              shortcutParts(shortcuts["Other"]!) == ["ctrl", "shift", "+"] else {
            throw OperationFailure.message("Literal plus shortcuts did not survive import and activation parsing.")
        }
        for input in [
            ["Other": "cmd++"],
            ["Other": "ctrl++", "Third": "ctrl++"],
            ["Other": "cmd+cmd+k"],
            ["Other": "cmd+++"],
            ["Other": "cmd+\n"],
            ["Unknown": "ctrl+k"]
        ] {
            do { _ = try validated(input, validTitles: titles, originalKeys: originals) }
            catch { continue }
            throw OperationFailure.message("Invalid shortcut import was accepted: \(input)")
        }
    }
}
