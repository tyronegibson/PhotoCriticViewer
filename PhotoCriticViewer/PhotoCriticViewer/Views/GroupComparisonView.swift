import SwiftUI

struct GroupComparisonView: View {
    let db: PhotoCriticDatabase
    let shoot: ShootSummary
    let groupId: Int64
    let curationRunner: CurationRunner
    @Binding var path: [Route]

    @State private var group: GroupDetail?
    @State private var loadError: String?
    @State private var isTogglingComposite = false
    @State private var memberPendingDeletion: GroupMember?

    private let columns = [SwiftUI.GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        ScrollView {
            if let group {
                VStack(alignment: .leading, spacing: 16) {
                    if group.isComposite {
                        Label(
                            "Composite set — every frame is kept together; Best Selection won't drop any of these as duplicates.",
                            systemImage: "square.stack.3d.up.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .padding(10)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let rationale = group.rationale {
                        Panel(title: "Comparison Rationale") {
                            Text(rationale)
                        }
                    }

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(group.members) { member in
                            GroupMemberCard(member: member, isComposite: group.isComposite)
                                .onTapGesture { path.append(.photo(member.fileId, .score)) }
                                .contextMenu {
                                    Button("Not a Duplicate — Remove from Group", systemImage: "rectangle.split.2x1") {
                                        curationRunner.removeFromGroup(groupId: groupId, fileId: member.fileId) { _ in load() }
                                    }
                                    .help("Splits this photo out of the similarity group — use this when the near-duplicate detector grouped two genuinely different photos together")
                                    Button("Delete Photo…", systemImage: "trash", role: .destructive) {
                                        memberPendingDeletion = member
                                    }
                                    .help("Remove this photo from PhotoCritic and move its RAW file to _Marked_for_Deletion")
                                }
                        }
                    }
                }
                .padding()
            } else if let loadError {
                ContentUnavailableView("Couldn't load group", systemImage: "exclamationmark.triangle",
                                        description: Text(loadError))
            } else {
                ProgressView().padding(60)
            }
        }
        .navigationTitle("Similarity Group #\(groupId)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(
                    group?.isComposite == true ? "Unmark Composite Set" : "Mark as Composite Set…",
                    systemImage: group?.isComposite == true ? "square.stack.3d.up.slash" : "square.stack.3d.up"
                ) {
                    toggleComposite()
                }
                .disabled(group == nil || isTogglingComposite)
                .help(
                    group?.isComposite == true
                        ? "Treat this group as a regular near-duplicate burst again"
                        : "Mark these frames as layers for one composite image — Best Selection will keep all of them instead of just the top-ranked one"
                )
            }
        }
        .task(id: groupId) { load() }
        .confirmationDialog(
            "Delete “\(memberPendingDeletion?.filename ?? "")”?",
            isPresented: .constant(memberPendingDeletion != nil),
            titleVisibility: .visible,
            presenting: memberPendingDeletion
        ) { member in
            Button("Delete Photo", role: .destructive) {
                curationRunner.deleteFile(fileId: member.fileId) { _ in load() }
                memberPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { memberPendingDeletion = nil }
        } message: { _ in
            Text("Removes it from PhotoCritic and moves the original RAW file into a “_Marked_for_Deletion” folder inside the shoot folder. Nothing is permanently erased.")
        }
    }

    private func toggleComposite() {
        guard let group else { return }
        isTogglingComposite = true
        curationRunner.setComposite(groupId: groupId, on: !group.isComposite) { _ in
            isTogglingComposite = false
            load()
        }
    }

    private func load() {
        let database = db
        let id = groupId
        runDatabaseQuery({
            try database.groupDetail(groupId: id)
        }) { result in
            switch result {
            case .success(let loaded):
                if let loaded {
                    group = loaded
                } else if !path.isEmpty {
                    // Splitting a 2-member group dissolves it entirely — nothing
                    // left here to show, so back out to the shoot dashboard.
                    path.removeLast()
                }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }
}

private struct GroupMemberCard: View {
    let member: GroupMember
    let isComposite: Bool

    private var borderColor: Color {
        switch member.role {
        case "strongest": .green
        // A composite set's frames are all keepers by design — painting the
        // last-ranked one red would read as "cull this," which is backwards here.
        case "weakest": isComposite ? .clear : .red
        default: .clear
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PreviewImage(previewPath: member.previewPath)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 2))

            Text(member.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            HStack(spacing: 8) {
                if let score = member.overallScore {
                    Text(String(format: "%.0f", score)).font(.headline)
                }
                if let role = member.role {
                    Text(role.replacingOccurrences(of: "_", with: " "))
                        .font(.caption).bold()
                        .foregroundStyle(borderColor == .clear ? .secondary : borderColor)
                }
                Spacer()
                Text("rank \(member.rank)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}
