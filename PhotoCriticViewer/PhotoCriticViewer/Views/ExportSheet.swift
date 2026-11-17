import SwiftUI
import AppKit

private enum ExportScope: String, CaseIterable, Identifiable {
    case keep = "Keep Only"
    case keepAndMaybe = "Keep + Maybe"
    case all = "All Photos"
    var id: String { rawValue }

    func matches(_ item: PhotoGridItem) -> Bool {
        switch self {
        case .keep: item.recommendation == "KEEP"
        case .keepAndMaybe: item.recommendation == "KEEP" || item.recommendation == "MAYBE"
        case .all: true
        }
    }
}

/// Copies original RAW files (not previews) for the chosen recommendation
/// tier to a folder the user picks. Sources are never modified.
struct ExportSheet: View {
    let grid: [PhotoGridItem]
    let onComplete: (ImageExportService.Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: ExportScope = .keep
    @State private var isExporting = false

    private var matchingCount: Int {
        grid.filter { scope.matches($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Photos").font(.headline)

            Picker("Include", selection: $scope) {
                ForEach(ExportScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Text("\(matchingCount) photo(s) will be copied — original files, not previews.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close without exporting anything")
                Button("Choose Folder & Export…") { chooseDestinationAndExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(matchingCount == 0 || isExporting)
                    .help("Pick a destination folder and copy the \(matchingCount) matching original RAW file(s) there")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func chooseDestinationAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        let items = grid.filter { scope.matches($0) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ImageExportService.export(items: items, to: destination)
            DispatchQueue.main.async {
                isExporting = false
                onComplete(result)
                dismiss()
            }
        }
    }
}
