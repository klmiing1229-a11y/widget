// Reminders.swift — pops a floating card before each calendar event.
// The lead time is set in Settings › Reminders (one default, plus an optional override per calendar).
import AppKit
import SwiftUI

final class ReminderCenter {
    let calendar: CalendarService
    private var timer: Timer?
    private var fired = Set<String>()                // occurrence ids already shown
    private var snoozed: [String: Date] = [:]        // occurrence id → show again at
    private var panels: [String: NSPanel] = [:]

    init(calendar: CalendarService) {
        self.calendar = calendar
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tick() }
    }

    static func lead(for e: CalEvent) -> Int {
        let s = Store.shared.settings.reminders
        return s.perCalendar[e.calendar] ?? s.leadMinutes
    }

    func tick() {
        let s = Store.shared.settings.reminders
        guard s.enabled else { return }
        let now = Date()
        for e in calendar.visibleEvents {
            if e.isAllDay && !s.includeAllDay { continue }
            if e.start < now.addingTimeInterval(-60) { continue }          // already started
            if let again = snoozed[e.id] {
                if now >= again { snoozed[e.id] = nil; show(e) }
                continue
            }
            if fired.contains(e.id) { continue }
            let fireAt = e.start.addingTimeInterval(-Double(Self.lead(for: e)) * 60)
            if now >= fireAt { fired.insert(e.id); show(e) }
        }
        // Close cards 10 minutes after their event started.
        for (id, panel) in panels where !id.hasPrefix("test-")
            && (calendar.events.first(where: { $0.id == id }).map({ $0.start < now.addingTimeInterval(-600) }) ?? true) {
            panel.close(); panels[id] = nil
        }
    }

    /// Shows a sample card so the user can see what a reminder looks like.
    func showTest() {
        let start = Date().addingTimeInterval(Double(Store.shared.settings.reminders.leadMinutes) * 60)
        show(CalEvent(id: "test-\(Date().timeIntervalSince1970)", title: "Test reminder", start: start,
                      end: start.addingTimeInterval(3600), isAllDay: false, calendar: "Deskmate", location: "Your desk"))
    }

    private func show(_ e: CalEvent) {
        FileHandle.standardError.write("Deskmate: reminder \(e.title) at \(e.start)\n".data(using: .utf8)!)
        panels[e.id]?.close()
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ReminderCard(event: e,
            onDismiss: { [weak self, weak panel] in panel?.close(); self?.panels[e.id] = nil },
            onSnooze: { [weak self, weak panel] in
                panel?.close(); self?.panels[e.id] = nil
                self?.snoozed[e.id] = Date().addingTimeInterval(Double(Store.shared.settings.reminders.snoozeMinutes) * 60)
            },
            onTrack: { [weak self, weak panel] in
                Store.shared.startTimer(HourMath.project(for: e) ?? Store.shared.settings.hours.projects.first ?? "General")
                panel?.close(); self?.panels[e.id] = nil
            })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 150)
        panel.contentView = host
        let fit = host.fittingSize
        // Stack cards down from the top-right corner of the main screen.
        if let screen = NSScreen.main?.visibleFrame {
            let y = screen.maxY - 16 - fit.height - CGFloat(panels.count) * (fit.height + 10)
            panel.setFrame(NSRect(x: screen.maxX - fit.width - 16, y: y, width: fit.width, height: fit.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        panels[e.id] = panel
        if Store.shared.settings.reminders.sound { NSSound(named: "Glass")?.play() }
    }
}

struct ReminderCard: View {
    let event: CalEvent
    let onDismiss: () -> Void
    let onSnooze: () -> Void
    let onTrack: () -> Void
    @ObservedObject var store = Store.shared

    var body: some View {
        let look = store.settings.look
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "bell.fill").foregroundColor(look.accent.color)
                    Text(countdown(ctx.date)).font(.system(size: 12, weight: .semibold)).foregroundColor(look.accent.color)
                    Spacer()
                    Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).opacity(0.7)
                }
                Text(event.title).font(.system(size: 15, weight: .bold)).lineLimit(2)
                Text(timeRange + (event.location.map { " · " + $0 } ?? "")).font(.system(size: 12)).opacity(0.8).lineLimit(1)
                Text(event.calendar).font(.system(size: 11)).opacity(0.55)
                HStack(spacing: 8) {
                    Button("Snooze \(store.settings.reminders.snoozeMinutes)m", action: onSnooze)
                    Button("Track time", action: onTrack)
                    Spacer()
                    Button("Dismiss", action: onDismiss).keyboardShortcut(.defaultAction)
                }.controlSize(.small).padding(.top, 2)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .foregroundColor(look.text.color)
            .background(RoundedRectangle(cornerRadius: min(look.cornerRadius, 24)).fill(look.background.color))
            .overlay(RoundedRectangle(cornerRadius: min(look.cornerRadius, 24)).stroke(look.accent.color.opacity(0.6), lineWidth: 1.5))
        }
    }

    var timeRange: String {
        if event.isAllDay { return "All day" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: event.start) + "–" + f.string(from: event.end)
    }

    func countdown(_ now: Date) -> String {
        let mins = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if mins <= 0 { return "Starting now" }
        if mins < 60 { return "Starts in \(mins) min" }
        return "Starts in \(mins / 60)h \(mins % 60)m"
    }
}

/// A borderless panel that can still take keyboard focus (for text fields and buttons).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
