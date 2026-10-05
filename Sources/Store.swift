// Store.swift — loads and saves settings, the vault and the Hour Map sessions.
import AppKit
import Combine
import SwiftUI

final class Store: ObservableObject {
    static let shared = Store()

    @Published var settings = Settings() { didSet { if settings != oldValue { save("settings.json", settings) } } }
    @Published var vault: [VaultItem] = [] { didSet { save("vault.json", vault) } }
    @Published var hours = HoursFile() { didSet { save("hours.json", hours) } }

    let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Deskmate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var loading = true

    private init() {
        if let d = try? Data(contentsOf: folder.appendingPathComponent("settings.json")) { settings = decodeMerged(Settings(), from: d) }
        if let d = try? Data(contentsOf: folder.appendingPathComponent("vault.json")) { vault = decodeMerged([VaultItem](), from: d) }
        else { vault = [VaultItem(label: "LinkedIn", value: "https://www.linkedin.com/in/your-name"),
                        VaultItem(label: "GitHub", value: "https://github.com/your-name")] }
        if let d = try? Data(contentsOf: folder.appendingPathComponent("hours.json")) { hours = decodeMerged(HoursFile(), from: d) }
        loading = false
        save("settings.json", settings); save("vault.json", vault)
    }

    private func save<T: Encodable>(_ name: String, _ value: T) {
        guard !loading else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value) {
            try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    // MARK: Hour Map timer

    func startTimer(_ project: String) {
        stopTimer()
        hours.running = RunningTimer(project: project, start: Date())
    }

    func stopTimer() {
        guard let r = hours.running else { return }
        let end = Date()
        if end.timeIntervalSince(r.start) >= 60 {     // ignore accidental sub-minute taps
            hours.sessions.append(Session(project: r.project, start: r.start, end: end))
        }
        hours.running = nil
    }

    // MARK: Hour Map projects and entries

    /// Adds a project unless one with the same name (ignoring capitals) exists. Returns the name in use.
    @discardableResult
    func addProject(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let existing = settings.hours.projects.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        settings.hours.projects.append(name)
        return name
    }

    /// Renames a project everywhere: its entries, rules, colour and a running timer.
    /// Renaming onto another project's name merges the two.
    func renameProject(_ old: String, to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        let target = settings.hours.projects.first { $0 != old && $0.caseInsensitiveCompare(new) == .orderedSame } ?? new
        var h = settings.hours
        if target == new, let i = h.projects.firstIndex(of: old) { h.projects[i] = new } else { h.projects.removeAll { $0 == old } }
        for i in h.rules.indices where h.rules[i].project == old { h.rules[i].project = target }
        if let c = h.colors.removeValue(forKey: old), h.colors[target] == nil { h.colors[target] = c }
        settings.hours = h
        var f = hours
        for i in f.sessions.indices where f.sessions[i].project == old { f.sessions[i].project = target }
        if f.running?.project == old { f.running?.project = target }
        hours = f
    }

    func deleteProject(_ name: String, deleteEntries: Bool) {
        settings.hours.projects.removeAll { $0 == name }
        settings.hours.rules.removeAll { $0.project == name }
        settings.hours.colors[name] = nil
        if hours.running?.project == name { stopTimer() }
        if deleteEntries { hours.sessions.removeAll { $0.project == name } }
    }

    func moveProject(_ name: String, by delta: Int) {
        guard let i = settings.hours.projects.firstIndex(of: name) else { return }
        let j = i + delta
        guard settings.hours.projects.indices.contains(j) else { return }
        settings.hours.projects.swapAt(i, j)
    }

    func saveSession(_ s: Session) {
        if let i = hours.sessions.firstIndex(where: { $0.id == s.id }) { hours.sessions[i] = s } else { hours.sessions.append(s) }
    }

    func deleteSession(_ id: UUID) { hours.sessions.removeAll { $0.id == id } }

    // MARK: Launch at login (a LaunchAgent file; removing the file turns it off)

    var loginAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.deskmate.app.plist")
    }
    var launchAtLogin: Bool { FileManager.default.fileExists(atPath: loginAgentURL.path) }

    func setLaunchAtLogin(_ on: Bool) {
        objectWillChange.send()
        if !on { try? FileManager.default.removeItem(at: loginAgentURL); return }
        let plist: [String: Any] = [
            "Label": "com.deskmate.app",
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        try? FileManager.default.createDirectory(at: loginAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: loginAgentURL)
        }
    }
}
