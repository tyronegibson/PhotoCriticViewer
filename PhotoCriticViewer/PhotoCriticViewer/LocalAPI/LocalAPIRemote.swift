import Foundation
import ImageIO
import UniformTypeIdentifiers

/// V1.5 Phase 1 -- iPhone remote. The endpoints a phone (the bundled web UI today, a SwiftUI
/// iPhone app later) needs on top of the existing control API: browse shoots, page through a
/// shoot's photos, fetch previews sized for a phone, list jobs, and download a finished export.
///
/// Nothing here serves a RAW. Previews come from the workspace's already-rendered JPEGs, and
/// /downloads only serves image derivatives from `<workspace>/exports`. Every endpoint is
/// read-only against photocritic.db (Python stays the sole writer) and sits behind the same
/// bearer token as the rest of the API; only the static web UI shell is served without one.
///
/// Reachable from the tailnet only when Settings' remote toggle binds the second listener (see
/// LocalAPIServer.startRemoteIfEnabled); otherwise these are just more 127.0.0.1 routes.
enum LocalAPIRemote {

    // MARK: - Interface check

    /// True if `address` is currently an IPv4 address on one of this Mac's interfaces, so the
    /// remote listener can explain "Tailscale isn't connected" instead of a bare bind error.
    static func isAssignedToThisMac(_ address: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil,
               String(cString: buffer) == address {
                return true
            }
        }
        return false
    }

    // MARK: - GET / (web UI)

    static func webUI() -> LocalAPIResponse {
        LocalAPIResponse(200, Data(LocalAPIWebUI.html.utf8), contentType: "text/html; charset=utf-8", headers: [
            // The page only ever talks to this same origin; blob: is how authorized image
            // fetches become <img> sources (an <img src> can't carry a bearer header).
            "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
        ])
    }

    // MARK: - GET /remote/config

    /// What a remote client needs to build requests without hardcoding Mac paths: where its
    /// exports should go (inside the allowlisted workspace) and which presets /export takes.
    static func handleConfig() -> LocalAPIResponse {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return LocalAPIResponse(200, apiJSONBody([
            "app_version": version,
            "remote_exports_dir": exportsRoot.appendingPathComponent("remote").path,
            "export_presets": LocalAPIExportProcessor.presets.keys.sorted(),
            "preview_sizes": previewSizes,
        ]))
    }

    // MARK: - GET /shoots

    static func handleShoots() -> LocalAPIResponse {
        do {
            let shoots = try PhotoCriticDatabase().listShoots().sorted { $0.id > $1.id }
            let payload: [[String: Any]] = shoots.map { shoot in
                let parent = ((shoot.folderPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return [
                    "id": shoot.id,
                    "name": shoot.displayName,
                    "parent": parent,
                    "folder_path": shoot.folderPath,
                    "total_files": shoot.totalFiles,
                    "evaluated": shoot.evaluatedCount,
                    "keep": shoot.keepCount,
                    "maybe": shoot.maybeCount,
                    "reject": shoot.rejectCount,
                ]
            }
            return LocalAPIResponse(200, apiJSONBody(payload))
        } catch {
            return LocalAPIResponse(500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
    }

    // MARK: - GET /shoots/{id}/photos

    /// `?sort=score|filename` (default score), optional `?recommendation=KEEP|MAYBE|REJECT`.
    static func handleShootPhotos(shootId: Int64, request: HTTPRequest) -> LocalAPIResponse {
        let sort: SortMode = request.query["sort"] == "filename" ? .filename : .score
        let filter = request.query["recommendation"]?.uppercased()
        do {
            var items = try PhotoCriticDatabase().shootGrid(shootId: shootId, sort: sort)
            if let filter, !filter.isEmpty {
                items = items.filter { ($0.recommendation ?? "").uppercased() == filter }
            }
            let payload: [[String: Any]] = items.map { item in
                var row: [String: Any] = [
                    "id": item.fileId,
                    "filename": item.filename,
                    "has_preview": item.previewPath != nil,
                ]
                if let v = item.overallScore { row["score"] = v }
                if let v = item.classification { row["classification"] = v }
                if let v = item.recommendation { row["recommendation"] = v }
                if let v = item.groupId { row["group_id"] = v }
                if let v = item.groupRank { row["group_rank"] = v }
                if let v = item.groupRole { row["group_role"] = v }
                if let v = item.lookName { row["look"] = v }
                if let v = item.personName { row["person"] = v }
                return row
            }
            return LocalAPIResponse(200, apiJSONBody(payload))
        } catch {
            return LocalAPIResponse(500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
    }

    // MARK: - GET /previews/{id}

    /// Long-edge sizes a caller can ask for with `?w=`; a request is snapped UP to the nearest
    /// one so the on-disk thumbnail cache stays a handful of files per photo, not one per pixel width.
    static let previewSizes = [256, 512, 1024, 2048]

    static func snappedPreviewSize(_ requested: Int?) -> Int? {
        guard let requested, requested > 0 else { return nil }
        return previewSizes.first { $0 >= requested } ?? previewSizes.last
    }

    /// The workspace preview JPEG (already a downsized render, never the RAW), or with `?w=` a
    /// smaller JPEG cached under `<workspace>/cache/remote_thumbs`.
    static func handlePreview(fileId: Int64, request: HTTPRequest) -> LocalAPIResponse {
        let previewPath: String?
        do {
            previewPath = try PhotoCriticDatabase().previewPath(fileId: fileId)
        } catch {
            return LocalAPIResponse(500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
        guard let previewPath else {
            return LocalAPIResponse(404, apiErrorBody(code: "no_preview", message: "file \(fileId) has no preview"))
        }
        let source = WorkspaceConfig.previewURL(forPreviewPath: previewPath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return LocalAPIResponse(404, apiErrorBody(code: "no_preview", message: "preview for file \(fileId) is missing on disk"))
        }
        let cacheHeaders = ["Cache-Control": "private, max-age=3600"]

        guard let size = snappedPreviewSize(request.query["w"].flatMap(Int.init)) else {
            guard let data = try? Data(contentsOf: source) else {
                return LocalAPIResponse(500, apiErrorBody(code: "read_failed", message: "could not read preview for file \(fileId)"))
            }
            return LocalAPIResponse(200, data, contentType: "image/jpeg", headers: cacheHeaders)
        }

        let cacheDir = WorkspaceConfig.root.appendingPathComponent("cache/remote_thumbs")
        let cached = cacheDir.appendingPathComponent("\(fileId)_w\(size).jpg")
        if isFresh(cached, comparedTo: source), let data = try? Data(contentsOf: cached) {
            return LocalAPIResponse(200, data, contentType: "image/jpeg", headers: cacheHeaders)
        }
        guard let data = makeThumbnail(from: source, maxPixelSize: size) else {
            return LocalAPIResponse(500, apiErrorBody(code: "thumbnail_failed", message: "could not resize preview for file \(fileId)"))
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return LocalAPIResponse(200, data, contentType: "image/jpeg", headers: cacheHeaders)
    }

    private static func isFresh(_ cached: URL, comparedTo source: URL) -> Bool {
        let fm = FileManager.default
        guard let cachedDate = (try? fm.attributesOfItem(atPath: cached.path))?[.modificationDate] as? Date,
              let sourceDate = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date else {
            return false
        }
        return cachedDate >= sourceDate
    }

    static func makeThumbnail(from source: URL, maxPixelSize: Int) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - GET /jobs

    static func handleJobList(_ request: HTTPRequest) async -> LocalAPIResponse {
        let limit = min(max(request.query["limit"].flatMap(Int.init) ?? 50, 1), 200)
        let jobs = await LocalAPIJobStore.shared.list(limit: limit)
        let payload: [[String: Any]] = jobs.map { job in
            var row: [String: Any] = ["id": job.id, "status": job.status.rawValue, "created_at": job.createdAt]
            if let v = job.params { row["params"] = v }
            if let v = job.stage { row["stage"] = v }
            if let v = job.current { row["current"] = v }
            if let v = job.total { row["total"] = v }
            if let v = job.error { row["error"] = v }
            if let data = job.result, let object = try? JSONSerialization.jsonObject(with: data) { row["result"] = object }
            return row
        }
        return LocalAPIResponse(200, apiJSONBody(payload))
    }

    // MARK: - GET /downloads?path=

    /// Image types a finished export can be. Anything else -- RAWs above all -- is refused.
    static let downloadableExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "webp", "heic"]
    static let maxDownloadBytes = 200 * 1024 * 1024

    static var exportsRoot: URL {
        WorkspaceConfig.root.appendingPathComponent("exports")
    }

    enum DownloadCheck: Equatable {
        case ok(URL)
        case refused(String)
    }

    /// Pure path policy for /downloads (unit-tested): must be absolute, resolve (symlinks
    /// included) to somewhere inside `root`, and carry an image extension.
    static func checkDownloadPath(_ raw: String, root: URL) -> DownloadCheck {
        guard raw.hasPrefix("/") else { return .refused("path must be absolute") }
        let resolved = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(rootPath + "/") else {
            return .refused("only files under \(rootPath) can be downloaded")
        }
        guard downloadableExtensions.contains(resolved.pathExtension.lowercased()) else {
            return .refused("only exported images (\(downloadableExtensions.sorted().joined(separator: ", "))) can be downloaded")
        }
        return .ok(resolved)
    }

    static func handleDownload(_ request: HTTPRequest) -> LocalAPIResponse {
        guard let raw = request.query["path"], !raw.isEmpty else {
            return LocalAPIResponse(400, apiErrorBody(code: "missing_path", message: "expected ?path=/abs/path/to/export.jpg"))
        }
        let url: URL
        switch checkDownloadPath(raw, root: exportsRoot) {
        case .ok(let resolved): url = resolved
        case .refused(let reason): return LocalAPIResponse(403, apiErrorBody(code: "forbidden_path", message: reason))
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int else {
            return LocalAPIResponse(404, apiErrorBody(code: "not_found", message: "no such file: \(url.path)"))
        }
        guard size <= maxDownloadBytes else {
            return LocalAPIResponse(400, apiErrorBody(code: "too_large", message: "file is \(size / 1_048_576)MB; the limit is \(maxDownloadBytes / 1_048_576)MB"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return LocalAPIResponse(500, apiErrorBody(code: "read_failed", message: "could not read \(url.path)"))
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let safeName = url.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        return LocalAPIResponse(200, data, contentType: type, headers: [
            "Content-Disposition": "attachment; filename=\"\(safeName)\"",
            "Cache-Control": "private, no-cache",
        ])
    }
}
