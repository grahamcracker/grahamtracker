import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var sync: NotionSync

    @State private var keyDraft = ""
    @State private var isConnecting = false
    @State private var keyError: String?

    @State private var pages: [NotionPage] = []
    @State private var selectedPageID: String?
    @State private var isLoadingPages = false
    @State private var pagesError: String?
    @State private var isCreating = false
    @State private var createError: String?

    @State private var launchAtLogin = false
    @State private var loginError: String?

    private static let integrationsURL = URL(string: "https://www.notion.so/profile/integrations")!

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            }
            .onAppear(perform: refreshLaunchAtLogin)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                refreshLaunchAtLogin()
            }

            Section("Notion") {
                Toggle("Sync sessions to Notion", isOn: Binding(get: { sync.settings.enabled }, set: { sync.setEnabled($0) }))
                Text("Each finished session is added as a row in a Notion database. Edits and deletes in GrahamTracker are copied there too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if sync.settings.enabled {
                keySection
                if sync.settings.token != nil {
                    destinationSection
                }
                if sync.isReady {
                    statusSection
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - General

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    // MARK: - Key

    @ViewBuilder
    private var keySection: some View {
        Section("Connection key") {
            if sync.settings.token != nil {
                HStack {
                    Label {
                        Text("Connected to \(sync.settings.workspaceName ?? "Notion")")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Remove Key", role: .destructive) { sync.removeKey() }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Open Notion connections and click **New integration**. Pick your workspace and leave the type as **Internal**.")
                    Text("2. Copy the **Internal Integration Secret** (it starts with `ntn_`) and paste it here. No OAuth setup is needed.")
                }
                .font(.callout)
                Link("Open Notion connections…", destination: Self.integrationsURL)
                HStack {
                    SecureField("Key", text: $keyDraft, prompt: Text("ntn_…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    if isConnecting { ProgressView().controlSize(.small) }
                }
                if let keyError {
                    Text(keyError).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    private func connect() {
        guard !keyDraft.isEmpty, !isConnecting else { return }
        isConnecting = true
        keyError = nil
        Task {
            do {
                try await sync.connect(token: keyDraft)
                keyDraft = ""
            } catch {
                keyError = error.localizedDescription
            }
            isConnecting = false
        }
    }

    // MARK: - Destination

    @ViewBuilder
    private var destinationSection: some View {
        Section("Sessions database") {
            if sync.settings.databaseID != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NotionClient.databaseTitle).fontWeight(.medium)
                        Text("in “\(sync.settings.pageTitle ?? "Notion")”").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = sync.settings.databaseURL.flatMap(URL.init(string:)) {
                        Link("Open in Notion", destination: url)
                    }
                    Button("Change…") { sync.changeDestination() }
                }
            } else {
                Text("Choose a page. GrahamTracker will create a “\(NotionClient.databaseTitle)” database inside it.")
                    .font(.callout)
                HStack {
                    Picker("Page", selection: $selectedPageID) {
                        Text("Choose a page…").tag(String?.none)
                        ForEach(pages) { page in
                            Text(page.title).tag(Optional(page.id))
                        }
                    }
                    Button { loadPages() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh the list of pages")
                        .disabled(isLoadingPages)
                    if isLoadingPages { ProgressView().controlSize(.small) }
                }
                if !isLoadingPages && pages.isEmpty && pagesError == nil {
                    Text("No pages are shared with this connection yet. In Notion, open the page you want to use, click ••• → Connections, and add your connection. Then refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if isCreating { ProgressView().controlSize(.small) }
                    Button("Create Database", action: createDatabase)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedPageID == nil || isCreating)
                }
                if let error = pagesError ?? createError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .task(id: sync.settings.token) {
            if sync.settings.databaseID == nil { loadPages() }
        }
    }

    private func loadPages() {
        guard !isLoadingPages else { return }
        isLoadingPages = true
        pagesError = nil
        Task {
            do {
                pages = try await sync.pages()
                if let selectedPageID, !pages.contains(where: { $0.id == selectedPageID }) {
                    self.selectedPageID = nil
                }
            } catch {
                pagesError = error.localizedDescription
            }
            isLoadingPages = false
        }
    }

    private func createDatabase() {
        guard let page = pages.first(where: { $0.id == selectedPageID }) else { return }
        isCreating = true
        createError = nil
        Task {
            do {
                try await sync.createDatabase(in: page)
            } catch {
                createError = error.localizedDescription
            }
            isCreating = false
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            HStack {
                statusLabel
                Spacer()
                Button("Sync Now") { sync.sync() }
                    .disabled({ if case .syncing = sync.status { return true }; return false }())
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch sync.status {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .synced:
            Label(sync.statusDescription, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        default:
            Text(sync.statusDescription).foregroundStyle(.secondary)
        }
    }
}
