import AppKit
import SwiftUI

/// Editable HH:MM:SS field. SwiftUI's DatePicker can't show seconds on macOS, so this wraps NSDatePicker.
struct TimeField: NSViewRepresentable {
    @Binding var date: Date
    var focusRequested = false
    var onFocused: () -> Void = {}

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .hourMinuteSecond
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if picker.dateValue != date { picker.dateValue = date }
        if focusRequested { context.coordinator.focusWhenVisible(picker) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimeField
        private var focusTask: Task<Void, Never>?

        init(_ parent: TimeField) { self.parent = parent }

        /// The picker may not be in a visible window yet (e.g. the window is still opening), so poll briefly.
        func focusWhenVisible(_ picker: NSDatePicker) {
            guard focusTask == nil else { return }
            focusTask = Task { @MainActor [weak self, weak picker] in
                defer { self?.focusTask = nil }
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self, let picker else { return }
                    if let window = picker.window, window.isVisible {
                        window.makeFirstResponder(picker)
                        self.parent.onFocused()
                        return
                    }
                }
            }
        }

        @objc func changed(_ sender: NSDatePicker) {
            parent.date = sender.dateValue
            // The store may reject or adjust the edit; show what was actually saved.
            if parent.date != sender.dateValue { sender.dateValue = parent.date }
        }
    }
}
