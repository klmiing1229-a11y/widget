// Models.swift — every piece of data Deskmate keeps, and where it is saved.
// All data lives in ~/Library/Application Support/Deskmate/ as plain JSON files.
import AppKit
import SwiftUI

// MARK: - Colours and shapes

/// A colour that can be saved to JSON (red, green, blue, alpha from 0 to 1).
struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        r = Double(ns.redComponent); g = Double(ns.greenComponent); b = Double(ns.blueComponent); a = Double(ns.alphaComponent)
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

enum BadgeShape: String, Codable, CaseIterable, Identifiable {
    case circle, pill, rounded, square
    var id: String { rawValue }
    var label: String { ["circle": "Circle", "pill": "Pill", "rounded": "Rounded", "square": "Square"][rawValue]! }
}

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct Look: Codable, Equatable {
    var background = RGBA(0.13, 0.11, 0.20, 1)
    var accent = RGBA(0.64, 0.47, 1.0)
    var text = RGBA(0.95, 0.95, 0.98)
    var opacity = 1.0           // whole widget, 0.3–1
    var badgeShape: BadgeShape = .circle
    var badgeSize = 64.0        // collapsed widget size
    var cornerRadius = 18.0     // expanded panel corners, 0–60
    var panelWidth = 360.0
    var panelHeight = 500.0
    var fontSize = 13.0
    var mode: ColorMode = .auto
    var alwaysOnTop = true

    static let presets: [(String, RGBA, RGBA, RGBA)] = [
        ("Purple night", RGBA(0.13, 0.11, 0.20, 1), RGBA(0.64, 0.47, 1.0), RGBA(0.95, 0.95, 0.98)),
        ("Paper", RGBA(0.98, 0.97, 0.94, 1), RGBA(0.85, 0.35, 0.20), RGBA(0.13, 0.12, 0.11)),
        ("Ocean", RGBA(0.05, 0.16, 0.24, 1), RGBA(0.20, 0.80, 0.85), RGBA(0.90, 0.97, 1.0)),
        ("Mono", RGBA(0.10, 0.10, 0.10, 1), RGBA(0.85, 0.85, 0.85), RGBA(0.96, 0.96, 0.96)),
        ("Mint", RGBA(0.92, 0.98, 0.95, 1), RGBA(0.10, 0.60, 0.40), RGBA(0.06, 0.20, 0.14)),
    ]
}

// MARK: - News

enum NewsTab: String, Codable, CaseIterable, Identifiable {
    case tech, politics, economy
    var id: String { rawValue }
    var label: String { ["tech": "Tech", "politics": "Politics", "economy": "Economy"][rawValue]! }
}

/// A feed is either fixed to one tab, or "auto" (sorted headline by headline using keywords).
enum FeedCategory: String, Codable, CaseIterable, Identifiable {
    case tech, politics, economy, auto
    var id: String { rawValue }
    var label: String { ["tech": "Tech", "politics": "Politics", "economy": "Economy", "auto": "Auto (keywords)"][rawValue]! }
    var tab: NewsTab? { NewsTab(rawValue: rawValue) }
}

struct NewsFeed: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var category: FeedCategory
    var enabled = true
}

struct NewsSettings: Codable, Equatable {
    var feeds: [NewsFeed] = NewsSettings.defaultFeeds
    var keywords: [String: [String]] = NewsSettings.defaultKeywords   // key = NewsTab.rawValue
    var refreshMinutes = 15
    var maxPerTab = 40

    static let defaultFeeds: [NewsFeed] = [
        NewsFeed(name: "The Verge", url: "https://www.theverge.com/rss/index.xml", category: .tech),
        NewsFeed(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", category: .tech),
        NewsFeed(name: "TechCrunch", url: "https://techcrunch.com/feed/", category: .tech),
        NewsFeed(name: "BBC Technology", url: "https://feeds.bbci.co.uk/news/technology/rss.xml", category: .tech),
        NewsFeed(name: "NYT Technology", url: "https://rss.nytimes.com/services/xml/rss/nyt/Technology.xml", category: .tech),
        NewsFeed(name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml", category: .politics),
        NewsFeed(name: "NYT Politics", url: "https://rss.nytimes.com/services/xml/rss/nyt/Politics.xml", category: .politics),
        NewsFeed(name: "Politico", url: "https://rss.politico.com/politics-news.xml", category: .politics),
        NewsFeed(name: "BBC Business", url: "https://feeds.bbci.co.uk/news/business/rss.xml", category: .economy),
        NewsFeed(name: "NYT Business", url: "https://rss.nytimes.com/services/xml/rss/nyt/Business.xml", category: .economy),
        NewsFeed(name: "CNBC", url: "https://www.cnbc.com/id/100003114/device/rss/rss.html", category: .economy),
        NewsFeed(name: "CNBC Finance", url: "https://www.cnbc.com/id/10000664/device/rss/rss.html", category: .economy),
        NewsFeed(name: "SCMP Business", url: "https://www.scmp.com/rss/92/feed/", category: .economy),
        NewsFeed(name: "RTHK Finance", url: "https://rthk.hk/rthk/news/rss/e_expressnews_efinance.xml", category: .economy),
        NewsFeed(name: "RTHK 財經", url: "https://rthk.hk/rthk/news/rss/c_expressnews_cfinance.xml", category: .economy),
        NewsFeed(name: "RTHK Local", url: "https://rthk.hk/rthk/news/rss/e_expressnews_elocal.xml", category: .auto),
        NewsFeed(name: "RTHK 本地", url: "https://rthk.hk/rthk/news/rss/c_expressnews_clocal.xml", category: .auto),
        NewsFeed(name: "SCMP Hong Kong", url: "https://www.scmp.com/rss/2/feed/", category: .auto),
        NewsFeed(name: "HKFP", url: "https://hongkongfp.com/feed/", category: .auto),
    ]

    static let defaultKeywords: [String: [String]] = [
        "tech": ["AI", "artificial intelligence", "chip", "chips", "semiconductor", "tech", "technology", "software",
                 "app", "Apple", "Google", "Microsoft", "Meta", "OpenAI", "Anthropic", "Nvidia", "smartphone",
                 "cyber", "hacker", "robot", "startup", "internet", "5G", "electric vehicle", "EV", "data centre",
                 "科技", "人工智能", "晶片", "半導體", "數碼", "網絡", "創科"],
        "politics": ["government", "election", "minister", "president", "parliament", "Legco", "legislative",
                     "policy", "Beijing", "Washington", "sanctions", "war", "military", "diplomat", "protest",
                     "court", "national security", "chief executive", "Trump", "Xi", "lawmaker", "lawmakers", "police",
                     "officials", "authorities", "watchdog", "bill", "law", "judge", "trial", "ICAC", "John Lee",
                     "secretary", "department", "council", "Legislative Council", "district council", "consulate",
                     "政府", "立法會", "選舉", "特首", "國安", "政策", "外交", "議員", "警方", "局長", "司長",
                     "法院", "法庭", "廉署", "官員", "當局", "署長", "區議會", "李家超"],
        "economy": ["economy", "economic", "market", "markets", "stocks", "shares", "Hang Seng", "inflation",
                    "interest rate", "rates", "GDP", "trade", "tariff", "tariffs", "bank", "HKMA", "Fed", "property",
                    "housing", "jobs", "unemployment", "budget", "tax", "earnings", "IPO", "currency", "yuan", "dollar",
                    "經濟", "股市", "恒指", "利率", "通脹", "樓市", "銀行", "關稅", "貿易", "上市", "財政"],
    ]
}

// MARK: - Calendar reminders

enum CalendarSource: String, Codable, CaseIterable, Identifiable {
    case system, ics
    var id: String { rawValue }
    var label: String { self == .system ? "macOS Calendar (add Google in System Settings)" : "Google secret iCal address" }
}

struct ReminderSettings: Codable, Equatable {
    var enabled = true
    var leadMinutes = 10
    var perCalendar: [String: Int] = [:]   // calendar name → minutes; overrides leadMinutes
    var includeAllDay = false
    var source: CalendarSource = .system
    var icsURL = ""
    var hiddenCalendars: [String] = []      // calendars to ignore
    var snoozeMinutes = 5
    var sound = true
}

// MARK: - Hour Map

struct HourRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var match: String      // a calendar name, or a word in the event title
    var project: String
}

struct HourSettings: Codable, Equatable {
    var projects: [String] = ["Study", "Work", "Personal"]
    var colors: [String: RGBA] = [:]   // project → colour (unset = picked from the palette)
    var rules: [HourRule] = []
    var autoLogCalendar = true   // count finished calendar events that match a rule

    static let palette: [RGBA] = [RGBA(0.64, 0.47, 1.0), RGBA(0.20, 0.75, 0.85), RGBA(0.98, 0.62, 0.25),
                                  RGBA(0.35, 0.80, 0.45), RGBA(0.95, 0.40, 0.55), RGBA(0.95, 0.85, 0.30),
                                  RGBA(0.45, 0.55, 0.95), RGBA(0.70, 0.70, 0.70)]
    func color(_ project: String) -> RGBA {
        if let c = colors[project] { return c }
        let i = projects.firstIndex(of: project) ?? project.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[i % Self.palette.count]
    }
}

struct Session: Codable, Identifiable, Hashable {
    var id = UUID()
    var project: String
    var start: Date
    var end: Date
    var hours: Double { end.timeIntervalSince(start) / 3600 }
}

struct RunningTimer: Codable, Equatable {
    var project: String
    var start: Date
}

// MARK: - Vault and general

struct VaultItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var value: String
}

struct GeneralSettings: Codable, Equatable {
    var expanded = true
    var originX: Double? = nil       // top-left corner of the widget on screen
    var originTop: Double? = nil
    var tab = "news"
    var hotkeys = true
}

struct Settings: Codable, Equatable {
    var look = Look()
    var news = NewsSettings()
    var reminders = ReminderSettings()
    var hours = HourSettings()
    var general = GeneralSettings()
}

struct HoursFile: Codable {
    var sessions: [Session] = []
    var running: RunningTimer? = nil
}

// MARK: - Loading with defaults

/// Decodes `data` on top of `fallback`: any field missing from the file keeps its default,
/// so adding a setting in a later version never wipes a user's saved settings.
func decodeMerged<T: Codable>(_ fallback: T, from data: Data) -> T {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    guard let base = try? JSONSerialization.jsonObject(with: enc.encode(fallback)),
          let saved = try? JSONSerialization.jsonObject(with: data) else { return fallback }
    func merge(_ a: Any, _ b: Any) -> Any {
        guard let da = a as? [String: Any], let db = b as? [String: Any] else { return b }
        var out = da
        for (k, v) in db { out[k] = out[k].map { merge($0, v) } ?? v }
        return out
    }
    guard let merged = try? JSONSerialization.data(withJSONObject: merge(base, saved)),
          let value = try? dec.decode(T.self, from: merged) else { return fallback }
    return value
}
