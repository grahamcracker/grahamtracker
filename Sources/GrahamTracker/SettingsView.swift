import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var sync: NotionSync
    let dataDirectory: URL

    var body: some View {
        Form {
            GeneralSection()
            NotionSection(sync: sync)
            Section("Advanced") {
                LabeledContent("Data folder") {
                    Button("Open in Finder") { NSWorkspace.shared.open(dataDirectory) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSection: View {
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            if let loginError {
                Text(loginError).font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
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
        refresh()
    }
}

private struct NotionSection: View {
    @ObservedObject var sync: NotionSync

    @State private var keyDraft = ""
    @State private var isConnecting = false
    @State private var keyError: String?

    @State private var pages: [NotionPage] = []
    @State private var selectedPageID: String?
    @State private var isLoadingPages = false
    @State private var pagesError: String?
    @State private var isInstalling = false
    @State private var installError: String?

    private static let integrationsURL = URL(string: "https://www.notion.so/profile/integrations")!

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Sync sessions to Notion", isOn: Binding(get: { sync.settings.enabled }, set: { sync.setEnabled($0) }))
                Text("Your finished sessions are copied to a Notion page you choose. Edits and deletes in GrahamTracker are copied there too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if sync.settings.enabled {
                keyRows
                if sync.settings.token != nil {
                    pageRows
                }
                if sync.isReady {
                    statusRow
                }
            }
        } header: {
            Text("Notion")
        }
    }

    // MARK: - Key

    @ViewBuilder
    private var keyRows: some View {
        if sync.settings.token != nil {
            LabeledContent("Key") {
                HStack {
                    Label {
                        Text("Connected to \(sync.settings.workspaceName ?? "Notion")")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Button("Remove", role: .destructive) { sync.removeKey() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Key").fontWeight(.medium)
                VStack(alignment: .leading, spacing: 4) {
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

    // MARK: - Page

    @ViewBuilder
    private var pageRows: some View {
        Group {
            if sync.settings.databaseID != nil {
                LabeledContent("Page") {
                    HStack {
                        Text(sync.settings.pageTitle ?? "Notion")
                        if let url = sync.settings.databaseURL.flatMap(URL.init(string:)) {
                            Link("Open", destination: url)
                        }
                        Button("Change…") { sync.changeDestination() }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Page").fontWeight(.medium)
                    Text("Choose the page your sessions should go on. GrahamTracker adds a sessions table to it, or picks up the one it added before.")
                        .font(.callout)
                    HStack {
                        Picker("Page", selection: $selectedPageID) {
                            Text("Choose a page…").tag(String?.none)
                            ForEach(pages) { page in
                                Text(page.title).tag(Optional(page.id))
                            }
                        }
                        .labelsHidden()
                        Button { loadPages() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh the list of pages")
                            .disabled(isLoadingPages)
                        if isLoadingPages { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Use This Page", action: install)
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedPageID == nil || isInstalling)
                        if isInstalling { ProgressView().controlSize(.small) }
                    }
                    if !isLoadingPages && pages.isEmpty && pagesError == nil {
                        Text("No pages are shared with this connection yet. In Notion, open the page you want to use, click ••• → Connections, and add your connection. Then refresh.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let error = pagesError ?? installError {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
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

    private func install() {
        guard let page = pages.first(where: { $0.id == selectedPageID }) else { return }
        isInstalling = true
        installError = nil
        Task {
            do {
                try await sync.install(in: page)
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        LabeledContent("Status") {
            HStack {
                statusLabel
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
