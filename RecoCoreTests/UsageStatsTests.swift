import Foundation
import XCTest

@testable import RecoCore

final class UsageStatsTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testRecordAggregatesByLocalDay() {
        var stats = UsageStats()
        stats.record(words: 5, at: date(2026, 11, 10, hour: 1), calendar: calendar)
        stats.record(words: 7, at: date(2026, 11, 10, hour: 23), calendar: calendar)
        stats.record(words: 3, at: date(2026, 11, 8), calendar: calendar)

        XCTAssertEqual(
            stats.days,
            [
                UsageDay(date: "2026-11-08", transcriptions: 1, words: 3),
                UsageDay(date: "2026-11-10", transcriptions: 2, words: 12),
            ])
        XCTAssertEqual(stats.transcriptions, 3)
        XCTAssertEqual(stats.words, 15)
        XCTAssertEqual(stats.firstDate, "2026-11-08")
    }

    func testRecentDaysFillsEmptyDaysOldestFirst() {
        var stats = UsageStats()
        stats.record(words: 4, at: date(2026, 11, 10), calendar: calendar)
        stats.record(words: 9, at: date(2026, 10, 1), calendar: calendar)

        let days = stats.recentDays(3, endingAt: date(2026, 11, 11), calendar: calendar)

        XCTAssertEqual(days.map(\.date), ["2026-11-09", "2026-11-10", "2026-11-11"])
        XCTAssertEqual(days.map(\.words), [0, 4, 0])
        XCTAssertEqual(stats.recentDays(0, calendar: calendar), [])
    }

    func testRecentDaysCrossesMonthAndDaylightSavingBoundaries() {
        let days = UsageStats().recentDays(3, endingAt: date(2026, 11, 2), calendar: calendar)
        XCTAssertEqual(days.map(\.date), ["2026-10-31", "2026-11-01", "2026-11-02"])
    }

    func testWordCountSplitsOnAnyWhitespace() {
        XCTAssertEqual(UsageStats.wordCount("  Hello,  world.\nNew line\there "), 5)
        XCTAssertEqual(UsageStats.wordCount(""), 0)
    }

    func testDayKeyRoundTrips() {
        let key = UsageStats.dayKey(for: date(2026, 3, 7), calendar: calendar)
        XCTAssertEqual(key, "2026-03-07")
        XCTAssertEqual(UsageStats.date(forDayKey: key, calendar: calendar), date(2026, 3, 7, hour: 0))
        XCTAssertNil(UsageStats.date(forDayKey: "nope", calendar: calendar))
    }

    func testStoreRoundTripsAndTreatsMissingFileAsEmpty() throws {
        let store = UsageStatsStore(fileURL: temporaryDirectory.appendingPathComponent("reco/stats.json"))
        XCTAssertEqual(try store.load(), UsageStats())

        var stats = UsageStats()
        stats.record(words: 2, at: date(2026, 11, 12), calendar: calendar)
        try store.save(stats)

        XCTAssertEqual(try store.load(), stats)
    }

    func testStoreReportsUnreadableFile() throws {
        let url = temporaryDirectory.appendingPathComponent("stats.json")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        XCTAssertThrowsError(try UsageStatsStore(fileURL: url).load())
    }

    func testDefaultPathHonorsAbsoluteXDGDataHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            UsageStatsStore.defaultFileURL(environment: ["XDG_DATA_HOME": "/tmp/data"], homeDirectory: home).path,
            "/tmp/data/reco/stats.json")
        XCTAssertEqual(
            UsageStatsStore.defaultFileURL(environment: ["XDG_DATA_HOME": "relative"], homeDirectory: home).path,
            "/Users/example/.local/share/reco/stats.json")
    }
}
