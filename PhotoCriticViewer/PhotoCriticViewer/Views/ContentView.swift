import SwiftUI
import AppKit

struct ContentView: View {
    @State private var db: PhotoCriticDatabase?
    @State private var shoots: [ShootSummary] = []
    @State private var selectedShootId: Int64?
    @State private var loadError: String?
    // .shared, not a fresh instance: the local control API drives jobs through the same
    // IngestRunner/CurationRunner this view displays, so an API-triggered job is visible
    // here too and the "only one job at a time" guard applies across both.
    @State private var ingestRunner = IngestRunner.shared
    @State private var curationRunner = CurationRunner.shared
    @State private var cameraDetector = CameraDetector()
    @State private var shootPendingDeletion: ShootSummary?
    @State private var shootPendingRename: ShootSummary?
    @State private var cameraPendingImport: CameraDetector.CameraVolume?
    @State private var ejectFailedVolumeName: String?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(shoots, selection: $selectedShootId) { shoot in
                    ShootRow(shoot: shoot)
                        .tag(shoot.id)
                        .contextMenu {
                            Button("Rename Shoot…", systemImage: "pencil") {
                                shootPendingRename = shoot
                            }
                            .help("Rename this shoot's folder on disk and update PhotoCritic to match")
                            Toggle("Multiple People in This Shoot", isOn: Binding(
                                get: { shoot.separatePeople },
                                set: { newValue in
                                    curationRunner.setSeparatePeople(shootId: shoot.id, on: newValue) { _ in load() }
                                }
                            ))
                            .help("Turn on for group shoots with more than one subject, so you can tag and filter by person. Leave off for single-subject shoots and events.")
                            Button("Delete Shoot…", systemImage: "trash", role: .destructive) {
                                shootPendingDeletion = shoot
                            }
                            .help("Remove this shoot from PhotoCritic and move its RAW files to a _Marked_for_Deletion folder")
                        }
                }
                if !cameraDetector.detectedVolumes.isEmpty {
                    Divider()
                    CameraDetectedView(volumes: cameraDetector.detectedVolumes) { volume in
                        cameraPendingImport = volume
                    } onEject: { volume in
                        if !cameraDetector.eject(volume) {
                            ejectFailedVolumeName = volume.name
                        }
                    }
                }
                Divider()
                IngestDropView(runner: ingestRunner) { folder in
                    ingestRunner.startOrganize(folder: folder) { load() }
                }
            }
            .navigationTitle("PhotoCritic")
            .frame(minWidth: 220)
            .toolbar {
                ToolbarItem {
                    Button("Reload", systemImage: "arrow.clockwise") { load() }
                        .help("Reload the shoot list from the database")
                }
            }
        } detail: {
            if let db, let shoot = shoots.first(where: { $0.id == selectedShootId }) {
                ShootNavigationHost(db: db, shoot: shoot, curationRunner: curationRunner, ingestRunner: ingestRunner, onReload: load)
            } else if let loadError {
                ContentUnavailableView("Couldn't load database", systemImage: "exclamationmark.triangle",
                                        description: Text(loadError))
            } else {
                ContentUnavailableView("Select a shoot", systemImage: "photo.stack")
            }
        }
        .task { await loadWithRetry() }
        .onAppear {
            // SwiftUI's auto-generated toolbar has no stable identifier, so macOS can't
            // persist a user's "Icon and Text" customization across launches — it silently
            // reverts to icon-only, which leaves the Sort/Look menu pickers showing no label
            // at all (no icon to fall back on). Force the readable mode every launch instead.
            DispatchQueue.main.async {
                NSApp.windows.first?.toolbar?.displayMode = .iconAndLabel
            }
        }
        .confirmationDialog(
            "Delete “\(shootPendingDeletion?.displayName ?? "")”?",
            isPresented: .constant(shootPendingDeletion != nil),
            titleVisibility: .visible,
            presenting: shootPendingDeletion
        ) { shoot in
            Button("Delete Shoot", role: .destructive) {
                let id = shoot.id
                curationRunner.deleteShoot(shootId: id) { _ in
                    if selectedShootId == id { selectedShootId = nil }
                    load()
                }
                shootPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { shootPendingDeletion = nil }
        } message: { shoot in
            Text("Removes all \(shoot.totalFiles) photo(s) from PhotoCritic and moves the original RAW files into a “_Marked_for_Deletion” folder inside the shoot folder. Nothing is permanently erased.")
        }
        .sheet(item: $shootPendingRename) { shoot in
            RenameShootSheet(shoot: shoot, curationRunner: curationRunner) { load() }
        }
        .sheet(item: $cameraPendingImport) { volume in
            CameraImportSheet(volume: volume, ingestRunner: ingestRunner) { load() }
        }
        .alert(
            "Couldn't Eject “\(ejectFailedVolumeName ?? "")”",
            isPresented: .constant(ejectFailedVolumeName != nil),
            presenting: ejectFailedVolumeName
        ) { _ in
            Button("OK") { ejectFailedVolumeName = nil }
        } message: { _ in
            Text("It may still be in use — try closing any open files or windows on it, then eject again.")
        }
    }

    private func load() {
        Task { await loadOnce() }
    }

    /// The connection opens READWRITE with a busy_timeout (see SQLiteConnection) so it can
    /// create the WAL sidecar files; that means a query can now block for that timeout if
    /// the Python pipeline's writer holds the lock, where a strictly read-only connection
    /// never could. Reload and the startup .task both call this, so the open + query run
    /// off the main actor — otherwise an ingest running mid-commit could freeze the UI.
    @discardableResult
    private func loadOnce() async -> Bool {
        let result: Result<(PhotoCriticDatabase, [ShootSummary]), Error> = await Task.detached {
            do {
                let database = try PhotoCriticDatabase()
                return .success((database, try database.listShoots()))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let (database, loadedShoots)):
            db = database
            shoots = loadedShoots
            loadError = nil
            return true
        case .failure(let error):
            loadError = error.localizedDescription
            return false
        }
    }

    /// Startup only: the workspace lives on an external drive that may still
    /// be mid-mount right when the app launches (e.g. right after login or a
    /// sleep/wake cycle), which fails with "unable to open database file" —
    /// not a real problem, just a timing race. Retry briefly instead of
    /// making the photographer click Reload for something that resolves
    /// itself within a second or two.
    private func loadWithRetry() async {
        for attempt in 0..<5 {
            if await loadOnce() { return }
            if attempt < 4 { try? await Task.sleep(for: .seconds(1)) }
        }
    }
}

/// Shown when a Hasselblad body or card mounts as a USB volume — both can
/// mount separately, so this lists every removable, ejectable volume
/// carrying .3FR files found right now.
private struct CameraDetectedView: View {
    let volumes: [CameraDetector.CameraVolume]
    let onImport: (CameraDetector.CameraVolume) -> Void
    let onEject: (CameraDetector.CameraVolume) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(volumes) { volume in
                HStack(spacing: 6) {
                    Image(systemName: "camera")
                        .foregroundStyle(.blue)
                    Text(volume.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Import…") { onImport(volume) }
                        .font(.caption)
                        .help("Copy new RAW files from \(volume.name) into a folder and organize them")
                    Button {
                        onEject(volume)
                    } label: {
                        Image(systemName: "eject")
                    }
                    .font(.caption)
                    .help("Eject \(volume.name)")
                }
            }
        }
        .padding(10)
    }
}

private struct ShootRow: View {
    let shoot: ShootSummary
    @State private var rawFilesMissing = false

    private var needsEvaluation: Bool {
        shoot.totalFiles > 0 && shoot.evaluatedCount < shoot.totalFiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(shoot.displayName).font(.headline)
                    .foregroundStyle(rawFilesMissing ? Color.red : Color.primary)
                if rawFilesMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help("This shoot's RAW files no longer exist at the location PhotoCritic recorded (moved, deleted, or evicted from iCloud). Previews still show, but Edit in Photoshop/Lightroom and RAW export won't work.")
                }
                if needsEvaluation {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("\(shoot.totalFiles - shoot.evaluatedCount) of \(shoot.totalFiles) photo(s) not yet evaluated — open this shoot and click Evaluate Shoot")
                }
            }
            HStack(spacing: 10) {
                Label("\(shoot.totalFiles)", systemImage: "photo")
                    .help("\(shoot.totalFiles) total photo(s) in this shoot")
                Label("\(shoot.keepCount)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    .help("\(shoot.keepCount) recommended KEEP")
                Label("\(shoot.maybeCount)", systemImage: "questionmark.circle").foregroundStyle(.yellow)
                    .help("\(shoot.maybeCount) recommended MAYBE")
                Label("\(shoot.rejectCount)", systemImage: "xmark.circle").foregroundStyle(.red)
                    .help("\(shoot.rejectCount) recommended REJECT")
                if needsEvaluation {
                    Label("\(shoot.totalFiles - shoot.evaluatedCount)", systemImage: "sparkles")
                        .foregroundStyle(.orange)
                        .help("\(shoot.totalFiles - shoot.evaluatedCount) photo(s) awaiting AI evaluation")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            rawFilesMissing ? Color.red.opacity(0.18) : (needsEvaluation ? Color.orange.opacity(0.10) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .task(id: shoot.sampleFilePaths) {
            let paths = shoot.sampleFilePaths
            guard !paths.isEmpty else { rawFilesMissing = false; return }
            // Off the main actor: stat-ing paths on an unmounted/slow external volume can block.
            rawFilesMissing = await Task.detached {
                paths.contains { !FileManager.default.fileExists(atPath: $0) }
            }.value
        }
    }
}

/// Owns the navigation stack for one shoot (dashboard -> photo detail / group
/// comparison), reset via .id(shoot.id) whenever the sidebar selection changes.
private struct ShootNavigationHost: View {
    let db: PhotoCriticDatabase
    let shoot: ShootSummary
    let curationRunner: CurationRunner
    let ingestRunner: IngestRunner
    let onReload: () -> Void
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            DashboardView(db: db, shoot: shoot, curationRunner: curationRunner, ingestRunner: ingestRunner, onReload: onReload, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .photo(let fileId, let sort):
                        PhotoDetailView(db: db, shoot: shoot, fileId: fileId, sort: sort, curationRunner: curationRunner, path: $path)
                    case .group(let groupId):
                        GroupComparisonView(db: db, shoot: shoot, groupId: groupId, curationRunner: curationRunner, path: $path)
                    }
                }
        }
        .id(shoot.id)
    }
}

enum Route: Hashable {
    case photo(Int64, SortMode)
    case group(Int64)
}
