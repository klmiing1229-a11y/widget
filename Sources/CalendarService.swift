// CalendarService.swift — reads events (never writes them).
// Route 1: macOS Calendar via EventKit. Add a Google account in System Settings › Internet Accounts
//          and its calendars show up here.
// Route 2: a Google Calendar "secret address in iCal format" (.ics URL), parsed locally.
import EventKit
import Combine
import Foundation

struct CalEvent: Identifiable, Hashable {
    let id: String          // unique per occurrence
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: String
    let location: String?
}

enum CalAccess { case unknown, granted, denied }

final class CalendarService: ObservableObject {
    @Published var events: [CalEvent] = []          // 4 weeks back → 14 days ahead
    @Published var calendars: [String] = []
    @Published var access: CalAccess = .unknown
    @Published var lastError: String?
    @Published var lastLoaded: Date?

    let store = EKEventStore()
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    init() {
        updateAccessState()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.reload() }
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &bag)
        Store.shared.$settings.map { [$0.reminders.source.rawValue, $0.reminders.icsURL] }.removeDuplicates().dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &bag)
    }

    var window: (Date, Date) {
        let cal = Calendar.current
        let weekStart = Self.startOfWeek(Date())
        return (cal.date(byAdding: .day, value: -21, to: weekStart)!, cal.date(byAdding: .day, value: 14, to: Date())!)
    }

    static func startOfWeek(_ d: Date) -> Date {
        var cal = Calendar(identifier: .iso8601); cal.timeZone = .current
        return cal.dateInterval(of: .weekOfYear, for: d)!.start   // Monday 00:00
    }

    func updateAccessState() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined: access = .unknown
        case .denied, .restricted: access = .denied
        default:
            if #available(macOS 14.0, *) { access = status == .fullAccess ? .granted : .denied }
            else { access = status == .authorized ? .granted : .denied }
        }
    }

    func requestAccess() {
        let done: (Bool, Error?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateAccessState(); self?.reload() }
        }
        if #available(macOS 14.0, *) { store.requestFullAccessToEvents(completion: done) }
        else { store.requestAccess(to: .event, completion: done) }
    }

    func reload() {
        let s = Store.shared.settings.reminders
        switch s.source {
        case .system: loadSystem()
        case .ics: loadICS(s.icsURL)
        }
    }

    private func loadSystem() {
        updateAccessState()
        guard access == .granted else { events = []; calendars = []; return }
        let (from, to) = window
        let cals = store.calendars(for: .event)
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        let evs = store.events(matching: pred).map {
            CalEvent(id: ($0.eventIdentifier ?? UUID().uuidString) + "@\($0.startDate.timeIntervalSince1970)",
                     title: $0.title ?? "(no title)", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                     calendar: $0.calendar.title, location: $0.location)
        }
        events = evs.sorted { $0.start < $1.start }
        calendars = Array(Set(cals.map(\.title))).sorted()
        FileHandle.standardError.write("Deskmate: calendar access granted; \(cals.count) calendars (\(cals.map { $0.source.title + ": " + $0.title }.sorted().joined(separator: " | "))); \(evs.count) events loaded\n".data(using: .utf8)!)
        lastError = nil
        lastLoaded = Date()
    }

    private func loadICS(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "webcal://", with: "https://")
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            events = []; calendars = []; lastError = trimmed.isEmpty ? nil : "That iCal address isn't a valid link."; return
        }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 30)) { [weak self] data, _, err in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (from, to) = self.window
            let parsed = text.contains("BEGIN:VCALENDAR") ? ICSParser.parse(text, from: from, to: to) : nil
            DispatchQueue.main.async {
                guard let parsed else {
                    self.lastError = err?.localizedDescription ?? "Couldn't read that iCal address."
                    return
                }
                self.events = parsed.events.sorted { $0.start < $1.start }
                self.calendars = [parsed.name]
                self.lastError = nil
                self.lastLoaded = Date()
            }
        }.resume()
    }

    var visibleEvents: [CalEvent] {
        let hidden = Set(Store.shared.settings.reminders.hiddenCalendars)
        return events.filter { !hidden.contains($0.calendar) }
    }
}

// MARK: - .ics parser with basic repeat rules

enum ICSParser {
    struct Raw { var props: [(String, [String: String], String)] = [] }

    static func parse(_ text: String, from: Date, to: Date) -> (name: String, events: [CalEvent]) {
        // Unfold continuation lines (lines starting with a space or tab belong to the previous line).
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = line.first, f == " " || f == "\t", !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else { lines.append(String(line)) }
        }
        var name = "iCal"
        var raws: [Raw] = []
        var cur: Raw? = nil
        for l in lines {
            if l == "BEGIN:VEVENT" { cur = Raw(); continue }
            if l == "END:VEVENT" { if let c = cur { raws.append(c) }; cur = nil; continue }
            guard let colon = l.firstIndex(of: ":") else { continue }
            let head = l[..<colon], value = String(l[l.index(after: colon)...])
            var parts = head.split(separator: ";").map(String.init)
            let key = parts.removeFirst().uppercased()
            var params: [String: String] = [:]
            for p in parts { let kv = p.split(separator: "=", maxSplits: 1); if kv.count == 2 { params[kv[0].uppercased()] = String(kv[1]) } }
            if cur == nil { if key == "X-WR-CALNAME" { name = unescape(value) }; continue }
            cur!.props.append((key, params, value))
        }

        var overrides: [String: [Date: Raw]] = [:]   // UID → original start → replacement
        var masters: [Raw] = []
        for r in raws {
            if let rid = r.props.first(where: { $0.0 == "RECURRENCE-ID" }), let uid = val(r, "UID"),
               let d = date(rid.2, rid.1)?.0 { overrides[uid, default: [:]][d] = r }
            else { masters.append(r) }
        }

        var out: [CalEvent] = []
        func emit(_ r: Raw, start: Date, end: Date, allDay: Bool, uid: String) {
            if (val(r, "STATUS") ?? "").uppercased() == "CANCELLED" { return }
            guard end > from, start < to else { return }
            out.append(CalEvent(id: uid + "@\(start.timeIntervalSince1970)", title: unescape(val(r, "SUMMARY") ?? "(no title)"),
                                start: start, end: end, isAllDay: allDay, calendar: name, location: val(r, "LOCATION").map(unescape)))
        }

        for r in masters {
            guard let ds = r.props.first(where: { $0.0 == "DTSTART" }), let (start, allDay, tz) = date(ds.2, ds.1) else { continue }
            let uid = val(r, "UID") ?? UUID().uuidString
            var duration: TimeInterval = allDay ? 86400 : 3600
            if let de = r.props.first(where: { $0.0 == "DTEND" }), let (end, _, _) = date(de.2, de.1) { duration = end.timeIntervalSince(start) }
            else if let dur = val(r, "DURATION") { duration = parseDuration(dur) ?? duration }
            let exdates = Set(r.props.filter { $0.0 == "EXDATE" }.flatMap { p in
                p.2.split(separator: ",").compactMap { date(String($0), p.1)?.0 } })

            guard let rule = val(r, "RRULE") else {
                emit(r, start: start, end: start.addingTimeInterval(duration), allDay: allDay, uid: uid); continue
            }
            for occ in expand(rule: rule, start: start, tz: tz, until: to) where !exdates.contains(occ) {
                if let o = overrides[uid]?[occ], let ds2 = o.props.first(where: { $0.0 == "DTSTART" }), let (s2, ad2, _) = date(ds2.2, ds2.1) {
                    var d2 = duration
                    if let de = o.props.first(where: { $0.0 == "DTEND" }), let (e2, _, _) = date(de.2, de.1) { d2 = e2.timeIntervalSince(s2) }
                    emit(o, start: s2, end: s2.addingTimeInterval(d2), allDay: ad2, uid: uid)
                } else {
                    emit(r, start: occ, end: occ.addingTimeInterval(duration), allDay: allDay, uid: uid)
                }
            }
        }
        return (name, out)
    }

    static func val(_ r: Raw, _ key: String) -> String? { r.props.first { $0.0 == key }?.2 }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Returns (date, isAllDay, timeZone used).
    static func date(_ value: String, _ params: [String: String]) -> (Date, Bool, TimeZone)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || v.count == 8 {
            f.dateFormat = "yyyyMMdd"; f.timeZone = .current
            return f.date(from: v).map { ($0, true, .current) }
        }
        if v.hasSuffix("Z") {
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: v).map { ($0, false, .current) }
        }
        let tz = params["TZID"].flatMap { TimeZone(identifier: $0.replacingOccurrences(of: "\"", with: "")) } ?? .current
        f.dateFormat = "yyyyMMdd'T'HHmmss"; f.timeZone = tz
        return f.date(from: v).map { ($0, false, tz) }
    }

    static func parseDuration(_ s: String) -> TimeInterval? {
        var total: TimeInterval = 0, num = "", inTime = false
        for c in s {
            if c.isNumber { num.append(c); continue }
            let n = Double(num) ?? 0; num = ""
            switch c {
            case "T": inTime = true
            case "W": total += n * 604800
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : n * 2592000
            case "S": total += n
            default: break
            }
        }
        return total > 0 ? total : nil
    }

    /// Expands DAILY / WEEKLY (with BYDAY) / MONTHLY / YEARLY rules with INTERVAL, COUNT and UNTIL.
    static func expand(rule: String, start: Date, tz: TimeZone, until windowEnd: Date) -> [Date] {
        var parts: [String: String] = [:]
        for p in rule.split(separator: ";") { let kv = p.split(separator: "=", maxSplits: 1); if kv.count == 2 { parts[String(kv[0])] = String(kv[1]) } }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let interval = max(1, Int(parts["INTERVAL"] ?? "1") ?? 1)
        let count = parts["COUNT"].flatMap { Int($0) }
        var until = windowEnd
        if let u = parts["UNTIL"], let (d, _, _) = date(u, [:]) { until = min(until, d.addingTimeInterval(u.count == 8 ? 86399 : 0)) }
        let freq = parts["FREQ"] ?? "WEEKLY"
        let dayMap = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let byDays = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { dayMap[String($0.suffix(2))] }

        var out: [Date] = []
        var produced = 0
        func add(_ d: Date) -> Bool {   // returns false when the rule is finished
            if d > until { return false }
            if let c = count, produced >= c { return false }
            if d >= start { out.append(d); produced += 1 }
            return true
        }
        var step = 0
        while step < 20000 {
            if freq == "WEEKLY" && !byDays.isEmpty {
                guard let weekBase = cal.date(byAdding: .weekOfYear, value: step * interval, to: start) else { break }
                let startWeekday = cal.component(.weekday, from: weekBase)
                var stop = false
                // Walk the days of this week in order, starting from the week's Monday (RFC default WKST=MO).
                let mondayOffset = (startWeekday + 5) % 7
                for dayIndex in 0..<7 {
                    guard let d = cal.date(byAdding: .day, value: dayIndex - mondayOffset, to: weekBase) else { continue }
                    if byDays.contains(cal.component(.weekday, from: d)) { if !add(d) { stop = true; break } }
                }
                if stop { break }
            } else {
                let comp: Calendar.Component = ["DAILY": .day, "MONTHLY": .month, "YEARLY": .year][freq] ?? .weekOfYear
                guard let d = cal.date(byAdding: comp, value: step * interval, to: start) else { break }
                if !add(d) { break }
            }
            step += 1
        }
        return out
    }
}
