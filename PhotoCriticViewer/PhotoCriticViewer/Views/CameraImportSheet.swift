import AppKit
import SwiftUI

/// Import RAW files from a detected camera/card volume into a destination
/// folder, then run that folder through organize.py — the same fast,
/// no-GPU pass a manually dropped folder gets. The camera's card is only
/// ever read from; nothing is copied back to it or deleted off it.
struct CameraImportSheet: View {
    let volume: CameraDetector.CameraVolume
    let ingestRunner: IngestRunner
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("cameraImportDestination") private var savedDestination: String = ""
    @State private var destination: URL?
    @State private var fileCount: Int = 0
    @State private var preScanWarnings: [String] = []
    @State private var isImporting = false
    @State private var importSummary: CameraImportService.Result?
    @State private var showingSummary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from \(volume.name)").font(.headline)

            Text("\(fileCount) RAW (.3FR) file(s) found on this volume. JPEG previews on the card, if any, aren't imported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !preScanWarnings.isEmpty {
                Text("⚠️ Could not read \(preScanWarnings.count) item(s) while scanning the card — the count above may be incomplete. Re-plug the card if this number looks low.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination folder").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(destination?.path ?? "Choose a folder…")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDestination() }
                        .help("Pick where imported photos should go — organize.py runs on this folder afterward")
                }
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }

            Text("Copies new files only — anything already in the destination is skipped. The card itself is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close without importing anything")
                Button("Import & Organize") { importAndOrganize() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || isImporting || fileCount == 0)
                    .help("Copy new files here, then sort them by date, decode, and technical-cull (fast, no GPU)")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            let scan = CameraImportService.countRawFiles(at: volume.url)
            fileCount = scan.count
            preScanWarnings = scan.warnings
            if !savedDestination.isEmpty {
                destination = URL(fileURLWithPath: savedDestination)
            }
        }
        .alert("Import Complete", isPresented: $showingSummary, presenting: importSummary) { _ in
            Button("OK") { importSummary = nil; dismiss() }
        } message: { summary in
            Text(importSummaryText(summary))
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let destination { panel.directoryURL = destination }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        savedDestination = url.path
    }

    private func importAndOrganize() {
        guard let destination else { return }
        isImporting = true
        let sourceVolume = volume.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CameraImportService.importPhotos(from: sourceVolume, to: destination)
            DispatchQueue.main.async {
                isImporting = false
                importSummary = result
                showingSummary = true
                if !result.copied.isEmpty {
                    ingestRunner.startOrganize(folder: destination) { onImported() }
                }
            }
        }
    }

    private func importSummaryText(_ summary: CameraImportService.Result) -> String {
        var lines: [String] = []
        if !summary.scanWarnings.isEmpty {
            lines.append("⚠️ Could not read \(summary.scanWarnings.count) item(s) on the card — the scan kept going, but double-check nothing was missed:")
            for w in summary.scanWarnings.prefix(5) { lines.append("  \(w)") }
            if summary.scanWarnings.count > 5 { lines.append("  …and \(summary.scanWarnings.count - 5) more") }
        }
        lines.append("Copied \(summary.copied.count) new file(s).")
        if !summary.skippedExisting.isEmpty {
            lines.append("Skipped \(summary.skippedExisting.count) already imported.")
        }
        if !summary.renamedForCollision.isEmpty {
            lines.append("\(summary.renamedForCollision.count) file(s) shared a name with a different photo already imported (likely a different roll on the card) — renamed on import so nothing was dropped:")
            for entry in summary.renamedForCollision.prefix(5) {
                lines.append("  \(entry.original) → \(entry.renamedTo)")
            }
            if summary.renamedForCollision.count > 5 {
                lines.append("  …and \(summary.renamedForCollision.count - 5) more")
            }
        }
        if !summary.possibleDuplicates.isEmpty {
            lines.append("⚠️ \(summary.possibleDuplicates.count) of those also matched an existing file's size exactly, not just its name — a content check confirmed they're different photos and copied them anyway, but worth a look:")
            for name in summary.possibleDuplicates.prefix(5) { lines.append("  \(name)") }
            if summary.possibleDuplicates.count > 5 { lines.append("  …and \(summary.possibleDuplicates.count - 5) more") }
        }
        if !summary.failed.isEmpty {
            // Group by reason so "210 failed" reads as either "one root cause, 210 files" or
            // "210 different individual problems" -- showing only failed.first!.reason made
            // those two very different situations look identical and gave no way to tell which
            // one actually happened.
            var countByReason: [String: Int] = [:]
            var firstFileByReason: [String: String] = [:]
            for f in summary.failed {
                countByReason[f.reason, default: 0] += 1
                if firstFileByReason[f.reason] == nil { firstFileByReason[f.reason] = f.filename }
            }
            let byCountDesc = countByReason.sorted { $0.value > $1.value }
            lines.append("Failed: \(summary.failed.count) file(s), \(byCountDesc.count) distinct reason(s):")
            for (reason, count) in byCountDesc.prefix(5) {
                lines.append("  \(count)× \(reason) (e.g. \(firstFileByReason[reason] ?? "?"))")
            }
            if byCountDesc.count > 5 { lines.append("  …and \(byCountDesc.count - 5) more reason(s)") }
        }
        if !summary.copied.isEmpty {
            lines.append("Organizing has started in the background.")
        }
        return lines.joined(separator: "\n")
    }
}
