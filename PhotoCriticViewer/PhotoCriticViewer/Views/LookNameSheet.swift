import SwiftUI

/// Names a new look (or person) boundary, or renames an existing one.
struct LookNameSheet: View {
    let title: String
    let initialName: String
    let confirmLabel: String
    var fieldPlaceholder: String = "Look name"
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            TextField(fieldPlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(confirmLabel) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .task { name = initialName }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
        dismiss()
    }
}
