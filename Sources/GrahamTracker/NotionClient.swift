import Foundation

struct NotionError: LocalizedError {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? { message }
}

struct NotionPage: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Minimal Notion REST client for the calls GrahamTracker needs.
@MainActor
struct NotionClient {
    static let apiVersion = "2022-06-28"
    static let databaseTitle = "GrahamTracker Sessions"
    /// Earlier versions used this title; such databases are reused rather than duplicated.
    static let legacyDatabaseTitles = ["Work Sessions"]
    /// Overridable so tests can point at a local mock server.
    static let baseURL = URL(string: ProcessInfo.processInfo.environment["GRAHAMTRACKER_NOTION_API"] ?? "https://api.notion.com/v1/")!

    let token: String

    /// Validates the key and returns the name of the workspace it belongs to.
    func workspaceName() async throws -> String {
        let me = try await call("GET", "users/me")
        let bot = me["bot"] as? [String: Any]
        return bot?["workspace_name"] as? String ?? me["name"] as? String ?? "Notion"
    }

    /// Standalone pages the key can see (not rows inside databases).
    func searchPages() async throws -> [NotionPage] {
        var pages: [NotionPage] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": ["property": "object", "value": "page"], "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let response = try await call("POST", "search", body: body)
            for result in response["results"] as? [[String: Any]] ?? [] {
                guard let id = result["id"] as? String,
                      (result["parent"] as? [String: Any])?["type"] as? String != "database_id",
                      result["archived"] as? Bool != true, result["in_trash"] as? Bool != true
                else { continue }
                let properties = result["properties"] as? [String: [String: Any]] ?? [:]
                let titleProperty = properties.values.first { $0["type"] as? String == "title" }
                let title = (titleProperty?["title"] as? [[String: Any]] ?? [])
                    .compactMap { $0["plain_text"] as? String }
                    .joined()
                pages.append(NotionPage(id: id, title: title.isEmpty ? "Untitled" : title))
            }
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
        } while cursor != nil && pages.count < 500
        return pages.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Reuses a GrahamTracker database already on the page (adding any missing columns), or creates one.
    func installDatabase(inPage pageID: String) async throws -> (id: String, url: String?) {
        let response: [String: Any]
        if let existing = try await findDatabase(inPage: pageID) {
            response = try await call("PATCH", "databases/\(existing)", body: ["properties": Self.columns])
        } else {
            response = try await call("POST", "databases", body: [
                "parent": ["type": "page_id", "page_id": pageID],
                "title": [["type": "text", "text": ["content": Self.databaseTitle]]],
                "properties": Self.columns.merging(["Session": ["title": [String: Any]()]]) { $1 },
            ])
        }
        guard let id = response["id"] as? String else {
            throw NotionError(status: 0, code: "bad_response", message: "Notion didn't return the sessions database.")
        }
        return (id, response["url"] as? String)
    }

    /// Columns besides the title, which can't be re-declared on an existing database.
    private static let columns: [String: Any] = [
        "Start": ["date": [String: Any]()],
        "End": ["date": [String: Any]()],
        "Hours": ["number": ["format": "number"]],
        "Session ID": ["rich_text": [String: Any]()],
    ]

    private func findDatabase(inPage pageID: String) async throws -> String? {
        let titles = Set([Self.databaseTitle] + Self.legacyDatabaseTitles)
        var cursor: String?
        repeat {
            var path = "blocks/\(pageID)/children?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let response = try await call("GET", path)
            for block in response["results"] as? [[String: Any]] ?? [] {
                guard block["type"] as? String == "child_database",
                      block["archived"] as? Bool != true, block["in_trash"] as? Bool != true,
                      let title = (block["child_database"] as? [String: Any])?["title"] as? String,
                      titles.contains(title)
                else { continue }
                return block["id"] as? String
            }
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
        } while cursor != nil
        return nil
    }

    func queryAllRows(database id: String) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let response = try await call("POST", "databases/\(id)/query", body: body)
            rows += response["results"] as? [[String: Any]] ?? []
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
        } while cursor != nil
        return rows
    }

    func createRow(database id: String, properties: [String: Any]) async throws -> String {
        let response = try await call("POST", "pages", body: ["parent": ["database_id": id], "properties": properties])
        guard let pageID = response["id"] as? String else {
            throw NotionError(status: 0, code: "bad_response", message: "Notion didn't return the new row.")
        }
        return pageID
    }

    func updateRow(_ pageID: String, properties: [String: Any]) async throws {
        try await call("PATCH", "pages/\(pageID)", body: ["properties": properties])
    }

    func archiveRow(_ pageID: String) async throws {
        try await call("PATCH", "pages/\(pageID)", body: ["archived": true])
    }

    static func rowProperties(for session: Session) -> [String: Any] {
        let duration = session.end.timeIntervalSince(session.start)
        let title = "\(session.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(formatHMS(duration))"
        return [
            "Session": ["title": [["text": ["content": title]]]],
            "Start": ["date": ["start": isoFormatter.string(from: session.start)]],
            "End": ["date": ["start": isoFormatter.string(from: session.end)]],
            "Hours": ["number": (duration / 36).rounded() / 100],
            "Session ID": ["rich_text": [["text": ["content": session.id.uuidString]]]],
        ]
    }

    static func parseDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? isoFormatter.date(from: string)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    @discardableResult
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.baseURL)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        for _ in 0..<5 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw NotionError(status: 0, code: "network", message: "Couldn't reach Notion. Check your internet connection.")
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 429 {
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
                try await Task.sleep(for: .seconds(max(wait, 0.5)))
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(status) else {
                let message = status == 401
                    ? "Notion didn't accept this key. Make sure you copied the whole secret."
                    : json["message"] as? String ?? "Notion returned an error (\(status))."
                throw NotionError(status: status, code: json["code"] as? String ?? "", message: message)
            }
            return json
        }
        throw NotionError(status: 429, code: "rate_limited", message: "Notion is busy right now. GrahamTracker will try again shortly.")
    }
}
