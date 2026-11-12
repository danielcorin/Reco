import Charts
import RecoCore
import SwiftUI

/// Lifetime totals plus a per-day bar chart for one metric at a time. The two
/// metrics have different scales, so they never share an axis; the totals
/// double as the control that picks which one the chart shows.
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
                .font(RecoStyle.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                StatTile(
                    value: stats.words,
                    label: Metric.words.label(for: stats.words),
                    isSelected: metric == .words
                ) { metric = .words }

                StatTile(
                    value: stats.transcriptions,
                    label: Metric.transcriptions.label(for: stats.transcriptions),
                    isSelected: metric == .transcriptions
                ) { metric = .transcriptions }
            }

            VStack(alignment: .leading, spacing: 6) {
                caption
                chart
            }
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
        .font(RecoStyle.Font.caption)
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
                    .font(RecoStyle.Font.axis)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(RecoStyle.Font.axis)
            }
        }
        .frame(height: 72)
        .accessibilityLabel("\(metric.rawValue) per day, last \(Self.dayCount) days")
    }
}

/// A lifetime total that also selects the chart's metric.
private struct StatTile: View {
    let value: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value, format: .number)
                    .font(RecoStyle.Font.statValue)
                    .monospacedDigit()
                Text(label)
                    .font(RecoStyle.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background, in: RoundedRectangle(cornerRadius: RecoStyle.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: RecoStyle.cornerRadius)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: RecoStyle.cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Shows \(label) per day in the chart")
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        return Color.secondary.opacity(isHovered ? 0.12 : 0.07)
    }
}
