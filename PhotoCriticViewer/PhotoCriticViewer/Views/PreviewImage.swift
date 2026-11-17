import SwiftUI
import AppKit

/// Loads a preview JPEG straight from disk — these are local files, not remote
/// URLs, so a simple synchronous-on-background-thread loader is enough (no need
/// for AsyncImage's network-request semantics).
struct PreviewImage: View {
    let previewPath: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.2))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: previewPath) { await load() }
    }

    private func load() async {
        guard let previewPath else { return }
        let url = WorkspaceConfig.previewURL(forPreviewPath: previewPath)
        let loaded = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
        if !Task.isCancelled { image = loaded }
    }
}
