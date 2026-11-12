import Foundation

/// Transcription counts for one local calendar day.
public struct UsageDay: Codable, Equatable, Sendable {
    /// Local calendar day, formatted `yyyy-MM-dd`.
    public var date: String
    public var transcriptions: Int
    public var words: Int

    public init(date: String, transcriptions: Int = 0, words: Int = 0) {
        self.date = date
        self.transcriptions = transcriptions
        self.words = words
    }
}

/// Per-day usage totals. Only counts are kept, never transcript text.
public struct UsageStats: Codable, Equatable, Sendable {
    /// Days with at least one transcription, oldest first.
    public private(set) var days: [UsageDay]

    public init(days: [UsageDay] = []) {
        self.days = days.sorted { $0.date < $1.date }
    }

    public var transcriptions: Int { days.reduce(0) { $0 + $1.transcriptions } }
    public var words: Int { days.reduce(0) { $0 + $1.words } }
    public var firstDate: String? { days.first?.date }

    public mutating func record(words: Int, at date: Date, calendar: Calendar = .current) {
        let key = Self.dayKey(for: date, calendar: calendar)
        if let index = days.firstIndex(where: { $0.date == key }) {
            days[index].transcriptions += 1
            days[index].words += words
        } else {
            days.append(UsageDay(date: key, transcriptions: 1, words: words))
            days.sort { $0.date < $1.date }
        }
    }

    /// The last `count` days ending on `date`, oldest first, with empty days filled in.
    public func recentDays(
        _ count: Int,
        endingAt date: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsageDay] {
        guard count > 0 else { return [] }
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let end = calendar.startOfDay(for: date)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let key = Self.dayKey(for: day, calendar: calendar)
            return byDate[key] ?? UsageDay(date: key)
        }
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of the local day a `yyyy-MM-dd` key names.
    public static func date(forDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Reads and writes `$XDG_DATA_HOME/reco/stats.json`. The app is the only writer;
/// the CLI reads the file directly so stats work while Reco is not running.
public struct UsageStatsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let baseDirectory: URL
        if let configured = environment["XDG_DATA_HOME"],
            !configured.isEmpty,
            configured.hasPrefix("/")
        {
            baseDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            baseDirectory =
                homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return
            baseDirectory
            .appendingPathComponent("reco", isDirectory: true)
            .appendingPathComponent("stats.json")
    }

    /// A missing file means no transcriptions yet.
    public func load() throws -> UsageStats {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return UsageStats() }
        do {
            return try JSONDecoder().decode(UsageStats.self, from: Data(contentsOf: fileURL))
        } catch {
            throw UsageStatsError.unreadable(fileURL.path, error.localizedDescription)
        }
    }

    public func save(_ stats: UsageStats) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stats).write(to: fileURL, options: [.atomic])
    }
}

public enum UsageStatsError: LocalizedError, Equatable {
    case unreadable(String, String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            "Couldn’t read usage stats at \(path): \(reason)"
        }
    }
}
