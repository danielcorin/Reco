import Charts
import RecoCore
import SwiftUI

/// Lifetime totals plus a per-day bar chart for one metric at a time. The two
/// metrics have different scales, so they never share an axis.
struct UsageStatsSection: View {
    enum Metric: String, CaseIterable, Identifiable {
        case words = "Words"
        case transcriptions = "Transcriptions"

        var id: Self { self }

        func value(of day: UsageDay) -> Int {
            switch self {
            case .words: day.words
            case .transcriptions: day.transcriptions
            }
        }

        func label(for count: Int) -> String {
            switch self {
            case .words: count == 1 ? "word" : "words"
            case .transcriptions: count == 1 ? "transcription" : "transcriptions"
            }
        }
    }

    struct Point: Identifiable {
        let date: Date
        let day: UsageDay
        var id: Date { date }
    }

    static let dayCount = 30

    let stats: UsageStats
    @State private var metric: Metric = .words
    @State private var selectedDate: Date?

    var body: some View {
        if stats.transcriptions == 0 {
            Text("Totals and a daily chart appear after your first transcription.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            totalRow("Transcriptions", stats.transcriptions)
            totalRow("Words transcribed", stats.words)

            Picker("Chart", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 6) {
                caption
                chart
            }
        }
    }

    private func totalRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value, format: .number)
                .monospacedDigit()
        }
    }

    private var points: [Point] {
        stats.recentDays(Self.dayCount).compactMap { day in
            UsageStats.date(forDayKey: day.date).map { Point(date: $0, day: day) }
        }
    }

    private var selectedPoint: Point? {
        guard let selectedDate else { return nil }
        let calendar = Calendar.current
        return points.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    /// One fixed-height line that names the hovered day, so hovering never
    /// moves the layout.
    private var caption: some View {
        Group {
            if let point = selectedPoint {
                let value = metric.value(of: point.day)
                Text(
                    "\(point.date.formatted(.dateTime.month(.abbreviated).day())) · \(value.formatted(.number)) \(metric.label(for: value))"
                )
            } else {
                Text("Last \(Self.dayCount) days")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var chart: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Day", point.date, unit: .day),
                y: .value(metric.rawValue, metric.value(of: point.day))
            )
            .foregroundStyle(Color.accentColor)
            .opacity(selectedPoint == nil || selectedPoint?.date == point.date ? 1 : 0.4)
            .cornerRadius(2)
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.system(size: 9))
            }
        }
        .frame(height: 72)
        .accessibilityLabel("\(metric.rawValue) per day, last \(Self.dayCount) days")
    }
}
