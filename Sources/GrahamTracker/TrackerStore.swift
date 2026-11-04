import AppKit
import CoreGraphics
import Foundation

struct Session: Codable, Identifiable, Hashable {
    var id: UUID
    var start: Date
    var end: Date
}

struct ActiveSession: Codable {
    var start: Date
    var heartbeat: Date
}

private struct StoreFile: Codable {
    var sessions: [Session]
    var active: ActiveSession?
}

enum StopReason {
    case manual, idle, sleep, quit, recovered
}

@MainActor
final class TrackerStore: ObservableObject {
    static let minimumSessionLength: TimeInterval = 5
    static let idleThreshold: TimeInterval = 5 * 60
    static let heartbeatInterval: TimeInterval = 30
    /// Stable table-row id for the ongoing session.
    static let activeRowID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Completed sessions, newest first.
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var activeStart: Date?
    @Published private(set) var lastAutoStop: (date: Date, reason: StopReason)?
    private(set) var loadError: String?

    var isRunning: Bool { activeStart != nil }
    var onTick: (() -> Void)?

    let dataDirectory: URL
    private let fileURL: URL
    private var timer: Timer?
    private var lastTick = Date()
    private var lastSave = Date.distantPast

    init() {
        if let override = ProcessInfo.processInfo.environment["GRAHAMTRACKER_DATA_DIR"] {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GrahamTracker", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        fileURL = dataDirectory.appendingPathComponent("sessions.json")
        load()
        startTimer()
        observeSleep()
    }

    // MARK: - Tracking

    func toggle() {
        if isRunning { stop(reason: .manual) } else { start() }
    }

    func start() {
        guard !isRunning else { return }
        activeStart = Self.wholeSecond(Date())
        lastAutoStop = nil
        save()
    }

    func stop(at date: Date = Date(), reason: StopReason) {
        guard let start = activeStart else { return }
        let end = max(Self.wholeSecond(date), start)
        activeStart = nil
        if end.timeIntervalSince(start) >= Self.minimumSessionLength {
            insert(Session(id: UUID(), start: start, end: end))
        }
        lastAutoStop = (reason == .manual || reason == .quit) ? nil : (end, reason)
        save()
    }

    private func tick() {
        let now = Date()
        defer {
            lastTick = now
            onTick?()
        }
        guard isRunning else { return }

        // The timer doesn't fire while the Mac sleeps; a large gap means we missed the sleep notification.
        if now.timeIntervalSince(lastTick) > 30 {
            stop(at: lastTick, reason: .sleep)
        } else if Self.secondsSinceLastInput() >= Self.idleThreshold {
            stop(at: now, reason: .idle)
        } else if now.timeIntervalSince(lastSave) >= Self.heartbeatInterval {
            save()
        }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observeSleep() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: .sleep) }
        }
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: - Editing

    func session(_ id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    func setActiveStart(_ date: Date) {
        guard isRunning else { return }
        activeStart = min(Self.wholeSecond(date), Self.wholeSecond(Date()))
        save()
    }

    @discardableResult
    func updateSession(id: UUID, start: Date, end: Date) -> Bool {
        guard start < end, let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        sessions[index].start = Self.wholeSecond(start)
        sessions[index].end = Self.wholeSecond(end)
        sessions.sort { $0.start > $1.start }
        save()
        return true
    }

    @discardableResult
    func addSession(start: Date, end: Date) -> UUID {
        let session = Session(id: UUID(), start: Self.wholeSecond(start), end: Self.wholeSecond(end))
        insert(session)
        save()
        return session.id
    }

    /// Deletes completed sessions; including `activeRowID` discards the ongoing session without saving it.
    func delete(_ ids: Set<UUID>) {
        if ids.contains(Self.activeRowID) { activeStart = nil }
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    private func insert(_ session: Session) {
        sessions.append(session)
        sessions.sort { $0.start > $1.start }
    }

    // MARK: - Aggregation

    private func spans(now: Date) -> [(start: Date, end: Date)] {
        var result = sessions.map { ($0.start, $0.end) }
        if let activeStart { result.append((activeStart, max(now, activeStart))) }
        return result
    }

    func trackedTime(in interval: DateInterval, now: Date = Date()) -> TimeInterval {
        spans(now: now).reduce(0) { total, span in
            total + max(0, min(span.end, interval.end).timeIntervalSince(max(span.start, interval.start)))
        }
    }

    func sessionCount(in interval: DateInterval, now: Date = Date()) -> Int {
        spans(now: now).filter { $0.end > interval.start && $0.start < interval.end }.count
    }

    func workedDays(in interval: DateInterval, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        var days = Set<Date>()
        for span in spans(now: now) where span.end > interval.start && span.start < interval.end {
            let last = min(span.end, interval.end)
            var day = calendar.startOfDay(for: max(span.start, interval.start))
            while day < last {
                days.insert(day)
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        return days.count
    }

    // MARK: - Persistence

    /// Saves without stopping, so a relaunch within the idle threshold picks the running session back up.
    func saveForRelaunch() {
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try Self.decoder.decode(StoreFile.self, from: data)
            sessions = file.sessions.sorted { $0.start > $1.start }
            try? data.write(to: dataDirectory.appendingPathComponent("sessions.backup.json"), options: .atomic)

            if let active = file.active {
                if Date().timeIntervalSince(active.heartbeat) < Self.idleThreshold {
                    activeStart = active.start
                } else {
                    activeStart = active.start
                    stop(at: active.heartbeat, reason: .recovered)
                }
            }
        } catch {
            // Never overwrite a file we couldn't parse (e.g. a bad hand edit); set it aside instead.
            let stamp = Int(Date().timeIntervalSince1970)
            let brokenURL = dataDirectory.appendingPathComponent("sessions.broken-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: brokenURL)
            loadError = "Couldn't read sessions.json (\(error.localizedDescription)). "
                + "It was moved to \(brokenURL.lastPathComponent) in the data folder; "
                + "fix it and rename it back to sessions.json while the app is quit."
        }
    }

    private func save() {
        let now = Date()
        let file = StoreFile(
            sessions: sessions,
            active: activeStart.map { ActiveSession(start: $0, heartbeat: Self.wholeSecond(now)) }
        )
        do {
            try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
            lastSave = now
        } catch {
            NSLog("GrahamTracker: failed to save sessions: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        nonisolated(unsafe) let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        nonisolated(unsafe) let formatter = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
            }
            return date
        }
        return decoder
    }()
}
