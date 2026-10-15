import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case charts = "Charts"

    var id: Self { self }
}

struct MainView: View {
    @ObservedObject var store: TrackerStore
    @AppStorage("selectedTab") private var tab: MainTab = .sessions
    @AppStorage("granularity") private var granularity: Granularity = .week
    @State private var anchor = Date()

    private var period: Period { Period(granularity: granularity, anchor: anchor) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .sessions: SessionsView(store: store, period: period)
            case .charts: ChartsView(store: store, period: period)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $tab) {
                ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button { anchor = period.shifted(by: -1).anchor } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .help("Previous (⌘[)")
            Text(period.title)
                .font(.headline)
                .frame(minWidth: 190)
            Button { anchor = period.shifted(by: 1).anchor } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .help("Next (⌘])")
            Button("Today") { anchor = Date() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(period.containsNow)

            Spacer()

            Picker("Range", selection: $granularity) {
                ForEach(Granularity.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(10)
    }
}
