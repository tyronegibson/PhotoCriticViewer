import Testing
import Foundation
@testable import PhotoCriticViewer

/// V1.5 remote access: the two rules that keep "remote" meaning "tailnet only, previews and
/// exports only" -- the Tailscale address check the second listener is gated on, and the
/// /downloads path policy that keeps RAWs (and anything outside exports/) off the phone.
struct LocalAPIRemoteTests {

    // MARK: - isTailscaleAddress

    @Test(arguments: ["100.100.10.20", "100.64.0.1", "100.127.255.254"])
    func acceptsTailscaleCGNATAddresses(_ address: String) {
        #expect(LocalAPISettings.isTailscaleAddress(address))
    }

    @Test(arguments: [
        "0.0.0.0", "127.0.0.1", "192.168.1.20", "10.0.0.5", "8.8.8.8",
        "100.63.255.255", "100.128.0.1",              // just outside 100.64.0.0/10
        "100.100.10", "100.100.10.20.1", "100..51.84", // malformed
        " 100.100.10.20", "100.100.10.084x", "100.100.10.256",
        "::", "fd7a:115c:a1e0::1", "localhost", "",
    ])
    func refusesEverythingElse(_ address: String) {
        #expect(!LocalAPISettings.isTailscaleAddress(address))
    }

    // MARK: - /downloads path policy

    private func makeExportsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-remote-test-\(UUID().uuidString)/exports")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("remote/2026-11-03"), withIntermediateDirectories: true)
        return root
    }

    @Test func allowsAnExportedJPEGInsideExports() throws {
        let root = try makeExportsRoot()
        let file = root.appendingPathComponent("remote/2026-11-03/B0001_original.jpg")
        let check = LocalAPIRemote.checkDownloadPath(file.path, root: root)
        guard case .ok(let url) = check else { Issue.record("expected ok, got \(check)"); return }
        #expect(url.lastPathComponent == "B0001_original.jpg")
    }

    @Test func refusesRawFilesEvenInsideExports() throws {
        let root = try makeExportsRoot()
        for name in ["B0001.3fr", "B0001.3FR", "B0001.fff", "B0001.dng", "notes.txt", "noext"] {
            let check = LocalAPIRemote.checkDownloadPath(root.appendingPathComponent(name).path, root: root)
            if case .ok = check { Issue.record("\(name) was allowed") }
        }
    }

    @Test func refusesPathsOutsideExports() throws {
        let root = try makeExportsRoot()
        let outside = [
            root.deletingLastPathComponent().appendingPathComponent("previews/1.jpg").path,
            root.path + "/../previews/1.jpg",                 // traversal
            root.path + "-evil/x.jpg",                        // prefix trick
            root.path,                                        // the folder itself
            "relative/x.jpg",
        ]
        for raw in outside {
            if case .ok = LocalAPIRemote.checkDownloadPath(raw, root: root) { Issue.record("\(raw) was allowed") }
        }
    }

    @Test func refusesASymlinkThatPointsOutOfExports() throws {
        let root = try makeExportsRoot()
        let secret = root.deletingLastPathComponent().appendingPathComponent("secret.jpg")
        try Data("x".utf8).write(to: secret)
        let link = root.appendingPathComponent("remote/link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        if case .ok = LocalAPIRemote.checkDownloadPath(link.path, root: root) {
            Issue.record("symlink escaping exports/ was allowed")
        }
    }

    // MARK: - preview sizes

    @Test func previewWidthsSnapUpToACachedSize() {
        #expect(LocalAPIRemote.snappedPreviewSize(nil) == nil)
        #expect(LocalAPIRemote.snappedPreviewSize(0) == nil)
        #expect(LocalAPIRemote.snappedPreviewSize(100) == 256)
        #expect(LocalAPIRemote.snappedPreviewSize(512) == 512)
        #expect(LocalAPIRemote.snappedPreviewSize(513) == 1024)
        #expect(LocalAPIRemote.snappedPreviewSize(99_999) == 2048)
    }
}
