// SettingsView.swift — the Settings window: Look · Reminders · News · Hour Map · General.
// Every change applies live and is saved straight away.
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store = Store.shared
    let calendar: CalendarService
    let reminders: ReminderCenter
    let news: NewsService

    var body: some View {
        TabView {
            LookSettings().tabItem { Label("Look", systemImage: "paintpalette") }
            ReminderSettingsView(calendar: calendar, reminders: reminders).tabItem { Label("Reminders", systemImage: "bell") }
            NewsSettingsView(news: news).tabItem { Label("News", systemImage: "newspaper") }
            HourSettingsView().tabItem { Label("Hour Map", systemImage: "chart.bar") }
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(width: 560, height: 560)
    }
}

/// Binds a SwiftUI ColorPicker to a saved RGBA value.
func colorBinding(_ b: Binding<RGBA>) -> Binding<Color> {
    Binding(get: { b.wrappedValue.color }, set: { b.wrappedValue = RGBA(color: $0) })
}

struct LookSettings: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        Form {
            Section("Colours") {
                ColorPicker("Background", selection: colorBinding($store.settings.look.background), supportsOpacity: true)
                ColorPicker("Accent", selection: colorBinding($store.settings.look.accent), supportsOpacity: false)
                ColorPicker("Text", selection: colorBinding($store.settings.look.text), supportsOpacity: false)
                HStack {
                    Text("Presets")
                    ForEach(Look.presets, id: \.0) { p in
                        Button(p.0) { store.settings.look.background = p.1; store.settings.look.accent = p.2; store.settings.look.text = p.3 }
                            .controlSize(.small)
                    }
                }
                Picker("System controls", selection: $store.settings.look.mode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("Shape and size") {
                Picker("Collapsed badge", selection: $store.settings.look.badgeShape) {
                    ForEach(BadgeShape.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                slider("Badge size", $store.settings.look.badgeSize, 40...140, "%.0f pt")
                slider("Panel corners", $store.settings.look.cornerRadius, 0...60, "%.0f pt")
                slider("Panel width", $store.settings.look.panelWidth, 280...640, "%.0f pt")
                slider("Panel height", $store.settings.look.panelHeight, 320...900, "%.0f pt")
                slider("Text size", $store.settings.look.fontSize, 10...20, "%.0f pt")
                slider("Opacity", $store.settings.look.opacity, 0.3...1, "%.2f")
                Toggle("Keep on top of other windows", isOn: $store.settings.look.alwaysOnTop)
            }
            Button("Reset look to default") { store.settings.look = Look() }
        }.formStyle(.grouped)
    }

    func slider(_ name: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ fmt: String) -> some View {
        HStack {
            Text(name).frame(width: 110, alignment: .leading)
            Slider(value: v, in: r)
            Text(String(format: fmt, v.wrappedValue)).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }
}

struct ReminderSettingsView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var calendar: CalendarService
    let reminders: ReminderCenter

    var body: some View {
        Form {
            Section("Pop-out reminders") {
                Toggle("Show a reminder card before events", isOn: $store.settings.reminders.enabled)
                Stepper("Default: \(store.settings.reminders.leadMinutes) min before", value: $store.settings.reminders.leadMinutes, in: 0...1440, step: 5)
                Stepper("Snooze for \(store.settings.reminders.snoozeMinutes) min", value: $store.settings.reminders.snoozeMinutes, in: 1...60)
                Toggle("Remind me about all-day events too", isOn: $store.settings.reminders.includeAllDay)
                Toggle("Play a sound", isOn: $store.settings.reminders.sound)
                Button("Show a test reminder") { reminders.showTest() }
            }
            Section("Where events come from") {
                Picker("Source", selection: $store.settings.reminders.source) {
                    ForEach(CalendarSource.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.radioGroup)
                if store.settings.reminders.source == .system {
                    HStack {
                        Text(calendar.access == .granted ? "✅ Calendar access granted" : "Calendar access not granted yet")
                        Spacer()
                        if calendar.access == .unknown { Button("Connect") { calendar.requestAccess() } }
                        if calendar.access == .denied {
                            Button("Open Privacy Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                            }
                        }
                    }
                    Text("To see Google Calendar here: System Settings › Internet Accounts › Add Account › Google, and tick Calendars.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    TextField("https://calendar.google.com/calendar/ical/…/basic.ics", text: $store.settings.reminders.icsURL)
                    Text("Google Calendar › Settings › your calendar › Integrate calendar › Secret address in iCal format. Read-only; anyone with this link can see your events, so keep it private.")
                        .font(.caption).foregroundColor(.secondary)
                    if let e = calendar.lastError { Text(e).foregroundColor(.orange) }
                }
            }
            if !calendar.calendars.isEmpty {
                Section("Per calendar (lead time overrides the default; untick to ignore)") {
                    ForEach(calendar.calendars, id: \.self) { name in
                        HStack {
                            Toggle(name, isOn: Binding(
                                get: { !store.settings.reminders.hiddenCalendars.contains(name) },
                                set: { on in
                                    store.settings.reminders.hiddenCalendars.removeAll { $0 == name }
                                    if !on { store.settings.reminders.hiddenCalendars.append(name) }
                                }))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { store.settings.reminders.perCalendar[name] ?? -1 },
                                set: { store.settings.reminders.perCalendar[name] = $0 < 0 ? nil : $0 })) {
                                Text("Default").tag(-1)
                                ForEach([0, 5, 10, 15, 30, 60, 120, 1440], id: \.self) { m in
                                    Text(m == 1440 ? "1 day" : m >= 60 ? "\(m / 60) h" : "\(m) min").tag(m)
                                }
                            }.labelsHidden().frame(width: 110)
                        }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

struct NewsSettingsView: View {
    @ObservedObject var store = Store.shared
    let news: NewsService
    @State private var name = ""
    @State private var url = ""
    @State private var cat: FeedCategory = .auto

    var body: some View {
        Form {
            Section("Feeds (free RSS — no account, no key)") {
                ForEach($store.settings.news.feeds) { $f in
                    HStack {
                        Toggle("", isOn: $f.enabled).labelsHidden()
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text(f.url).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("", selection: $f.category) { ForEach(FeedCategory.allCases) { Text($0.label).tag($0) } }
                            .labelsHidden().frame(width: 140)
                        Button { store.settings.news.feeds.removeAll { $0.id == f.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Name", text: $name).frame(width: 110)
                    TextField("Feed URL", text: $url)
                    Picker("", selection: $cat) { ForEach(FeedCategory.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 130)
                    Button("Add") {
                        store.settings.news.feeds.append(NewsFeed(name: name.isEmpty ? url : name, url: url, category: cat))
                        name = ""; url = ""
                    }.disabled(URL(string: url)?.scheme == nil)
                }
            }
            Section("Keywords for \"Auto\" feeds (comma-separated; English matches whole words, 中文 matches anywhere)") {
                ForEach(NewsTab.allCases) { t in
                    VStack(alignment: .leading) {
                        Text(t.label).bold()
                        TextEditor(text: Binding(
                            get: { (store.settings.news.keywords[t.rawValue] ?? []).joined(separator: ", ") },
                            set: { store.settings.news.keywords[t.rawValue] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                            .frame(height: 54).font(.system(size: 12))
                    }
                }
            }
            Section {
                Stepper("Refresh every \(store.settings.news.refreshMinutes) min", value: $store.settings.news.refreshMinutes, in: 5...240, step: 5)
                Stepper("Show up to \(store.settings.news.maxPerTab) per tab", value: $store.settings.news.maxPerTab, in: 10...200, step: 10)
                HStack {
                    Button("Refresh now") { news.refresh() }
                    Button("Restore default feeds and keywords") { store.settings.news = NewsSettings() }
                }
            }
        }.formStyle(.grouped)
    }
}

struct HourSettingsView: View {
    @ObservedObject var store = Store.shared
    @State private var newProject = ""

    var body: some View {
        Form {
            Section("Projects") {
                ForEach(Array(store.settings.hours.projects.enumerated()), id: \.offset) { i, p in
                    HStack {
                        Text(p); Spacer()
                        Button { store.deleteProject(p, deleteEntries: false) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("New project", text: $newProject)
                    Button("Add") { store.addProject(newProject); newProject = "" }
                }
            }
            Section("Count calendar events automatically") {
                Toggle("Add finished calendar events that match a rule", isOn: $store.settings.hours.autoLogCalendar)
                Text("A rule matches a calendar's name exactly, or any event whose title contains the text. First match wins.")
                    .font(.caption).foregroundColor(.secondary)
                ForEach($store.settings.hours.rules) { $r in
                    HStack {
                        TextField("Calendar name or title word", text: $r.match)
                        Image(systemName: "arrow.right")
                        Picker("", selection: $r.project) {
                            ForEach(store.settings.hours.projects, id: \.self) { Text($0).tag($0) }
                            if !store.settings.hours.projects.contains(r.project) { Text(r.project).tag(r.project) }
                        }.labelsHidden().frame(width: 130)
                        Button { store.settings.hours.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                }
                Button("Add rule") {
                    store.settings.hours.rules.append(HourRule(match: "", project: store.settings.hours.projects.first ?? "General"))
                }
            }
            Section {
                Button("Delete all timer sessions…") {
                    let a = NSAlert(); a.messageText = "Delete every Hour Map timer session?"; a.informativeText = "This can't be undone. Calendar events are not affected."
                    a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { store.hours.sessions = []; store.hours.running = nil }
                }.foregroundColor(.red)
            }
        }.formStyle(.grouped)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        Form {
            Section {
                Toggle("Open Deskmate when I log in", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Toggle("Keyboard shortcuts: ⌃⌥D show/hide · ⌃⌥V open Vault", isOn: $store.settings.general.hotkeys)
            }
            Section("Your data") {
                Text(store.folder.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }
                Text("Everything stays on this Mac. Deskmate uses no AI, no account and no tracking. It only goes online to read news feeds and, if you set one, your iCal address.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section {
                Button("Quit Deskmate") { NSApp.terminate(nil) }
            }
        }.formStyle(.grouped)
    }
}
