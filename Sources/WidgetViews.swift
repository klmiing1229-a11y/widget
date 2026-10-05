// WidgetViews.swift — what the floating widget looks like: a small badge when collapsed,
// a panel with three tabs (News · Time · Vault) when expanded.
import AppKit
import SwiftUI

final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var newsTab: NewsTab = .tech
    @Published var timeMode = 0      // 0 = upcoming, 1 = hour map
    var openSettings: () -> Void = {}
}

struct WidgetRoot: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var news: NewsService
    @ObservedObject var calendar: CalendarService

    var body: some View {
        let look = store.settings.look
        Group {
            if store.settings.general.expanded { ExpandedPanel(news: news, calendar: calendar) }
            else { Badge(calendar: calendar) }
        }
        .font(.system(size: look.fontSize))
        .foregroundColor(look.text.color)
        .tint(look.accent.color)
    }
}

// MARK: - Collapsed badge

struct BadgeShapeView: Shape {
    let kind: BadgeShape
    func path(in r: CGRect) -> Path {
        switch kind {
        case .circle: return Circle().path(in: r)
        case .pill: return Capsule().path(in: r)
        case .rounded: return RoundedRectangle(cornerRadius: min(r.width, r.height) * 0.28).path(in: r)
        case .square: return RoundedRectangle(cornerRadius: 4).path(in: r)
        }
    }
}

struct Badge: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var calendar: CalendarService

    var body: some View {
        let look = store.settings.look
        let size = badgeSize(look)
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ZStack {
                BadgeShapeView(kind: look.badgeShape).fill(look.background.color)
                BadgeShapeView(kind: look.badgeShape).stroke(look.accent.color, lineWidth: 2)
                VStack(spacing: 1) {
                    if let run = store.hours.running {
                        Text(run.project).font(.system(size: size.height * 0.17, weight: .semibold)).lineLimit(1)
                        Text(short(ctx.date.timeIntervalSince(run.start))).font(.system(size: size.height * 0.22, weight: .bold)).monospacedDigit()
                    } else if let next = nextEvent(ctx.date) {
                        Image(systemName: "bell").font(.system(size: size.height * 0.18)).foregroundColor(look.accent.color)
                        Text(short(next.start.timeIntervalSince(ctx.date))).font(.system(size: size.height * 0.22, weight: .bold)).monospacedDigit()
                    } else {
                        Image(systemName: "square.grid.2x2.fill").font(.system(size: size.height * 0.34)).foregroundColor(look.accent.color)
                    }
                }.padding(6).minimumScaleFactor(0.5)
            }
            .frame(width: size.width, height: size.height)
            .overlay(DragArea { store.settings.general.expanded = true })
            .help("Click to open · drag to move")
        }
    }

    func nextEvent(_ now: Date) -> CalEvent? {
        calendar.visibleEvents.first { !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) < 12 * 3600 }
    }

    func short(_ t: TimeInterval) -> String {
        let m = max(0, Int(t / 60))
        return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))" : "\(m)m"
    }
}

func badgeSize(_ look: Look) -> CGSize {
    let s = CGFloat(look.badgeSize)
    return look.badgeShape == .pill ? CGSize(width: s * 2.1, height: s) : CGSize(width: s, height: s)
}

// MARK: - Expanded panel

struct ExpandedPanel: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var news: NewsService
    @ObservedObject var calendar: CalendarService

    var body: some View {
        let look = store.settings.look
        let shape = RoundedRectangle(cornerRadius: CGFloat(look.cornerRadius), style: .continuous)
        VStack(spacing: 0) {
            header(look)
            tabBar(look)
            Divider().opacity(0.3)
            Group {
                switch store.settings.general.tab {
                case "time": TimeView(calendar: calendar)
                case "vault": VaultView()
                default: NewsView(news: news)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, CGFloat(look.cornerRadius) * 0.25)
        .frame(width: CGFloat(look.panelWidth), height: CGFloat(look.panelHeight))
        .background(shape.fill(look.background.color))
        .overlay(shape.stroke(look.accent.color.opacity(0.35), lineWidth: 1))
        .clipShape(shape)
    }

    func header(_ look: Look) -> some View {
        HStack(spacing: 10) {
            Circle().fill(look.accent.color).frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(ctx.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(.system(size: look.fontSize, weight: .semibold))
            }
            Spacer()
            Button { UIState.shared.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("Settings")
            Button { store.settings.general.expanded = false } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).help("Collapse to badge")
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        .background(DragArea(onClick: nil))
    }

    func tabBar(_ look: Look) -> some View {
        HStack(spacing: 4) {
            ForEach([("news", "newspaper", "News"), ("time", "clock", "Time"), ("vault", "tray.full", "Vault")], id: \.0) { t in
                let on = store.settings.general.tab == t.0
                Button { store.settings.general.tab = t.0 } label: {
                    Label(t.2, systemImage: t.1).frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? look.accent.color.opacity(0.28) : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 10).padding(.bottom, 6)
    }
}

// MARK: - News tab

struct NewsView: View {
    @ObservedObject var news: NewsService
    @ObservedObject var ui = UIState.shared
    @ObservedObject var store = Store.shared

    var body: some View {
        let look = store.settings.look
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $ui.newsTab) {
                ForEach(NewsTab.allCases) { t in Text("\(t.label) \(news.items[t]?.count ?? 0)").tag(t) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    let list = news.items[ui.newsTab] ?? []
                    if list.isEmpty {
                        Text(news.loading ? "Loading…" : "No headlines yet. Check your internet connection, or the feeds in Settings › News.")
                            .opacity(0.6).padding(.top, 20)
                    }
                    ForEach(list) { item in
                        Button { if let u = URL(string: item.link) { NSWorkspace.shared.open(u) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(3).multilineTextAlignment(.leading)
                                Text(item.source + (item.date.map { " · " + ago($0) } ?? ""))
                                    .font(.system(size: look.fontSize - 2)).foregroundColor(look.accent.color.opacity(0.9))
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.trailing, 4)
            }
            HStack {
                if let t = news.lastUpdated { Text("Updated " + t.formatted(date: .omitted, time: .shortened)) }
                if !news.failedFeeds.isEmpty {
                    Text("· \(news.failedFeeds.count) feed\(news.failedFeeds.count == 1 ? "" : "s") failed")
                        .help(news.failedFeeds.joined(separator: ", "))
                }
                Spacer()
                Button { news.refresh() } label: { Image(systemName: news.loading ? "hourglass" : "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(news.loading)
            }.font(.system(size: look.fontSize - 2)).opacity(0.7)
        }
    }

    func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m)m ago" }
        if m < 1440 { return "\(m / 60)h ago" }
        return "\(m / 1440)d ago"
    }
}

// MARK: - Time tab (upcoming + Hour Map)

struct TimeView: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var ui = UIState.shared
    @ObservedObject var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $ui.timeMode) {
                Text("Upcoming").tag(0); Text("Hour Map").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if ui.timeMode == 1 { HourMapView(calendar: calendar) } else { upcoming }
        }
    }

    @ViewBuilder var upcoming: some View {
        let look = store.settings.look
        let s = store.settings.reminders
        HStack {
            Image(systemName: s.enabled ? "bell.fill" : "bell.slash").foregroundColor(s.enabled ? look.accent.color : .orange)
            Text("Remind me")
            Picker("", selection: $store.settings.reminders.leadMinutes) {
                ForEach([1, 5, 10, 15, 30, 60, 120], id: \.self) { Text(label($0)).tag($0) }
                if ![1, 5, 10, 15, 30, 60, 120].contains(s.leadMinutes) { Text(label(s.leadMinutes)).tag(s.leadMinutes) }
            }.labelsHidden().frame(width: 110)
            Text("before")
            Spacer()
            Toggle(s.enabled ? "On" : "Off", isOn: $store.settings.reminders.enabled).toggleStyle(.switch).controlSize(.mini)
                .help("Turn reminder pop-outs on or off")
        }
        if s.source == .system && calendar.access != .granted {
            VStack(alignment: .leading, spacing: 8) {
                Text(calendar.access == .denied
                     ? "Deskmate doesn't have Calendar access. Turn it on in System Settings › Privacy & Security › Calendars."
                     : "Connect your calendars. Deskmate reads events from the macOS Calendar app, so add your Google account in System Settings › Internet Accounts first.")
                    .fixedSize(horizontal: false, vertical: true).opacity(0.8)
                if calendar.access == .denied {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                } else { Button("Connect Calendar") { calendar.requestAccess() } }
                Text("Or paste a Google \"secret address in iCal format\" in Settings › Reminders.").font(.system(size: look.fontSize - 2)).opacity(0.6)
            }.padding(.top, 6)
        } else {
            if let err = calendar.lastError { Text(err).foregroundColor(.orange) }
            let upcoming = calendar.visibleEvents.filter { $0.end > Date() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if upcoming.isEmpty { Text("Nothing in the next 14 days.").opacity(0.6).padding(.top, 10) }
                    ForEach(groupByDay(upcoming), id: \.0) { day, evs in
                        Text(dayLabel(day)).font(.system(size: look.fontSize - 1, weight: .bold)).foregroundColor(look.accent.color).padding(.top, 4)
                        ForEach(evs) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(e.isAllDay ? "all day" : e.start.formatted(date: .omitted, time: .shortened))
                                    .monospacedDigit().frame(width: 62, alignment: .leading).opacity(0.8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title).lineLimit(2)
                                    Text(e.calendar + (e.isAllDay && !s.includeAllDay ? "" : " · 🔔 \(label(ReminderCenter.lead(for: e)))"))
                                        .font(.system(size: look.fontSize - 2)).opacity(0.55)
                                }
                            }
                        }
                    }
                }.padding(.trailing, 4)
            }
        }
    }

    func label(_ m: Int) -> String { m >= 60 && m % 60 == 0 ? "\(m / 60) h" : "\(m) min" }

    func groupByDay(_ evs: [CalEvent]) -> [(Date, [CalEvent])] {
        let cal = Calendar.current
        var out: [(Date, [CalEvent])] = []
        for e in evs {
            let d = cal.startOfDay(for: max(e.start, cal.startOfDay(for: Date())))
            if let i = out.firstIndex(where: { $0.0 == d }) { out[i].1.append(e) } else { out.append((d, [e])) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

// MARK: - Vault tab

struct VaultView: View {
    @ObservedObject var store = Store.shared
    @State private var editing = false
    @State private var copied: UUID?
    @State private var newLabel = ""
    @State private var newValue = ""

    var body: some View {
        let look = store.settings.look
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Click to copy").opacity(0.6)
                Spacer()
                Button(editing ? "Done" : "Edit") { editing.toggle() }.controlSize(.small)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(store.vault.enumerated()), id: \.element.id) { i, item in
                        if editing { editRow(i, look) } else { copyRow(item, look) }
                    }
                }.padding(.trailing, 4)
            }
            if editing {
                VStack(spacing: 6) {
                    TextField("Label (e.g. LinkedIn)", text: $newLabel).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Value (e.g. https://…)", text: $newValue).textFieldStyle(.roundedBorder).onSubmit(add)
                        Button("Add", action: add).disabled(newLabel.isEmpty || newValue.isEmpty)
                    }
                }
            }
            Text("Saved as a plain file on this Mac — don't save passwords here.")
                .font(.system(size: look.fontSize - 3)).opacity(0.5)
        }
    }

    func copyRow(_ item: VaultItem, _ look: Look) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.value, forType: .string)
            copied = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == item.id { copied = nil } }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label).bold()
                    Text(item.value).font(.system(size: look.fontSize - 2)).opacity(0.65).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if copied == item.id {
                    Text("Copied").font(.system(size: look.fontSize - 1, weight: .semibold)).foregroundColor(look.accent.color)
                } else {
                    Image(systemName: "doc.on.doc").opacity(0.6)
                }
                if let u = URL(string: item.value), u.scheme?.hasPrefix("http") == true {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).help("Open link")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(copied == item.id ? look.accent.color.opacity(0.25) : look.text.color.opacity(0.07)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func editRow(_ i: Int, _ look: Look) -> some View {
        HStack(spacing: 4) {
            VStack(spacing: 4) {
                TextField("Label", text: $store.vault[i].label).textFieldStyle(.roundedBorder)
                TextField("Value", text: $store.vault[i].value).textFieldStyle(.roundedBorder)
            }
            VStack(spacing: 2) {
                Button { if i > 0 { store.vault.swapAt(i, i - 1) } } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                Button { if i < store.vault.count - 1 { store.vault.swapAt(i, i + 1) } } label: { Image(systemName: "chevron.down") }
                    .disabled(i == store.vault.count - 1)
            }.buttonStyle(.plain)
            Button { store.vault.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundColor(.red)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(look.text.color.opacity(0.07)))
    }

    func add() {
        guard !newLabel.isEmpty, !newValue.isEmpty else { return }
        store.vault.append(VaultItem(label: newLabel, value: newValue))
        newLabel = ""; newValue = ""
    }
}

// MARK: - Drag to move, click to act

/// An invisible layer: drag it to move the widget, click it (without dragging) to run `onClick`.
struct DragArea: NSViewRepresentable {
    var onClick: (() -> Void)?
    func makeNSView(context: Context) -> DragNSView { let v = DragNSView(); v.onClick = onClick; return v }
    func updateNSView(_ v: DragNSView, context: Context) { v.onClick = onClick }
}

final class DragNSView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            if e.type == .leftMouseUp { break }
            if !moved && hypot(dx, dy) < 3 { continue }
            moved = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        if moved { NotificationCenter.default.post(name: .deskmateMoved, object: nil) }
        else { onClick?() }
    }
}

extension Notification.Name { static let deskmateMoved = Notification.Name("deskmateMoved") }
