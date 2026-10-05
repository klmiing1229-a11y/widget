// News.swift — fetches free RSS/Atom feeds and sorts headlines into Tech / Politics / Economy.
// No AI: a feed is either fixed to one tab, or each headline is scored against keyword lists
// the user can edit in Settings › News. A headline with no keyword hit from an "auto" feed is dropped.
import Foundation
import Combine

struct NewsItem: Identifiable, Hashable {
    var id: String { link }
    let title: String
    let link: String
    let source: String
    let date: Date?
    let tab: NewsTab
}

final class NewsService: ObservableObject {
    @Published var items: [NewsTab: [NewsItem]] = [:]
    @Published var lastUpdated: Date?
    @Published var failedFeeds: [String] = []
    @Published var loading = false

    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    init() {
        refresh()
        schedule(Store.shared.settings.news.refreshMinutes)
        Store.shared.$settings.map(\.news).removeDuplicates().dropFirst()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] s in self?.schedule(s.refreshMinutes); self?.refresh() }
            .store(in: &bag)
    }

    private func schedule(_ minutes: Int) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(max(5, minutes)) * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let s = Store.shared.settings.news
        let feeds = s.feeds.filter { $0.enabled }
        loading = true
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [NewsItem] = []
        var failed: [String] = []
        for feed in feeds {
            guard let url = URL(string: feed.url) else { failed.append("\(feed.name) (bad link)"); continue }
            group.enter()
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("Mozilla/5.0 (Macintosh) Deskmate/1.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, err in
                defer { group.leave() }
                let parsed = data.map { FeedParser.parse($0) } ?? []
                lock.lock(); defer { lock.unlock() }
                if parsed.isEmpty {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    let why = err.map { ($0 as NSError).localizedDescription } ?? (code != 200 ? "HTTP \(code)" : "no headlines in the feed")
                    failed.append("\(feed.name) (\(why))"); return
                }
                for p in parsed {
                    guard let tab = Classifier.tab(for: p.title, feed: feed.category, keywords: s.keywords) else { continue }
                    collected.append(NewsItem(title: p.title, link: p.link, source: feed.name, date: p.date, tab: tab))
                }
            }.resume()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            var out: [NewsTab: [NewsItem]] = [:]
            for tab in NewsTab.allCases {
                let sorted = collected.filter { $0.tab == tab }
                    .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                out[tab] = Array(Classifier.dedupe(sorted).prefix(s.maxPerTab))
            }
            self.items = out
            self.failedFeeds = failed.sorted()
            if !failed.isEmpty { FileHandle.standardError.write(("Deskmate: feeds failed: " + failed.sorted().joined(separator: "; ") + "\n").data(using: .utf8)!) }
            self.lastUpdated = Date()
            self.loading = false
        }
    }
}

// MARK: - Keyword classifier

enum Classifier {
    static func tab(for title: String, feed: FeedCategory, keywords: [String: [String]]) -> NewsTab? {
        if let fixed = feed.tab { return fixed }
        var best: (NewsTab, Int)? = nil
        for tab in NewsTab.allCases {
            let score = (keywords[tab.rawValue] ?? []).reduce(0) { $0 + (matches(title, $1) ? 1 : 0) }
            if score > 0, score > (best?.1 ?? 0) { best = (tab, score) }
        }
        return best?.0
    }

    /// English keywords match whole words, case-insensitive ("AI" won't match "said").
    /// Chinese keywords match anywhere in the headline.
    static func matches(_ text: String, _ keyword: String) -> Bool {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return false }
        if k.unicodeScalars.contains(where: { $0.value > 0x2E80 }) { return text.contains(k) }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: k) + "\\b"
        // Short all-capitals keywords (AI, EV, GDP) are case-sensitive so "ai" inside words never counts.
        let caseSensitive = k.count <= 3 && k == k.uppercased()
        let opts: String.CompareOptions = caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]
        return text.range(of: pattern, options: opts) != nil
    }

    /// Drops a headline when it shares 60%+ of its words with one already kept.
    static func dedupe(_ items: [NewsItem]) -> [NewsItem] {
        var kept: [NewsItem] = []
        var keptWords: [Set<String>] = []
        var links = Set<String>()
        for item in items {
            if links.contains(item.link) { continue }
            let words = Set(item.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
            let dup = keptWords.contains { other in
                let union = words.union(other).count
                return union > 0 && Double(words.intersection(other).count) / Double(union) >= 0.6
            }
            if dup { continue }
            kept.append(item); keptWords.append(words); links.insert(item.link)
        }
        return kept
    }
}

// MARK: - RSS / Atom parser

struct ParsedEntry { var title = ""; var link = ""; var date: Date? }

final class FeedParser: NSObject, XMLParserDelegate {
    private var entries: [ParsedEntry] = []
    private var current: ParsedEntry?
    private var text = ""
    private var dateText = ""

    static func parse(_ data: Data) -> [ParsedEntry] {
        let p = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.entries.filter { !$0.title.isEmpty && !$0.link.isEmpty }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let n = name.lowercased()
        if n == "item" || n == "entry" { current = ParsedEntry(); dateText = "" }
        if n == "link", current != nil, let href = attributes["href"] {
            let rel = attributes["rel"] ?? "alternate"
            if rel == "alternate" && (current?.link.isEmpty ?? true) { current?.link = href }
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "title": if current!.title.isEmpty { current!.title = FeedParser.clean(value) }
        case "link": if current!.link.isEmpty, !value.isEmpty { current!.link = value }
        case "pubdate", "published", "updated", "dc:date":
            if current!.date == nil { current!.date = FeedParser.date(value) }
        case "item", "entry": entries.append(current!); current = nil
        default: break
        }
        text = ""
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#8217;", "’"), ("&#8216;", "‘"),
                       ("&#8220;", "“"), ("&#8221;", "”"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let rfc: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                                               "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z"].map {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = $0; return f
    }
    private static let iso: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter()
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [a, b]
    }()

    static func date(_ s: String) -> Date? {
        for f in iso { if let d = f.date(from: s) { return d } }
        for f in rfc { if let d = f.date(from: s) { return d } }
        return nil
    }
}
