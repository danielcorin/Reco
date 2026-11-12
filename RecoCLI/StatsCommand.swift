import Foundation
import RecoCore

private struct StatsOutput: Encodable {
    let transcriptions: Int
    let words: Int
    let since: String?
    let days: [UsageDay]
}

/// Reads the stats file directly, so this works whether or not Reco is running.
func runStatsCommand(arguments: [String], json: Bool) throws {
    var dayCount = 30
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "--days":
            guard let value = remaining.popFirst(), let count = Int(value), (0...3650).contains(count)
            else {
                throw UsageError("stats --days requires a number from 0 to 3650")
            }
            dayCount = count
        default:
            throw UsageError("unknown stats option '\(argument)'")
        }
    }

    let stats = try UsageStatsStore().load()
    let days = stats.recentDays(dayCount)
    if json {
        try writeJSON(
            StatsOutput(
                transcriptions: stats.transcriptions,
                words: stats.words,
                since: stats.firstDate,
                days: days
            ))
        return
    }

    let number = IntegerFormatStyle<Int>.number
    let since = stats.firstDate.map { "  (since \($0))" } ?? ""
    print("Transcriptions  \(stats.transcriptions.formatted(number))\(since)")
    print("Words           \(stats.words.formatted(number))")
    guard !days.isEmpty else { return }

    let transcriptionWidth = max(
        "Transcriptions".count, days.map { $0.transcriptions.formatted(number).count }.max() ?? 0)
    print("")
    print("Date        \(pad("Transcriptions", transcriptionWidth))  Words")
    for day in days {
        print(
            "\(day.date)  \(pad(day.transcriptions.formatted(number), transcriptionWidth))  \(day.words.formatted(number))"
        )
    }
}

private func pad(_ text: String, _ width: Int) -> String {
    text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
}
