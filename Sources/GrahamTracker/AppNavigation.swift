import Foundation

/// Lets the menu bar drive what the window shows.
@MainActor
final class AppNavigation: ObservableObject {
    /// True until the running session's start field has been focused.
    @Published var pendingFocusActiveStart = false
    @Published private(set) var focusRequest = 0

    func requestFocusActiveStart() {
        pendingFocusActiveStart = true
        focusRequest += 1
    }
}
