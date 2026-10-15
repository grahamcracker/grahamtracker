import AppKit
import SwiftUI

/// Editable HH:MM:SS field. SwiftUI's DatePicker can't show seconds on macOS, so this wraps NSDatePicker.
struct TimeField: NSViewRepresentable {
    @Binding var date: Date

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
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimeField

        init(_ parent: TimeField) { self.parent = parent }

        @objc func changed(_ sender: NSDatePicker) {
            parent.date = sender.dateValue
            // The store may reject or adjust the edit; show what was actually saved.
            if parent.date != sender.dateValue { sender.dateValue = parent.date }
        }
    }
}
