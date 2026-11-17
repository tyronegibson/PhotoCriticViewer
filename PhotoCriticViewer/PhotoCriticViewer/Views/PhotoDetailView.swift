import SwiftUI

struct PhotoDetailView: View {
    let db: PhotoCriticDatabase
    let shoot: ShootSummary
    let fileId: Int64
    let sort: SortMode
    let curationRunner: CurationRunner
    @Binding var path: [Route]

    @State private var photo: PhotoDetail?
    @State private var prevId: Int64?
    @State private var nextId: Int64?
    @State private var loadError: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        ScrollView {
            if let photo {
                HStack(alignment: .top, spacing: 24) {
                    leftColumn(photo)
                        .frame(maxWidth: .infinity)
                    rightColumn(photo)
                        .frame(width: 380)
                }
                .padding()
            } else if let loadError {
                ContentUnavailableView("Couldn't load photo", systemImage: "exclamationmark.triangle",
                                        description: Text(loadError))
            } else {
                ProgressView().padding(60)
            }
        }
        .navigationTitle(photo?.filename ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button("Previous", systemImage: "chevron.left") { navigate(to: prevId) }
                    .disabled(prevId == nil)
                    .help("Previous photo in the current sort order")
                Button("Next", systemImage: "chevron.right") { navigate(to: nextId) }
                    .disabled(nextId == nil)
                    .help("Next photo in the current sort order")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Delete Photo…", systemImage: "trash", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .help("Remove this photo from PhotoCritic and move its RAW file to _Marked_for_Deletion")
            }
        }
        .task(id: fileId) { load() }
        .confirmationDialog(
            "Delete “\(photo?.filename ?? "")”?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Photo", role: .destructive) {
                curationRunner.deleteFile(fileId: fileId) { _ in
                    if !path.isEmpty { path.removeLast() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from PhotoCritic and moves the original RAW file into a “_Marked_for_Deletion” folder inside the shoot folder. Nothing is permanently erased.")
        }
    }

    @ViewBuilder
    private func leftColumn(_ photo: PhotoDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PreviewImage(previewPath: photo.technical?.previewPath)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxHeight: 640)

            if let evaluation = photo.evaluation {
                Panel(title: "Reasoning") {
                    Text(evaluation.reasoning)
                    if let s = evaluation.distinguishingStrength {
                        Text("+ \(s)").foregroundStyle(.green).font(.callout)
                    }
                    if let w = evaluation.distinguishingWeakness {
                        Text("- \(w)").foregroundStyle(.red).font(.callout)
                    }
                }

                Panel(title: "Strengths / Weaknesses") {
                    TagFlow(tags: evaluation.strengths, color: .secondary)
                    if !evaluation.weaknesses.isEmpty {
                        TagFlow(tags: evaluation.weaknesses, color: .orange)
                    }
                }
            }

            if let group = photo.group {
                Panel(title: "Similarity Group") {
                    Text("Rank \(group.rank)" + (group.role.map { " — \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""))
                        .font(.headline)
                    if let rationale = group.rationale {
                        Text(rationale).font(.callout).foregroundStyle(.secondary)
                    }
                    Button("View full comparison →") { path.append(.group(group.groupId)) }
                        .help("Compare every photo in this burst side by side")
                }
            }
        }
    }

    @ViewBuilder
    private func rightColumn(_ photo: PhotoDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let evaluation = photo.evaluation {
                Panel(title: "Overall") {
                    HStack(spacing: 10) {
                        Text(String(format: "%.1f", evaluation.overallScore)).font(.system(size: 32, weight: .heavy))
                        RecommendationBadge(recommendation: evaluation.recommendation)
                        Text("class \(evaluation.classification)").foregroundStyle(.secondary)
                    }
                }

                Panel(title: "Category Scores") {
                    VStack(spacing: 8) {
                        ForEach(evaluation.orderedScores, id: \.0) { key, value in
                            ScoreBar(label: key.replacingOccurrences(of: "_", with: " "), value: value)
                        }
                    }
                }
            }

            if let technical = photo.technical {
                Panel(title: "Technical Cull") {
                    LabeledRow("Sharpness (center-crop)", String(format: "%.0f", technical.sharpnessScore))
                    LabeledRow("Exposure mean", String(format: "%.0f", technical.exposureMean))
                    LabeledRow("Highlight clip", String(format: "%.2f%%", technical.highlightClipPct))
                    LabeledRow("Shadow clip", String(format: "%.2f%%", technical.shadowClipPct))
                    if !technical.flags.isEmpty {
                        TagFlow(tags: technical.flags.map { $0.replacingOccurrences(of: "_", with: " ") }, color: .orange)
                    }
                }
            }

            if let metadata = photo.metadata {
                Panel(title: "Metadata") {
                    LabeledRow("Camera", metadata.cameraModel ?? "—")
                    LabeledRow("Lens", metadata.lens ?? "—")
                    LabeledRow("ISO", metadata.iso.map(String.init) ?? "—")
                    LabeledRow("Aperture", metadata.aperture.map { "f/\($0)" } ?? "—")
                    LabeledRow("Shutter", metadata.shutterSpeed ?? "—")
                    LabeledRow("Focal length", metadata.focalLength ?? "—")
                    LabeledRow("Captured", metadata.captureTime ?? "—")
                }
            }
        }
    }

    private func navigate(to id: Int64?) {
        guard let id else { return }
        path[path.count - 1] = .photo(id, sort)
    }

    private func load() {
        let database = db
        let id = fileId
        let shootId = shoot.id
        let sortMode = sort
        runDatabaseQuery({
            let detail = try database.photoDetail(fileId: id)
            let ids = try database.shootGrid(shootId: shootId, sort: sortMode).map(\.fileId)
            return (detail, ids)
        }) { result in
            switch result {
            case .success(let (detail, ids)):
                photo = detail
                if let idx = ids.firstIndex(of: id) {
                    prevId = idx > 0 ? ids[idx - 1] : nil
                    nextId = idx < ids.count - 1 ? ids[idx + 1] : nil
                }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }
}

// MARK: - Shared detail-view components

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }
}

struct ScoreBar: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.1f", value)).font(.caption).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(width: geo.size.width * CGFloat(value / 10))
                }
            }
            .frame(height: 4)
        }
    }
}

struct TagFlow: View {
    let tags: [String]
    let color: Color

    var body: some View {
        // Simple wrap layout without a third-party dependency.
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(color)
            }
        }
    }
}

/// Minimal wrapping HStack-of-tags layout (Layout protocol, no dependency needed).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
