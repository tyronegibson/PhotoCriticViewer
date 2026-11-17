import SwiftUI

/// Renames a shoot's folder on disk (via curate.py's rename-shoot) and
/// updates PhotoCritic's database to match — e.g. turning an auto-named
/// date folder like "2024-10-13" into something meaningful like "Fall Campaign".
struct RenameShootSheet: View {
    let shoot: ShootSummary
    let curationRunner: CurationRunner
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName: String = ""
    @State private var isRenaming = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Shoot").font(.headline)

            TextField("Folder name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { rename() }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            Text("Renames the shoot's actual folder on disk and updates PhotoCritic to match.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close without renaming anything")
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isRenaming)
                    .help("Rename the folder on disk and update the database")
            }
        }
        .padding(20)
        .frame(width: 360)
        .task { newName = shoot.displayName }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    private func rename() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        isRenaming = true
        errorMessage = nil
        curationRunner.renameShoot(shootId: shoot.id, newName: name) { result in
            isRenaming = false
            if result.success {
                onComplete()
                dismiss()
            } else {
                errorMessage = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
