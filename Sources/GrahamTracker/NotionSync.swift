import Combine
import Foundation

struct NotionSettings: Codable {
    var enabled = false
    var token: String?
    var workspaceName: String?
    var pageTitle: String?
    var databaseID: String?
    var databaseURL: String?
}

/// Mirrors completed sessions into a Notion database: new sessions are added, edits update rows, deletes archive them.
@MainActor
final class NotionSync: ObservableObject {
    enum Status: Equatable {
        case off
        case needsSetup
        case waiting
        case syncing(done: Int, total: Int)
        case synced(Date)
        case failed(String)
    }

    @Published private(set) var settings: NotionSettings
    @Published private(set) var status: Status = .off

    var isReady: Bool { settings.enabled && settings.token != nil && settings.databaseID != nil }

    private struct SyncedRow: Codable {
        var pageID: String
        var start: Date
        var end: Date
    }

    private struct SyncState: Codable {
        var databaseID: String
        /// Keyed by session UUID string.
        var rows: [String: SyncedRow]
    }

    private static let retryDelay: TimeInterval = 5 * 60
    private static let requestSpacing: Duration = .milliseconds(340)

    private let store: TrackerStore
    /// Holds the key, so it's written with owner-only permissions.
    private let settingsURL: URL
    private let stateURL: URL
    private var changeSubscription: AnyCancellable?
    private var retryTimer: Timer?
    private var isSyncing = false
    private var syncAgain = false

    init(store: TrackerStore) {
        self.store = store
        settingsURL = store.dataDirectory.appendingPathComponent("notion-settings.json")
        stateURL = store.dataDirectory.appendingPathComponent("notion-sync.json")
        settings = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(NotionSettings.self, from: $0) }
            ?? NotionSettings()
        refreshIdleStatus()
        changeSubscription = store.$sessions
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        saveSettings()
        sync()
    }

    /// Checks the key with Notion and saves it if it works.
    func connect(token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = try await NotionClient(token: trimmed).workspaceName()
        settings.token = trimmed
        settings.workspaceName = workspace
        saveSettings()
        refreshIdleStatus()
    }

    func removeKey() {
        settings = NotionSettings(enabled: settings.enabled)
        saveSettings()
        refreshIdleStatus()
    }

    func pages() async throws -> [NotionPage] {
        guard let token = settings.token else { return [] }
        return try await NotionClient(token: token).searchPages()
    }

    func createDatabase(in page: NotionPage) async throws {
        guard let token = settings.token else { return }
        let database = try await NotionClient(token: token).createDatabase(inPage: page.id)
        settings.pageTitle = page.title
        settings.databaseID = database.id
        settings.databaseURL = database.url
        saveSettings()
        saveState(SyncState(databaseID: database.id, rows: [:]))
        sync()
    }

    /// Forgets the current database so a new one can be created. The old one stays in Notion.
    func changeDestination() {
        settings.pageTitle = nil
        settings.databaseID = nil
        settings.databaseURL = nil
        saveSettings()
        refreshIdleStatus()
    }

    // MARK: - Syncing

    func sync() {
        guard isReady else {
            refreshIdleStatus()
            return
        }
        if isSyncing {
            syncAgain = true
            return
        }
        isSyncing = true
        retryTimer?.invalidate()
        status = .syncing(done: 0, total: 0)
        Task {
            do {
                try await performSync()
                status = .synced(Date())
            } catch {
                status = .failed((error as? NotionError)?.message ?? error.localizedDescription)
                scheduleRetry()
            }
            isSyncing = false
            if syncAgain {
                syncAgain = false
                sync()
            }
        }
    }

    private func performSync() async throws {
        guard let token = settings.token, let databaseID = settings.databaseID else { return }
        let client = NotionClient(token: token)
        var state = loadState(databaseID: databaseID)
        if state.rows.isEmpty {
            // Picks up rows from an earlier sync if the local record of them was lost, avoiding duplicates.
            state.rows = try await existingRows(client, databaseID: databaseID)
            saveState(state)
        }

        let sessions = store.sessions
        let liveIDs = Set(sessions.map(\.id.uuidString))
        for (sessionID, row) in state.rows where !liveIDs.contains(sessionID) {
            do {
                try await client.archiveRow(row.pageID)
            } catch let error as NotionError where error.status == 404 || error.status == 400 {
                // Already deleted in Notion.
            }
            state.rows[sessionID] = nil
            saveState(state)
            try await Task.sleep(for: Self.requestSpacing)
        }

        let pending = sessions.filter { session in
            guard let row = state.rows[session.id.uuidString] else { return true }
            return row.start != session.start || row.end != session.end
        }
        for (index, session) in pending.enumerated() {
            status = .syncing(done: index, total: pending.count)
            let properties = NotionClient.rowProperties(for: session)
            var pageID = state.rows[session.id.uuidString]?.pageID
            if let existing = pageID {
                do {
                    try await client.updateRow(existing, properties: properties)
                } catch let error as NotionError
                    where error.status == 404 || (error.status == 400 && error.message.lowercased().contains("archived")) {
                    pageID = nil // Row was deleted in Notion; add it back.
                }
            }
            if pageID == nil {
                do {
                    pageID = try await client.createRow(database: databaseID, properties: properties)
                } catch let error as NotionError where error.status == 404 {
                    throw NotionError(
                        status: 404, code: error.code,
                        message: "Can't find the Work Sessions database in Notion. It may have been deleted or unshared. Choose a page in Settings to create a new one."
                    )
                }
            }
            state.rows[session.id.uuidString] = SyncedRow(pageID: pageID!, start: session.start, end: session.end)
            saveState(state)
            try await Task.sleep(for: Self.requestSpacing)
        }
    }

    private func existingRows(_ client: NotionClient, databaseID: String) async throws -> [String: SyncedRow] {
        var rows: [String: SyncedRow] = [:]
        for page in try await client.queryAllRows(database: databaseID) {
            guard let pageID = page["id"] as? String, let properties = page["properties"] as? [String: Any] else { continue }
            let sessionID = ((properties["Session ID"] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? [])
                .compactMap { $0["plain_text"] as? String }
                .joined()
            guard !sessionID.isEmpty else { continue }
            func date(_ name: String) -> Date {
                let value = ((properties[name] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String
                return value.flatMap(NotionClient.parseDate) ?? .distantPast
            }
            rows[sessionID] = SyncedRow(pageID: pageID, start: date("Start"), end: date("End"))
        }
        return rows
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: Self.retryDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func refreshIdleStatus() {
        guard !isSyncing else { return }
        if !settings.enabled {
            status = .off
        } else if !isReady {
            status = .needsSetup
        } else if status == .off || status == .needsSetup {
            status = .waiting
        }
    }

    var statusDescription: String {
        switch status {
        case .off: "Off"
        case .needsSetup: "Finish setup in Settings"
        case .waiting: "Waiting to sync"
        case .syncing(let done, let total): total > 0 ? "Syncing \(done + 1) of \(total)…" : "Syncing…"
        case .synced(let date): "Synced at \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): message
        }
    }

    // MARK: - Persistence

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        let temporary = settingsURL.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        if rename(temporary.path, settingsURL.path) != 0 {
            NSLog("GrahamTracker: failed to save Notion settings")
        }
    }

    private func loadState(databaseID: String) -> SyncState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data),
              state.databaseID == databaseID
        else { return SyncState(databaseID: databaseID, rows: [:]) }
        return state
    }

    private func saveState(_ state: SyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
