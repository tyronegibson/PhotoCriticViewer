import SwiftUI
import AppKit

struct DashboardView: View {
    let db: PhotoCriticDatabase
    let shoot: ShootSummary
    let curationRunner: CurationRunner
    let ingestRunner: IngestRunner
    let onReload: () -> Void
    @Binding var path: [Route]

    @State private var sort: SortMode = .score
    @State private var grid: [PhotoGridItem] = []
    @State private var looks: [Look] = []
    @State private var lookFilter: Int64?
    @State private var people: [Person] = []
    @State private var personFilter: Int64?
    @State private var loadError: String?
    @State private var showingExportSheet = false
    @State private var showingBestSelectionSheet = false
    @State private var showingEvaluateLog = false
    @State private var exportSummary: ImageExportService.Result?
    @State private var photoPendingDeletion: PhotoGridItem?
    @State private var markingLookForItem: PhotoGridItem?
    @State private var lookPendingRename: Look?
    @State private var lookPendingDeletion: Look?
    @State private var markingPersonForItem: PhotoGridItem?
    @State private var personPendingRename: Person?
    @State private var personPendingDeletion: Person?
    @State private var showingReevaluateConfirm = false
    @State private var highlightedFilenames: Set<String> = []
    @State private var showHighlightedOnly = false
    @State private var selectedIDs: Set<Int64> = []
    @State private var selectionAnchor: Int64?
    @State private var photoshopError: String?
    @State private var lightroomError: String?

    private var displayedGrid: [PhotoGridItem] {
        var items = grid
        if let lookFilter {
            items = items.filter { $0.lookId == lookFilter }
        }
        if let personFilter {
            items = items.filter { $0.personId == personFilter }
        }
        if showHighlightedOnly {
            items = items.filter { highlightedFilenames.contains($0.filename) }
        }
        return items
    }

    private var needsEvaluation: Bool {
        shoot.totalFiles > 0 && shoot.evaluatedCount < shoot.totalFiles
    }

    private let columns = [SwiftUI.GridItem(.adaptive(minimum: 190), spacing: 14)]

    // `body` is split into `coreContent` + `personModifiers(_:)` + the final
    // re-evaluate dialog (rather than one long modifier chain) because the
    // Swift 6 type-checker times out trying to solve the whole chain — with
    // the Person feature's sheets/dialog added on top of the existing Look
    // ones — as a single expression.
    var body: some View {
        editErrorModifiers(personModifiers(coreContent))
            .confirmationDialog(
                "Re-evaluate “\(shoot.displayName)”?",
                isPresented: $showingReevaluateConfirm
            ) {
                Button("Re-evaluate", role: .destructive) { runEvaluate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Re-scores every photo in this shoot with the current AI model/prompt from scratch — including new fields like outfit detection. Full GPU pass, can take a while for a large shoot.")
            }
    }

    private func editErrorModifiers(_ content: some View) -> some View {
        content
            .alert("Couldn't Open Photoshop", isPresented: photoshopErrorPresented) {
                Button("OK") { photoshopError = nil }
            } message: {
                Text(photoshopError ?? "")
            }
            .alert("Couldn't Open Lightroom", isPresented: lightroomErrorPresented) {
                Button("OK") { lightroomError = nil }
            } message: {
                Text(lightroomError ?? "")
            }
    }

    private var photoshopErrorPresented: Binding<Bool> {
        Binding(get: { photoshopError != nil }, set: { if !$0 { photoshopError = nil } })
    }

    private var lightroomErrorPresented: Binding<Bool> {
        Binding(get: { lightroomError != nil }, set: { if !$0 { lightroomError = nil } })
    }

    private func personModifiers(_ content: some View) -> some View {
        content
            .sheet(item: $markingPersonForItem) { item in
                LookNameSheet(title: "New Person Starting Here", initialName: "", confirmLabel: "Create", fieldPlaceholder: "Person name") { name in
                    curationRunner.markPerson(fileId: item.fileId, name: name) { _ in loadGrid() }
                }
            }
            .sheet(item: $personPendingRename) { person in
                LookNameSheet(title: "Rename Person", initialName: person.name, confirmLabel: "Rename", fieldPlaceholder: "Person name") { name in
                    curationRunner.renamePerson(personId: person.id, name: name) { _ in loadGrid() }
                }
            }
            .confirmationDialog(
                "Remove Person Boundary “\(personPendingDeletion?.name ?? "")”?",
                isPresented: .constant(personPendingDeletion != nil),
                titleVisibility: .visible,
                presenting: personPendingDeletion
            ) { person in
                Button("Remove", role: .destructive) {
                    curationRunner.deletePerson(personId: person.id) { _ in
                        if personFilter == person.id { personFilter = nil }
                        loadGrid()
                    }
                    personPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { personPendingDeletion = nil }
            } message: { _ in
                Text("Photos after this point fall back to the previous person, if any. Nothing is deleted.")
            }
    }

    private var coreContent: some View {
        ScrollView {
            statRow
                .padding([.horizontal, .top])

            if ingestRunner.status != .idle {
                runnerStatusRow
                    .padding(.horizontal)
            }

            if grid.isEmpty {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle")
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(displayedGrid) { item in
                        gridCard(for: item)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(shoot.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let evaluateTitle: String = needsEvaluation ? "Evaluate Shoot" : "Re-evaluate Shoot…"
                let evaluateHelp: String = needsEvaluation
                    ? "Score every un-evaluated photo in this shoot with the AI model (GPU, can take a while)"
                    : "Re-scores every photo in this shoot with the current AI model/prompt (GPU, can take a while) — use this to backfill new fields like outfit detection on a shoot that's already fully evaluated"
                Button(evaluateTitle, systemImage: "sparkles") {
                    if needsEvaluation {
                        runEvaluate()
                    } else {
                        showingReevaluateConfirm = true
                    }
                }
                .disabled(ingestRunner.isRunning || grid.isEmpty)
                .help(evaluateHelp)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Best Selection…", systemImage: "star.circle") { showingBestSelectionSheet = true }
                    .disabled(grid.isEmpty)
                    .help("Auto-pick your strongest, non-duplicate shots and export web-sized previews for posts or client review")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Export…", systemImage: "square.and.arrow.up") { showingExportSheet = true }
                    .disabled(grid.isEmpty)
                    .help("Copy original RAW files for a chosen recommendation tier to a folder you pick")
            }
            ToolbarItem(placement: .primaryAction) {
                sortMenu
            }
            if !looks.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    lookMenu
                }
            }
            if shoot.separatePeople && !people.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    personMenu
                }
            }
            if grid.contains(where: { highlightedFilenames.contains($0.filename) }) {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Highlighted Only", systemImage: "circle.fill", isOn: $showHighlightedOnly)
                        .foregroundStyle(.orange)
                        .help("Show only the orange-highlighted photos")
                }
            }
        }
        .onChange(of: sort) { _, _ in loadGrid() }
        .task(id: shoot.id) { loadGrid() }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(grid: grid) { summary in
                exportSummary = summary
            }
        }
        .sheet(isPresented: $showingBestSelectionSheet) {
            BestSelectionSheet(grid: grid, shootName: shoot.displayName) { summary in
                exportSummary = summary
            }
        }
        .alert("Export Complete", isPresented: .constant(exportSummary != nil), presenting: exportSummary) { _ in
            Button("OK") { exportSummary = nil }
        } message: { summary in
            Text(exportSummaryText(summary))
        }
        .confirmationDialog(
            "Delete “\(photoPendingDeletion?.filename ?? "")”?",
            isPresented: .constant(photoPendingDeletion != nil),
            titleVisibility: .visible,
            presenting: photoPendingDeletion
        ) { item in
            Button("Delete Photo", role: .destructive) {
                curationRunner.deleteFile(fileId: item.fileId) { _ in loadGrid() }
                photoPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { photoPendingDeletion = nil }
        } message: { _ in
            Text("Removes it from PhotoCritic and moves the original RAW file into a “_Marked_for_Deletion” folder inside the shoot folder. Nothing is permanently erased.")
        }
        .sheet(isPresented: $showingEvaluateLog) {
            IngestLogView(runner: ingestRunner)
        }
        .sheet(item: $markingLookForItem) { item in
            LookNameSheet(title: "New Look Starting Here", initialName: "", confirmLabel: "Create") { name in
                curationRunner.markLook(fileId: item.fileId, name: name) { _ in loadGrid() }
            }
        }
        .sheet(item: $lookPendingRename) { look in
            LookNameSheet(title: "Rename Look", initialName: look.name, confirmLabel: "Rename") { name in
                curationRunner.renameLook(lookId: look.id, name: name) { _ in loadGrid() }
            }
        }
        .confirmationDialog(
            "Remove Look Boundary “\(lookPendingDeletion?.name ?? "")”?",
            isPresented: .constant(lookPendingDeletion != nil),
            titleVisibility: .visible,
            presenting: lookPendingDeletion
        ) { look in
            Button("Remove", role: .destructive) {
                curationRunner.deleteLook(lookId: look.id) { _ in
                    if lookFilter == look.id { lookFilter = nil }
                    loadGrid()
                }
                lookPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { lookPendingDeletion = nil }
        } message: { _ in
            Text("Photos after this point fall back to the previous look, if any. Nothing is deleted.")
        }
    }

    // Broken out of `body` as separate, explicitly-typed properties (rather than
    // inline in the .toolbar closure) because the Swift 6 type-checker times out
    // trying to solve three structurally-similar Menu blocks as one expression.

    private var sortMenu: some View {
        // A plain Picker(.menu) in this toolbar renders its pill with the
        // selected value's text invisible (only the chevron shows) — a SwiftUI/
        // AppKit toolbar rendering bug. A Menu with an explicit label showing the
        // current value renders correctly, so drive `sort` from Button actions instead.
        Menu {
            ForEach(SortMode.allCases) { mode in
                Button {
                    sort = mode
                } label: {
                    if sort == mode {
                        Label(mode.rawValue, systemImage: "checkmark")
                    } else {
                        Text(mode.rawValue)
                    }
                }
            }
        } label: {
            Text(sort.rawValue)
        }
        .help("Sort the grid by AI score or filename")
    }

    private var lookMenu: some View {
        Menu {
            Button {
                lookFilter = nil
            } label: {
                if lookFilter == nil {
                    Label("All Looks", systemImage: "checkmark")
                } else {
                    Text("All Looks")
                }
            }
            ForEach(looks) { look in
                Button {
                    lookFilter = look.id
                } label: {
                    if lookFilter == look.id {
                        Label(look.name, systemImage: "checkmark")
                    } else {
                        Text(look.name)
                    }
                }
            }
        } label: {
            Text(looks.first(where: { $0.id == lookFilter })?.name ?? "All Looks")
        }
        .help("Filter the grid to just one look/outfit")
    }

    private var personMenu: some View {
        Menu {
            Button {
                personFilter = nil
            } label: {
                if personFilter == nil {
                    Label("All People", systemImage: "checkmark")
                } else {
                    Text("All People")
                }
            }
            ForEach(people) { person in
                Button {
                    personFilter = person.id
                } label: {
                    if personFilter == person.id {
                        Label(person.name, systemImage: "checkmark")
                    } else {
                        Text(person.name)
                    }
                }
            }
        } label: {
            Text(people.first(where: { $0.id == personFilter })?.name ?? "All People")
        }
        .help("Filter the grid to just one person")
    }

    private func gridCard(for item: PhotoGridItem) -> some View {
        let highlighted: Bool = highlightedFilenames.contains(item.filename)
        let selected: Bool = selectedIDs.contains(item.fileId)
        return PhotoCardView(item: item, isHighlighted: highlighted, isSelected: selected)
            .onTapGesture(count: 2) {
                // Only a plain double-click opens the inspector. Shift/⌘-double-click is an
                // extend/toggle gesture, so opening would throw away the selection the user is building.
                let flags = NSEvent.modifierFlags
                guard !flags.contains(.shift), !flags.contains(.command) else { return }
                openInspector(on: item)
            }
            // `simultaneousGesture` (not another chained `.onTapGesture`) is required here:
            // on macOS's AppKit-backed gesture system, two plain `.onTapGesture` modifiers
            // of different counts don't get the count:1-waits-for-count:2 failure
            // requirement that this trick relies on for that pairing on iOS — the single
            // tap just fires immediately regardless, so a click always opened the inspector.
            // Declaring this one as non-exclusive makes single-click-selects reliable, and a
            // double click still fires both — select, then open — same as Finder.
            .simultaneousGesture(TapGesture(count: 1).onEnded { handleTap(on: item) })
            .contextMenu { gridItemContextMenu(for: item) }
    }

    // Finder-style: a single click only selects. Opening the detail/inspector
    // view now requires a double-click, since selecting (for Photoshop/Lightroom
    // hand-off, deletion, etc.) is the far more common action on a click.
    private func handleTap(on item: PhotoGridItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectionAnchor,
           let anchorIndex = displayedGrid.firstIndex(where: { $0.fileId == anchor }),
           let itemIndex = displayedGrid.firstIndex(where: { $0.fileId == item.fileId }) {
            // Range-select from the last non-shift anchor to this item, Finder-style —
            // the anchor itself doesn't move so repeated shift-clicks re-range from it.
            let range = anchorIndex < itemIndex ? anchorIndex...itemIndex : itemIndex...anchorIndex
            selectedIDs.formUnion(displayedGrid[range].map(\.fileId))
        } else if flags.contains(.command) || flags.contains(.shift) {
            toggleSelection(item.fileId)
            selectionAnchor = item.fileId
        } else {
            selectedIDs = [item.fileId]
            selectionAnchor = item.fileId
        }
    }

    /// Opens the inspector without clearing the selection: the single click before the second
    /// click of a double-click has already selected just this photo, and any multi-selection
    /// the user built is kept so it's still there when they come back from the inspector.
    private func openInspector(on item: PhotoGridItem) {
        selectionAnchor = item.fileId
        path.append(.photo(item.fileId, sort))
    }

    private func toggleSelection(_ id: Int64) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    @ViewBuilder
    private func gridItemContextMenu(for item: PhotoGridItem) -> some View {
        if selectedIDs.contains(item.fileId), selectedIDs.count > 1 {
            let paths = grid.filter { selectedIDs.contains($0.fileId) }.map(\.fullPath)
            Button("Edit \(selectedIDs.count) Photos in Photoshop…", systemImage: "photo.stack") {
                openInPhotoshop(paths: paths)
            }
            .help("Open all selected RAW files in Photoshop")
            Button("Edit \(selectedIDs.count) Photos in Lightroom…", systemImage: "photo.stack") {
                openInLightroom(paths: paths)
            }
            .help("Open all selected RAW files in Lightroom")
        } else {
            Button("Edit in Photoshop…", systemImage: "photo") {
                openInPhotoshop(paths: [item.fullPath])
            }
            .help("Open this RAW file in Photoshop")
            Button("Edit in Lightroom…", systemImage: "photo") {
                openInLightroom(paths: [item.fullPath])
            }
            .help("Open this RAW file in Lightroom")
        }
        Divider()
        if let groupId = item.groupId {
            Button("Compare Group") { path.append(.group(groupId)) }
                .help("View this photo side by side with the rest of its similarity/burst group")
        }
        if let existingLook = looks.first(where: { $0.startFilename == item.filename }) {
            Button("Rename Look “\(existingLook.name)”…") {
                lookPendingRename = existingLook
            }
            Button("Remove Look Boundary", role: .destructive) {
                lookPendingDeletion = existingLook
            }
            .help("Photos after this point fall back to the previous look, if any")
        } else {
            Button("Mark New Look Starts Here…", systemImage: "tag") {
                markingLookForItem = item
            }
            .help("Everything from this photo onward (in the current sort order), up to the next look, is grouped as a new look/outfit")
        }
        if shoot.separatePeople {
            if let existingPerson = people.first(where: { $0.startFilename == item.filename }) {
                Button("Rename Person “\(existingPerson.name)”…") {
                    personPendingRename = existingPerson
                }
                Button("Remove Person Boundary", role: .destructive) {
                    personPendingDeletion = existingPerson
                }
                .help("Photos after this point fall back to the previous person, if any")
            } else {
                Button("Mark New Person Starts Here…", systemImage: "person.crop.circle.badge.plus") {
                    markingPersonForItem = item
                }
                .help("Everything from this photo onward (in the current sort order), up to the next person, is grouped under a new person")
            }
        }
        Button("Delete Photo…", systemImage: "trash", role: .destructive) {
            photoPendingDeletion = item
        }
        .help("Remove this photo from PhotoCritic and move its RAW file to _Marked_for_Deletion")
    }

    // The RAW path recorded at ingest time can go stale — moved, renamed, or
    // (for shoots living on iCloud Drive) evicted/relocated outside the app's
    // knowledge. NSWorkspace either fails silently or hands back an opaque
    // Photoshop/Lightroom-side error in that case, so check up front and say
    // exactly which files are missing and where the app still thinks they are.
    private func missingPathsMessage(for paths: [String]) -> String? {
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard !missing.isEmpty else { return nil }
        let list = missing.map { "• \($0)" }.joined(separator: "\n")
        return "PhotoCritic's database points to a file that no longer exists at that location. It may have been moved, renamed, or (for iCloud-hosted shoots) evicted locally. Re-link or re-ingest this shoot to fix the path.\n\n\(list)"
    }

    private func openInPhotoshop(paths: [String]) {
        guard let photoshopURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") else {
            photoshopError = "Photoshop isn't installed, or Launch Services doesn't recognize it."
            return
        }
        if let missingMessage = missingPathsMessage(for: paths) {
            photoshopError = missingMessage
            return
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.open(urls, withApplicationAt: photoshopURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in photoshopError = error.localizedDescription }
        }
    }

    private func openInLightroom(paths: [String]) {
        guard let lightroomURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.mas.lightroomCC") else {
            lightroomError = "Lightroom isn't installed, or Launch Services doesn't recognize it."
            return
        }
        if let missingMessage = missingPathsMessage(for: paths) {
            lightroomError = missingMessage
            return
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.open(urls, withApplicationAt: lightroomURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in lightroomError = error.localizedDescription }
        }
    }

    private func runEvaluate() {
        ingestRunner.startEvaluate(shootId: shoot.id, shootLabel: shoot.displayName) {
            onReload()
            loadGrid()
        }
    }

    private var runnerStatusRow: some View {
        HStack(spacing: 8) {
            switch ingestRunner.status {
            case .idle:
                EmptyView()
            case .running(let label):
                if let fraction = ingestRunner.progressFraction {
                    ProgressView(value: fraction).controlSize(.small).frame(width: 50)
                    Text("\(Int(fraction * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(label)…").font(.caption)
            case .finished(let label, let success):
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(success ? .green : .red)
                Text(label).font(.caption)
            }
            Spacer()
            Button("Log…") { showingEvaluateLog = true }.font(.caption)
                .help("View live output from the running job")
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func exportSummaryText(_ summary: ImageExportService.Result) -> String {
        var lines = ["Copied \(summary.copied.count) file(s)."]
        if !summary.skippedExisting.isEmpty {
            lines.append("Skipped \(summary.skippedExisting.count) already present at destination.")
        }
        if !summary.failed.isEmpty {
            lines.append("Failed: \(summary.failed.count) — \(summary.failed.first!.reason)")
        }
        return lines.joined(separator: "\n")
    }

    private var statRow: some View {
        let keep = grid.filter { $0.recommendation == "KEEP" }.count
        let maybe = grid.filter { $0.recommendation == "MAYBE" }.count
        let reject = grid.filter { $0.recommendation == "REJECT" }.count
        let evaluated = grid.filter { $0.overallScore != nil }.count

        return HStack(spacing: 12) {
            StatTile(label: "Total", value: grid.count, color: .primary)
            StatTile(label: "Evaluated", value: evaluated, color: .primary)
            StatTile(label: "Keep", value: keep, color: .green)
            StatTile(label: "Maybe", value: maybe, color: .yellow)
            StatTile(label: "Reject", value: reject, color: .red)
            Spacer()
        }
    }

    private func loadGrid() {
        let database = db
        let shootId = shoot.id
        let sortMode = sort
        let separate = shoot.separatePeople
        runDatabaseQuery({
            (try database.shootGrid(shootId: shootId, sort: sortMode),
             try database.listLooks(shootId: shootId),
             separate ? try database.listPeople(shootId: shootId) : [])
        }) { result in
            switch result {
            case .success(let (loadedGrid, loadedLooks, loadedPeople)):
                grid = loadedGrid
                looks = loadedLooks
                people = loadedPeople
                highlightedFilenames = WorkspaceConfig.loadHighlightedFilenames()
                loadError = nil
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2).bold().foregroundStyle(color)
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
