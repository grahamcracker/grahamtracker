import Foundation

enum Granularity: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"

    var id: Self { self }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// Size of each bar in the chart.
    var bucketComponent: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        }
    }
}

struct Period: Equatable {
    var granularity: Granularity
    var anchor: Date

    var interval: DateInterval {
        Calendar.current.dateInterval(of: granularity.component, for: anchor)!
    }

    var containsNow: Bool { interval.contains(Date()) }

    func shifted(by count: Int) -> Period {
        Period(
            granularity: granularity,
            anchor: Calendar.current.date(byAdding: granularity.component, value: count, to: anchor)!
        )
    }

    var title: String {
        let interval = interval
        switch granularity {
        case .day:
            return interval.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        case .week:
            let formatter = DateIntervalFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: interval.start, to: interval.end.addingTimeInterval(-1))
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        }
    }

    var buckets: [DateInterval] {
        let calendar = Calendar.current
        let interval = interval
        var result: [DateInterval] = []
        var cursor = interval.start
        while cursor < interval.end {
            let next = calendar.date(byAdding: granularity.bucketComponent, value: 1, to: cursor)!
            result.append(DateInterval(start: cursor, end: min(next, interval.end)))
            cursor = next
        }
        return result
    }
}

func formatHMS(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}
