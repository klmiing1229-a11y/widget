// HourMap.swift — where did my week go? Adds up timer sessions and (optionally) finished
// calendar events that match a rule, per project, for one Monday–Sunday week.
import AppKit
import SwiftUI

enum HourMath {
    /// The project a calendar event belongs to: first rule whose text equals the calendar name
    /// or appears in the event title (case-insensitive).
    static func project(for e: CalEvent) -> String? {
        for r in Store.shared.settings.hours.rules {
            let m = r.match.trimmingCharacters(in: .whitespaces).lowercased()
            guard !m.isEmpty else { continue }
            if e.calendar.lowercased() == m || e.title.lowercased().contains(m) { return r.project }
        }
        return nil
    }

    struct Row: Identifiable { let project: String; var timer: Double; var calendar: Double; var id: String { project }; var total: Double { timer + calendar } }

    /// "12 min", "1 h 05 min", "3 h".
    static func format(hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(String(format: "%02d", m % 60)) min"
    }

    /// Calendar events counted for a project in a week (finished, not all-day, matching a rule).
    static func calendarEntries(weekStart: Date, events: [CalEvent]) -> [(CalEvent, String)] {
        guard Store.shared.settings.hours.autoLogCalendar else { return [] }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
        return events.compactMap { e in
            guard !e.isAllDay, e.start >= weekStart, e.start < end, e.end <= Date(), let p = project(for: e) else { return nil }
            return (e, p)
        }
    }

    static func week(offset: Int, events: [CalEvent]) -> (start: Date, rows: [Row]) {
        let start = Calendar.current.date(byAdding: .day, value: 7 * offset, to: CalendarService.startOfWeek(Date()))!
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let now = Date()
        var rows: [String: Row] = [:]
        func add(_ p: String, timer: Double = 0, cal: Double = 0) {
            var r = rows[p] ?? Row(project: p, timer: 0, calendar: 0)
            r.timer += timer; r.calendar += cal; rows[p] = r
        }
        for s in Store.shared.hours.sessions where s.start >= start && s.start < end { add(s.project, timer: s.hours) }
        if let run = Store.shared.hours.running, run.start >= start, run.start < end {
            add(run.project, timer: now.timeIntervalSince(run.start) / 3600)
        }
        if Store.shared.settings.hours.autoLogCalendar {
            for e in events where !e.isAllDay && e.start >= start && e.start < end && e.end <= now {
                if let p = project(for: e) { add(p, cal: e.end.timeIntervalSince(e.start) / 3600) }
            }
        }
        return (start, rows.values.sorted { $0.total > $1.total })
    }

    static func exportCSV(events: [CalEvent]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "deskmate-hours.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["start,end,hours,project,source,title"]
        for s in Store.shared.hours.sessions.sorted(by: { $0.start < $1.start }) {
            lines.append([f.string(from: s.start), f.string(from: s.end), String(format: "%.2f", s.hours), q(s.project), "timer", ""].joined(separator: ","))
        }
        if Store.shared.settings.hours.autoLogCalendar {
            for e in events where !e.isAllDay && e.end <= Date() {
                guard let p = project(for: e) else { continue }
                lines.append([f.string(from: e.start), f.string(from: e.end), String(format: "%.2f", e.end.timeIntervalSince(e.start) / 3600),
                              q(p), "calendar", q(e.title)].joined(separator: ","))
            }
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

struct HourMapView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var calendar: CalendarService
    @State private var offset = 0
    @State private var managing = false
    @State private var adding = false
    @State private var newProject = ""
    @State private var editing: Session?        // entry being edited (new or existing)

    var body: some View {
        let look = store.settings.look
        let week = HourMath.week(offset: offset, events: calendar.visibleEvents)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Projects
                HStack {
                    Text("Projects").font(.system(size: look.fontSize, weight: .bold))
                    Spacer()
                    Button(managing ? "Done" : "Manage") { managing.toggle(); adding = false }.controlSize(.small)
                }
                if managing { manageList(look) } else { chips(look) }

                Divider().opacity(0.3)

                // Week
                HStack {
                    Button { offset -= 1; editing = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).disabled(offset <= -3)
                    Text(weekLabel(week.start)).bold()
                    Button { offset += 1; editing = nil } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(offset >= 0)
                    Spacer()
                    Text(HourMath.format(hours: week.rows.reduce(0) { $0 + $1.total })).opacity(0.75)
                }
                if week.rows.isEmpty {
                    Text("Nothing logged this week. Tap a project above to start its timer.")
                        .font(.system(size: look.fontSize - 1)).opacity(0.6).fixedSize(horizontal: false, vertical: true)
                } else {
                    let maxH = max(week.rows.map(\.total).max() ?? 1, 0.01)
                    ForEach(week.rows) { row in
                        let c = store.settings.hours.color(row.project).color
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(row.project); Spacer(); Text(HourMath.format(hours: row.total)).monospacedDigit().opacity(0.8) }
                            GeometryReader { g in
                                HStack(spacing: 0) {
                                    Rectangle().fill(c).frame(width: g.size.width * row.timer / maxH)
                                    Rectangle().fill(c.opacity(0.45)).frame(width: g.size.width * row.calendar / maxH)
                                    Spacer(minLength: 0)
                                }.clipShape(RoundedRectangle(cornerRadius: 3))
                            }.frame(height: 8)
                        }
                    }
                    Text("Solid = timer · faded = calendar events").font(.system(size: look.fontSize - 3)).opacity(0.5)
                }

                Divider().opacity(0.3)

                // Entries
                HStack {
                    Text("Entries").font(.system(size: look.fontSize, weight: .bold))
                    Spacer()
                    Button("+ Add entry") {
                        let end = offset == 0 ? Date() : Calendar.current.date(byAdding: .hour, value: 18, to: week.start)!
                        editing = Session(project: store.settings.hours.projects.first ?? "General", start: end.addingTimeInterval(-3600), end: end)
                    }.controlSize(.small)
                }
                if let e = editing, !store.hours.sessions.contains(where: { $0.id == e.id }) { editor(look) }
                entries(week.start, look)

                Button("Export CSV…") { HourMath.exportCSV(events: calendar.visibleEvents) }.controlSize(.small).padding(.top, 4)
            }.padding(.trailing, 6)
        }
    }

    // MARK: Project chips — tap to start, tap again to stop

    func chips(_ look: Look) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(store.settings.hours.projects, id: \.self) { p in
                    let running = store.hours.running?.project == p
                    let c = store.settings.hours.color(p).color
                    Button { running ? store.stopTimer() : store.startTimer(p) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: running ? "stop.fill" : "play.fill").font(.system(size: 9))
                            Text(p).lineLimit(1)
                            if running, let r = store.hours.running {
                                Spacer(minLength: 2)
                                Text(clock(ctx.date.timeIntervalSince(r.start))).monospacedDigit().font(.system(size: look.fontSize - 2))
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(running ? c.opacity(0.55) : c.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(c, lineWidth: running ? 1.5 : 0.5))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(running ? "Stop and save" : "Start timer for \(p)")
                }
                if adding {
                    TextField("Name", text: $newProject).textFieldStyle(.roundedBorder)
                        .onSubmit { if let p = store.addProject(newProject) { _ = p }; newProject = ""; adding = false }
                } else {
                    Button { adding = true } label: {
                        Label("New", systemImage: "plus").padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).stroke(look.text.color.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3])))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Manage: rename, colour, order, auto-count words, delete

    func manageList(_ look: Look) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.settings.hours.projects, id: \.self) { p in
                ProjectRow(project: p, look: look)
            }
            HStack {
                TextField("New project", text: $newProject).textFieldStyle(.roundedBorder)
                    .onSubmit { store.addProject(newProject); newProject = "" }
                Button("Add") { store.addProject(newProject); newProject = "" }
                    .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Rename onto an existing name to merge two projects. \"Auto-count\" adds finished calendar events whose title contains one of the words, or whose calendar has that name.")
                .font(.system(size: look.fontSize - 3)).opacity(0.55).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Entries for the week, newest first

    func entries(_ weekStart: Date, _ look: Look) -> some View {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
        let timer = store.hours.sessions.filter { $0.start >= weekStart && $0.start < end }
        let cal = HourMath.calendarEntries(weekStart: weekStart, events: calendar.visibleEvents)
        struct Item: Identifiable { let id: String; let project: String; let start: Date; let end: Date; let session: Session?; let title: String? }
        let items = (timer.map { Item(id: $0.id.uuidString, project: $0.project, start: $0.start, end: $0.end, session: $0, title: nil) }
                     + cal.map { Item(id: $0.0.id, project: $0.1, start: $0.0.start, end: $0.0.end, session: nil, title: $0.0.title) })
            .sorted { $0.start > $1.start }
        return VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty { Text("No entries this week.").font(.system(size: look.fontSize - 1)).opacity(0.5) }
            ForEach(items) { it in
                if let s = it.session, editing?.id == s.id {
                    editor(look)
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(store.settings.hours.color(it.project).color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(it.project + (it.title.map { " · " + $0 } ?? "")).lineLimit(1)
                            Text(it.start.formatted(.dateTime.weekday(.abbreviated).day()) + "  " + it.start.formatted(date: .omitted, time: .shortened)
                                 + "–" + it.end.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: look.fontSize - 2)).opacity(0.6)
                        }
                        Spacer()
                        Text(HourMath.format(hours: it.end.timeIntervalSince(it.start) / 3600)).monospacedDigit().font(.system(size: look.fontSize - 1))
                        if let s = it.session {
                            Button { editing = s } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit or delete")
                        } else {
                            Image(systemName: "calendar").opacity(0.5).help("Counted from your calendar. Change the project's auto-count words to change this.")
                        }
                    }.padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: Entry editor

    func editor(_ look: Look) -> some View {
        let isNew = !store.hours.sessions.contains { $0.id == editing?.id }
        let bind = Binding<Session>(get: { editing ?? Session(project: "", start: Date(), end: Date()) }, set: { editing = $0 })
        let valid = (editing.map { $0.end > $0.start }) ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Project", selection: bind.project) {
                ForEach(store.settings.hours.projects, id: \.self) { Text($0).tag($0) }
                if let p = editing?.project, !store.settings.hours.projects.contains(p) { Text(p).tag(p) }
            }
            DatePicker("Start", selection: bind.start, displayedComponents: [.date, .hourAndMinute])
            DatePicker("End", selection: bind.end, displayedComponents: [.date, .hourAndMinute])
            HStack {
                Text(valid ? HourMath.format(hours: bind.wrappedValue.hours) : "End must be after start")
                    .foregroundColor(valid ? look.text.color.opacity(0.7) : .orange)
                Spacer()
                if !isNew {
                    Button("Delete") { if let e = editing { store.deleteSession(e.id) }; editing = nil }.foregroundColor(.red)
                }
                Button("Cancel") { editing = nil }
                Button(isNew ? "Add" : "Save") { if let e = editing { store.saveSession(e) }; editing = nil }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(look.accent.color.opacity(0.12)))
    }

    func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    func weekLabel(_ start: Date) -> String {
        if offset == 0 { return "This week" }
        if offset == -1 { return "Last week" }
        return "Week of " + start.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// One project in Manage mode: colour, name (rename on Enter), order, auto-count words, delete.
struct ProjectRow: View {
    let project: String
    let look: Look
    @ObservedObject var store = Store.shared
    @State private var name = ""
    @State private var words = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ColorPicker("", selection: Binding(get: { store.settings.hours.color(project).color },
                                                   set: { store.settings.hours.colors[project] = RGBA(color: $0) }), supportsOpacity: false)
                    .labelsHidden().frame(width: 28)
                TextField("Name", text: $name, onEditingChanged: { focused in if !focused { commitName() } })
                    .textFieldStyle(.roundedBorder).onSubmit(commitName)
                Button { store.moveProject(project, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                Button { store.moveProject(project, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
                Button { confirmDelete() } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundColor(.red)
            }
            HStack(spacing: 4) {
                Text("Auto-count").font(.system(size: look.fontSize - 2)).opacity(0.6)
                TextField("e.g. ECON, lecture", text: $words, onEditingChanged: { focused in if !focused { commitWords() } })
                    .textFieldStyle(.roundedBorder).font(.system(size: look.fontSize - 2)).onSubmit(commitWords)
            }.padding(.leading, 34)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(look.text.color.opacity(0.06)))
        .onAppear(perform: load)
        .onChange(of: project) { _ in load() }
    }

    func load() {
        name = project
        words = store.settings.hours.rules.filter { $0.project == project }.map(\.match).joined(separator: ", ")
    }

    func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { name = project } else if n != project { store.renameProject(project, to: n) }
    }

    func commitWords() {
        var rules = store.settings.hours.rules.filter { $0.project != project }
        for w in words.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !w.isEmpty {
            rules.append(HourRule(match: w, project: project))
        }
        store.settings.hours.rules = rules
    }

    func confirmDelete() {
        let count = store.hours.sessions.filter { $0.project == project }.count
        if count == 0 { store.deleteProject(project, deleteEntries: false); return }
        let a = NSAlert()
        a.messageText = "Delete \"\(project)\"?"
        a.informativeText = "It has \(count) timer entr\(count == 1 ? "y" : "ies"). Keep them in your history, or delete them too?"
        a.addButton(withTitle: "Keep entries")
        a.addButton(withTitle: "Delete entries too")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: store.deleteProject(project, deleteEntries: false)
        case .alertSecondButtonReturn: store.deleteProject(project, deleteEntries: true)
        default: break
        }
    }
}
