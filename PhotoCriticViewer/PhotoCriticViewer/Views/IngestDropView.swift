import SwiftUI
import UniformTypeIdentifiers

/// Sidebar drop target — drop a folder here to run it through organize.py
/// (fast: sorts into per-date shoots, decodes, technical-culls, EXIF, burst-
/// groups — no GPU). Evaluate a resulting shoot afterward from its Dashboard.
/// The job keeps running even if the log sheet is closed, since IngestRunner
/// is owned by ContentView, not this view.
struct IngestDropView: View {
    let runner: IngestRunner
    let onDrop: (URL) -> Void

    @State private var isTargeted = false
    @State private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            dropArea
        }
        .padding(10)
        .sheet(isPresented: $showingLog) {
            IngestLogView(runner: runner)
        }
    }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 1.5, dash: [5])
            )
            .background(
                isTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .frame(height: 54)
            .overlay {
                Label(
                    runner.isRunning ? "A shoot is already processing…" : "Drop a folder to process",
                    systemImage: "tray.and.arrow.down"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
            }
            .opacity(runner.isRunning ? 0.5 : 1)
            .help(
                runner.isRunning
                    ? "A job is already running — wait for it to finish before starting another"
                    : "Drop a folder to sort it by capture date, decode, technical-cull, and burst-group it (fast, no GPU)"
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard !runner.isRunning, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else { return }
                    DispatchQueue.main.async { onDrop(url) }
                }
                return true
            }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch runner.status {
        case .idle:
            EmptyView()
        case .running(let label):
            HStack(spacing: 6) {
                if let fraction = runner.progressFraction {
                    ProgressView(value: fraction).controlSize(.small).frame(width: 50)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(label)…")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Log…") { showingLog = true }.font(.caption)
                    .help("View live output from the running job")
            }
        case .finished(let label, let success):
            HStack(spacing: 6) {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(success ? .green : .red)
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Log…") { showingLog = true }.font(.caption)
                    .help("View live output from the running job")
            }
        }
    }
}

struct IngestLogView: View {
    let runner: IngestRunner
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ingest Log").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .help("Close this window — the job keeps running in the background")
            }
            .padding()

            if let fraction = runner.progressFraction {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(runner.progressStage ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(runner.progressCurrent ?? 0)/\(runner.progressTotal ?? 0) — \(Int(fraction * 100))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: fraction)
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? "Waiting for output…" : runner.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("bottom")
                }
                .onChange(of: runner.log) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(width: 640, height: 420)
    }
}
