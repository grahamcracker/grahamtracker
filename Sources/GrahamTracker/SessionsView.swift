import SwiftUI

struct SessionRow: Identifiable {
    let id: UUID
    let start: Date
    /// nil while the session is still running.
    let end: Date?
}

struct SessionsView: View {
    @ObservedObject var store: TrackerStore
    let period: Period

    @State private var selection = Set<UUID>()
    @State private var pendingDelete = Set<UUID>()
    @State private var showDeleteConfirmation = false

    private var rows: [SessionRow] {
        let interval = period.interval
        var rows: [SessionRow] = []
        if let start = store.activeStart, start < interval.end, Date() > interval.start {
            rows.append(SessionRow(id: TrackerStore.activeRowID, start: start, end: nil))
        }
        rows += store.sessions
            .filter { $0.end > interval.start && $0.start < interval.end }
            .map { SessionRow(id: $0.id, start: $0.start, end: $0.end) }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Date") { row in dateCell(row) }
                    .width(min: 150, ideal: 170)
                TableColumn("Start") { row in startCell(row) }
                    .width(min: 110, ideal: 120)
                TableColumn("End") { row in endCell(row) }
                    .width(min: 140, ideal: 150)
                TableColumn("Duration") { row in durationCell(row) }
                    .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button(deleteLabel(for: ids), role: .destructive) { confirmDelete(ids) }
                    .disabled(ids.isEmpty)
            }
            .onDeleteCommand { confirmDelete(selection) }

            Divider()
            footer(rowCount: rows.count)
        }
        .confirmationDialog(
            "\(deleteLabel(for: pendingDelete))?",
            isPresented: $showDeleteConfirmation
        ) {
            Button(deleteLabel(for: pendingDelete), role: .destructive) {
                store.delete(pendingDelete)
                selection.subtract(pendingDelete)
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Cells

    private func dateCell(_ row: SessionRow) -> some View {
        HStack(spacing: 6) {
            Text(row.start, format: .dateTime.weekday(.abbreviated))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            DatePicker("Date", selection: dateBinding(row), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
        }
    }

    private func startCell(_ row: SessionRow) -> some View {
        TimeField(date: startBinding(row))
    }

    @ViewBuilder
    private func endCell(_ row: SessionRow) -> some View {
        if let end = row.end {
            HStack(spacing: 4) {
                TimeField(date: endBinding(row))
                if !Calendar.current.isDate(end, inSameDayAs: row.start) {
                    Text("+1d").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Running", systemImage: "record.circle")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func durationCell(_ row: SessionRow) -> some View {
        if let end = row.end {
            Text(formatHMS(end.timeIntervalSince(row.start))).monospacedDigit()
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(formatHMS(context.date.timeIntervalSince(row.start))).monospacedDigit()
            }
        }
    }

    private func footer(rowCount: Int) -> some View {
        HStack {
            Button { addSession() } label: { Label("Add Session", systemImage: "plus") }
            Button { confirmDelete(selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(rowCount) session\(rowCount == 1 ? "" : "s") · Total \(formatHMS(store.trackedTime(in: period.interval, now: context.date)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    // MARK: - Bindings

    /// Changing the date moves the whole session to that day, keeping its times.
    private func dateBinding(_ row: SessionRow) -> Binding<Date> {
        Binding(
            get: { currentStart(row) },
            set: { newDay in
                let calendar = Calendar.current
                let start = currentStart(row)
                let days = calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: newDay)
                ).day ?? 0
                guard days != 0 else { return }
                let shift = { (date: Date) in calendar.date(byAdding: .day, value: days, to: date)! }
                if let end = currentEnd(row) {
                    store.updateSession(id: row.id, start: shift(start), end: shift(end))
                } else {
                    store.setActiveStart(shift(start))
                }
            }
        )
    }

    private func startBinding(_ row: SessionRow) -> Binding<Date> {
        Binding(
            get: { currentStart(row) },
            set: { newTime in
                let newStart = combine(day: currentStart(row), time: newTime)
                if let end = currentEnd(row) {
                    store.updateSession(id: row.id, start: newStart, end: end)
                } else {
                    store.setActiveStart(newStart)
                }
            }
        )
    }

    /// End times are interpreted relative to the start's day, rolling to the next day if earlier than the start.
    private func endBinding(_ row: SessionRow) -> Binding<Date> {
        Binding(
            get: { currentEnd(row) ?? currentStart(row) },
            set: { newTime in
                let start = currentStart(row)
                var newEnd = combine(day: start, time: newTime)
                if newEnd <= start {
                    newEnd = Calendar.current.date(byAdding: .day, value: 1, to: newEnd)!
                }
                store.updateSession(id: row.id, start: start, end: newEnd)
            }
        )
    }

    /// Read from the store rather than the row so edits made since the last render are respected.
    private func currentStart(_ row: SessionRow) -> Date {
        row.end == nil ? (store.activeStart ?? row.start) : (store.session(row.id)?.start ?? row.start)
    }

    private func currentEnd(_ row: SessionRow) -> Date? {
        row.end == nil ? nil : (store.session(row.id)?.end ?? row.end)
    }

    private func combine(day: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .second], from: time)
        return calendar.date(
            bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0, of: day
        ) ?? day
    }

    // MARK: - Actions

    private func addSession() {
        let now = Date()
        let start: Date
        if period.containsNow {
            start = max(now.addingTimeInterval(-3600), Calendar.current.startOfDay(for: now))
        } else {
            start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: period.interval.start)!
        }
        let end = period.containsNow ? now : start.addingTimeInterval(3600)
        selection = [store.addSession(start: start, end: max(end, start.addingTimeInterval(60)))]
    }

    private func confirmDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        showDeleteConfirmation = true
    }

    private func deleteLabel(for ids: Set<UUID>) -> String {
        if ids == [TrackerStore.activeRowID] { return "Discard Running Session" }
        return ids.count == 1 ? "Delete Session" : "Delete \(ids.count) Sessions"
    }
}
