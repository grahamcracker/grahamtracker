import Charts
import SwiftUI

private struct Bucket: Identifiable {
    let start: Date
    let value: Double
    var id: Date { start }
}

struct ChartsView: View {
    @ObservedObject var store: TrackerStore
    let period: Period

    var body: some View {
        let live = store.isRunning && period.containsNow
        TimelineView(.periodic(from: .now, by: live ? 1 : 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let granularity = period.granularity
        let interval = period.interval
        let inMinutes = granularity == .day
        let unitName = inMinutes ? "Minutes" : "Hours"
        let buckets = period.buckets.map {
            Bucket(start: $0.start, value: store.trackedTime(in: $0, now: now) / (inMinutes ? 60 : 3600))
        }
        let total = store.trackedTime(in: interval, now: now)
        let days = store.workedDays(in: interval, now: now)

        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 40) {
                Stat(title: "Total", value: formatHMS(total))
                if granularity != .day {
                    Stat(title: "Days worked", value: "\(days)")
                    Stat(title: "Avg / worked day", value: days > 0 ? formatHMS(total / Double(days)) : "—")
                }
                Stat(title: "Sessions", value: "\(store.sessionCount(in: interval, now: now))")
            }

            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Time", bucket.start, unit: granularity.bucketComponent),
                    y: .value(unitName, bucket.value)
                )
                .foregroundStyle(Color.accentColor.gradient)
            }
            .chartXScale(domain: interval.start ... interval.end)
            .chartYAxisLabel(unitName)
            .chartXAxis {
                AxisMarks(values: .stride(by: granularity.bucketComponent, count: granularity == .day ? 3 : 1)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: granularity.axisLabelFormat, centered: granularity != .day)
                }
            }
        }
        .padding(20)
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
    }
}

private extension Granularity {
    var axisLabelFormat: Date.FormatStyle {
        switch self {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day()
        case .year: .dateTime.month(.abbreviated)
        }
    }
}
