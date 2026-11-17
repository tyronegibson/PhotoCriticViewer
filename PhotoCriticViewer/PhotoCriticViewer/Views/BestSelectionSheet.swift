import SwiftUI
import AppKit

/// Auto-curates a "best of shoot" set — web-sized preview JPEGs, deduped per
/// burst, sorted best-first — then hands it to a review grid before anything
/// is exported, so a bad auto-pick can be dropped before it goes out the door.
struct BestSelectionSheet: View {
    let grid: [PhotoGridItem]
    let shootName: String
    let onComplete: (ImageExportService.Result) -> Void

    private enum Step { case configure, review }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .configure
    @State private var scope: BestSelectionScope = .keepOnly
    @State private var dedupeGroups = true
    @State private var limitCount = false
    @State private var maxCount = 20
    @State private var numberFiles = true

    // Fixed once "Review Selection" is tapped, so tweaking exclusions doesn't
    // reshuffle ranking/numbering out from under the reviewer mid-review.
    @State private var reviewItems: [PhotoGridItem] = []
    @State private var excludedIds: Set<Int64> = []
    @State private var isExporting = false

    private var computedSelection: [PhotoGridItem] {
        BestSelectionService.select(
            from: grid, scope: scope, dedupeGroups: dedupeGroups,
            maxCount: limitCount ? maxCount : nil
        )
    }

    private var includedItems: [PhotoGridItem] {
        reviewItems.filter { !excludedIds.contains($0.fileId) }
    }

    var body: some View {
        switch step {
        case .configure: configureView
        case .review: reviewView
        }
    }

    private var configureView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prepare Best Selection").font(.headline)
            Text("Auto-picks your strongest, non-duplicate shots — you'll get a chance to review and drop any before they're exported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Include", selection: $scope) {
                ForEach(BestSelectionScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Toggle("Best of each burst only (skip near-duplicates)", isOn: $dedupeGroups)

            Toggle(isOn: $limitCount) {
                HStack {
                    Text("Limit to top")
                    TextField("Count", value: $maxCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                        .multilineTextAlignment(.trailing)
                        .disabled(!limitCount)
                        .labelsHidden()
                        .onChange(of: maxCount) { _, newValue in
                            maxCount = min(max(newValue, 1), 200)
                        }
                    Text("photos")
                }
            }

            Toggle("Number filenames by rank (001_, 002_, …)", isOn: $numberFiles)

            Text("\(computedSelection.count) photo(s) match — reviewed as preview JPEGs next; full-resolution RAW originals are untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close without exporting anything")
                Button("Review Selection…") {
                    reviewItems = computedSelection
                    excludedIds = []
                    step = .review
                }
                .keyboardShortcut(.defaultAction)
                .disabled(computedSelection.isEmpty)
                .help("Preview the \(computedSelection.count) auto-picked photo(s) before exporting, and drop any you don't want")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Back") { step = .configure }
                    .help("Change the scope/filter criteria without losing your place")
                Spacer()
                Text("\(includedItems.count) of \(reviewItems.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Deselect All") { excludedIds = Set(reviewItems.map(\.fileId)) }
                    .font(.caption)
                    .help("Drop every photo from the export")
                Button("Select All") { excludedIds = [] }
                    .font(.caption)
                    .help("Include every photo in the export")
            }

            Text("Tap a photo to drop it from the export.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [SwiftUI.GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(reviewItems) { item in
                        ReviewThumbnail(item: item, isExcluded: excludedIds.contains(item.fileId)) {
                            if excludedIds.contains(item.fileId) {
                                excludedIds.remove(item.fileId)
                            } else {
                                excludedIds.insert(item.fileId)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 420)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close without exporting anything")
                Button("Choose Folder & Prepare…") { chooseDestinationAndExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(includedItems.isEmpty || isExporting)
                    .help("Pick a destination folder and export the \(includedItems.count) selected photo(s) as web-sized previews")
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func chooseDestinationAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Prepare"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        let items = includedItems
        let numbered = numberFiles
        let name = shootName
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ImageExportService.exportPreviews(items: items, to: destination, shootName: name, numbered: numbered)
            DispatchQueue.main.async {
                isExporting = false
                onComplete(result)
                dismiss()
            }
        }
    }
}

private struct ReviewThumbnail: View {
    let item: PhotoGridItem
    let isExcluded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                PreviewImage(previewPath: item.previewPath)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(isExcluded ? 0.35 : 1)

                Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isExcluded ? Color.secondary : Color.green)
                    .background(Circle().fill(.background))
                    .padding(4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .help(isExcluded ? "Tap to include this photo in the export" : "Tap to drop this photo from the export")

            HStack(spacing: 4) {
                if let score = item.overallScore {
                    Text(String(format: "%.0f", score)).font(.caption2).bold()
                }
                Text(item.filename)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
