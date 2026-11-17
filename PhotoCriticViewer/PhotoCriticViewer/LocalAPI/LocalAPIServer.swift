import Foundation
import Network

/// A minimal local-only HTTP/1.1 server (no third-party dependency -- built on Network.framework,
/// which ships with the OS) letting an external assistant drive PhotoCriticViewer: list/ingest
/// photos, trigger the real evaluation pipeline, read results, and export deliverables. Every
/// handler calls into the app's existing services (IngestRunner.shared, CurationRunner.shared,
/// PhotoCriticDatabase) rather than reimplementing any of that logic.
///
/// Binds to 127.0.0.1, never 0.0.0.0 -- plus, only when Settings' remote toggle is on, a second
/// listener on this Mac's Tailscale address (see LocalAPIRemote; off by default). Every request except GET /health must carry
/// `Authorization: Bearer <token>` (see LocalAPIAuth). One request per connection -- every
/// response is sent with `Connection: close` -- which keeps the HTTP handling honest and simple
/// for what is, realistically, low-volume local automation traffic, not a public-facing server.
/// @unchecked Sendable: `listener` is only ever mutated from start()/stop(), called from the
/// main actor (AppDelegate, SettingsView) -- never from the request-handling path -- and
/// `isRunning`/`lastError` are plain status flags SettingsView reads for display, where a
/// stale read for one UI refresh is harmless. Same "handed off, not contended" reasoning as
/// PhotoCriticDatabase's @unchecked Sendable elsewhere in this app, which the compiler can't
/// see on its own.
final class LocalAPIServer: @unchecked Sendable {
    static let shared = LocalAPIServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.photocritic.localapi")
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Optional second listener on this Mac's Tailscale address (LocalAPISettings.remoteEnabled).
    /// Same routes, same token; it exists only while the setting is on. Same main-actor-only
    /// mutation rule as `listener`; the retry is dispatched back to main for that reason.
    private var remoteListener: NWListener?
    private var remoteRetry: DispatchWorkItem?
    private(set) var isRemoteRunning = false
    private(set) var remoteError: String?
    private static let remoteRetrySeconds: Double = 30

    private init() {}

    func startIfEnabled() {
        guard LocalAPISettings.isEnabled else { return }
        start()
    }

    func start() {
        defer { startRemoteIfEnabled() }
        guard listener == nil else { return }
        lastError = nil
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(LocalAPISettings.port)) else {
            lastError = "Invalid port \(LocalAPISettings.port)"
            return
        }
        do {
            // The one line that matters for "never 0.0.0.0": pin the listener to the loopback
            // endpoint explicitly rather than trusting a default that could bind every interface.
            listener = try makeListener(host: "127.0.0.1", port: nwPort) { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed(let error):
                    self?.lastError = error.localizedDescription
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        stopRemote()
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Remote (Tailscale) listener

    /// Binds the remote listener if the API and the remote toggle are both on. Never binds
    /// anything outside 100.64.0.0/10, and never a wildcard address. If the address isn't on
    /// this Mac yet (Tailscale still connecting after login/wake), retries every 30s while
    /// the setting stays on rather than giving up until the next relaunch.
    func startRemoteIfEnabled() {
        guard LocalAPISettings.isEnabled, LocalAPISettings.remoteEnabled else { return }
        guard remoteListener == nil else { return }
        remoteRetry?.cancel()
        remoteRetry = nil
        remoteError = nil

        let address = LocalAPISettings.remoteAddress
        guard LocalAPISettings.isTailscaleAddress(address) else {
            remoteError = "\(address) is not a Tailscale address (100.64.0.0/10) — refusing to bind it"
            return
        }
        guard LocalAPIRemote.isAssignedToThisMac(address) else {
            remoteError = "\(address) isn't on this Mac right now — is Tailscale connected? Retrying every 30s."
            scheduleRemoteRetry()
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(LocalAPISettings.port)) else {
            remoteError = "Invalid port \(LocalAPISettings.port)"
            return
        }
        do {
            remoteListener = try makeListener(host: address, port: nwPort) { [weak self] state in
                switch state {
                case .ready:
                    self?.isRemoteRunning = true
                case .failed(let error):
                    self?.isRemoteRunning = false
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.remoteError = "\(error.localizedDescription) — retrying every 30s."
                        self.remoteListener?.cancel()
                        self.remoteListener = nil
                        self.scheduleRemoteRetry()
                    }
                case .cancelled:
                    self?.isRemoteRunning = false
                default:
                    break
                }
            }
        } catch {
            remoteError = error.localizedDescription
            scheduleRemoteRetry()
        }
    }

    func stopRemote() {
        remoteRetry?.cancel()
        remoteRetry = nil
        remoteListener?.cancel()
        remoteListener = nil
        isRemoteRunning = false
        remoteError = nil
    }

    private func scheduleRemoteRetry() {
        let work = DispatchWorkItem { [weak self] in
            self?.remoteRetry = nil
            self?.startRemoteIfEnabled()
        }
        remoteRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.remoteRetrySeconds, execute: work)
    }

    private func makeListener(host: String, port: NWEndpoint.Port, onState: @escaping @Sendable (NWListener.State) -> Void) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = onState
        listener.start(queue: queue)
        return listener
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            // A request body past this size is refused outright rather than accumulated --
            // defensive against a misbehaving client, even though this is local and token-gated.
            if buffer.count > 32 * 1024 * 1024 {
                self.respond(LocalAPIResponse(400, apiErrorBody(code: "payload_too_large", message: "request exceeded 32MB")), on: connection)
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            if let request = HTTPRequestParser.parse(buffer) {
                Task {
                    self.respond(await self.route(request), on: connection)
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func respond(_ response: LocalAPIResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(HTTPStatus.reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var full = Data(head.utf8)
        full.append(response.body)
        connection.send(content: full, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) async -> LocalAPIResponse {
        // Unauthenticated: /health, and the static remote web UI shell (it holds no data --
        // every call it makes afterwards carries the bearer token like any other client).
        let isPublic = request.method == "GET" && ["/health", "/", "/remote"].contains(request.path)
        if !isPublic {
            guard let authHeader = request.headers["authorization"], authHeader.hasPrefix("Bearer ") else {
                return LocalAPIResponse(401, apiErrorBody(code: "unauthorized", message: "missing Authorization: Bearer <token> header"))
            }
            let presented = String(authHeader.dropFirst("Bearer ".count))
            guard LocalAPIAuth.isValid(presented) else {
                return LocalAPIResponse(401, apiErrorBody(code: "unauthorized", message: "invalid token"))
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/remote"):
            return LocalAPIRemote.webUI()
        case ("GET", "/health"):
            return LocalAPIResponse(handleHealth())
        case ("GET", "/openapi.json"):
            return LocalAPIResponse(200, Data(LocalAPIOpenAPISpec.json.utf8))
        case ("POST", "/open"):
            return LocalAPIResponse(await handleOpen(request))
        case ("POST", "/critique"):
            return LocalAPIResponse(await handleCritique(request))
        case ("GET", "/results"):
            return LocalAPIResponse(handleResults(request))
        case ("GET", "/report"):
            return LocalAPIResponse(handleReport(request))
        case ("GET", "/picks"):
            return LocalAPIResponse(handlePicks(request))
        case ("POST", "/posted"):
            return LocalAPIResponse(await handleMarkPosted(request))
        case ("POST", "/export"):
            return LocalAPIResponse(await handleExport(request))
        case ("GET", "/remote/config"):
            return LocalAPIRemote.handleConfig()
        case ("GET", "/shoots"):
            return LocalAPIRemote.handleShoots()
        case ("GET", "/jobs"):
            return await LocalAPIRemote.handleJobList(request)
        case ("GET", "/downloads"):
            return LocalAPIRemote.handleDownload(request)
        default:
            if request.method == "GET", request.path.hasPrefix("/jobs/") {
                return LocalAPIResponse(await handleJobStatus(id: String(request.path.dropFirst("/jobs/".count))))
            }
            if request.method == "GET", request.path.hasPrefix("/results/") {
                guard let id = Int64(request.path.dropFirst("/results/".count)) else {
                    return LocalAPIResponse(400, apiErrorBody(code: "invalid_id", message: "expected an integer file id"))
                }
                return LocalAPIResponse(handleResultDetail(id: id))
            }
            if request.method == "GET", request.path.hasPrefix("/previews/") {
                guard let id = Int64(request.path.dropFirst("/previews/".count)) else {
                    return LocalAPIResponse(400, apiErrorBody(code: "invalid_id", message: "expected an integer file id"))
                }
                return LocalAPIRemote.handlePreview(fileId: id, request: request)
            }
            if request.method == "GET", request.path.hasPrefix("/shoots/"), request.path.hasSuffix("/photos") {
                let middle = request.path.dropFirst("/shoots/".count).dropLast("/photos".count)
                guard let id = Int64(middle) else {
                    return LocalAPIResponse(400, apiErrorBody(code: "invalid_id", message: "expected /shoots/{integer id}/photos"))
                }
                return LocalAPIRemote.handleShootPhotos(shootId: id, request: request)
            }
            return LocalAPIResponse(404, apiErrorBody(code: "not_found", message: "no such endpoint: \(request.method) \(request.path)"))
        }
    }

    // MARK: - GET /health

    private func handleHealth() -> (Int, Data) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return (200, apiJSONBody(["ok": true, "app": "PhotoCriticViewer", "version": version]))
    }

    // MARK: - POST /open

    private func handleOpen(_ request: HTTPRequest) async -> (Int, Data) {
        guard let raw = request.jsonBody?["path"] as? String, !raw.isEmpty else {
            return (400, apiErrorBody(code: "missing_path", message: "body must be {\"path\": \"/abs/file/or/folder\"}"))
        }
        let resolved: URL
        switch LocalAPIPaths.resolve(raw) {
        case .success(let url): resolved = url
        case .failure(let error): return (400, apiErrorBody(code: "invalid_path", message: LocalAPIPaths.errorMessage(for: error, raw: raw)))
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return (400, apiErrorBody(code: "path_not_found", message: "no such file or folder: \(resolved.path)"))
        }
        let folder = isDirectory.boolValue ? resolved : resolved.deletingLastPathComponent()

        guard await MainActor.run(body: { !IngestRunner.shared.isRunning }) else {
            return (409, apiErrorBody(code: "server_busy", message: "another ingest/evaluate job is already running"))
        }

        let finalStatus = await runOrganizeAndWait(folder: folder)
        guard case .finished(_, let success) = finalStatus, success else {
            let tail = await MainActor.run { String(IngestRunner.shared.log.suffix(4000)) }
            return (500, apiErrorBody(code: "organize_failed", message: "organize.py failed; log tail:\n\(tail)"))
        }

        do {
            let db = try PhotoCriticDatabase()
            let allShoots = try db.listShoots()
            let matching = allShoots.filter { $0.folderPath == folder.path || $0.folderPath.hasPrefix(folder.path + "/") }
            var photos: [[String: Any]] = []
            for shoot in matching {
                for item in try db.shootGrid(shootId: shoot.id, sort: .filename) {
                    photos.append(["id": item.fileId, "path": item.fullPath, "filename": item.filename, "shoot_id": shoot.id])
                }
            }
            return (200, apiJSONBody(["shoot_ids": matching.map(\.id), "photos": photos]))
        } catch {
            return (500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
    }

    @MainActor
    private func runOrganizeAndWait(folder: URL) async -> IngestRunner.Status {
        await withCheckedContinuation { continuation in
            IngestRunner.shared.startOrganize(folder: folder) {
                continuation.resume(returning: IngestRunner.shared.status)
            }
        }
    }

    // MARK: - POST /critique

    private enum CritiqueMode {
        case shoot(Int64)
        case files([Int64])

        var paramsDescription: String {
            switch self {
            case .shoot(let id): return "shoot:\(id)"
            case .files(let ids): return "files:\(ids.count)"
            }
        }
    }

    /// Never returns 409: the job is always accepted and queued (LocalAPICritiqueQueue), run in
    /// arrival order once whatever else is using IngestRunner (another critique job, an /open,
    /// or the UI's own buttons) is free.
    private func handleCritique(_ request: HTTPRequest) async -> (Int, Data) {
        let mode: CritiqueMode
        do {
            mode = try await resolveCritiqueMode(for: request)
        } catch let error as LocalAPIHandlerError {
            return (error.status, apiErrorBody(code: error.code, message: error.message))
        } catch {
            return (500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }

        let jobId = await LocalAPIJobStore.shared.create(paramsDescription: mode.paramsDescription)
        await LocalAPICritiqueQueue.shared.enqueue { [weak self] in
            await self?.runCritiqueJob(jobId: jobId, mode: mode)
        }
        return (202, apiJSONBody(["job_id": jobId]))
    }

    /// {"path": "..."} resolves to the shoot at that folder (must already be organized --
    /// evaluation, look detection, and ranking all need an existing shoot to run against; use
    /// /open first for a brand new folder) and evaluates the WHOLE shoot. {"ids": [...]}
    /// evaluates ONLY those files (evaluate.py --files / pipeline.evaluate_specific_files) --
    /// not their whole shoot(s).
    private func resolveCritiqueMode(for request: HTTPRequest) async throws -> CritiqueMode {
        let body = request.jsonBody ?? [:]
        if let raw = body["path"] as? String, !raw.isEmpty {
            guard case .success(let url) = LocalAPIPaths.resolve(raw) else {
                throw LocalAPIHandlerError(status: 400, code: "invalid_path", message: "path must be absolute and inside an allowed root: \(raw)")
            }
            let db = try PhotoCriticDatabase()
            guard let shootId = try db.shootId(forFolderPath: url.path) else {
                throw LocalAPIHandlerError(status: 404, code: "shoot_not_found", message: "no organized shoot at \(url.path) -- call /open on it first")
            }
            return .shoot(shootId)
        }
        if let rawIds = body["ids"] as? [Any] {
            let ids = rawIds.compactMap { ($0 as? NSNumber)?.int64Value }
            guard !ids.isEmpty else {
                throw LocalAPIHandlerError(status: 400, code: "empty_ids", message: "\"ids\" must be a non-empty array of integers")
            }
            return .files(ids)
        }
        throw LocalAPIHandlerError(status: 400, code: "missing_ids_or_path", message: "body must be {\"ids\": [...]} or {\"path\": \"...\"}")
    }

    private func runCritiqueJob(jobId: String, mode: CritiqueMode) async {
        // Wait our turn against IngestRunner -- it's shared with /open and the UI's own
        // Organize/Evaluate buttons, not just other queued critique jobs.
        while await MainActor.run(body: { IngestRunner.shared.isRunning }) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await LocalAPIJobStore.shared.update(jobId, status: .running)

        let pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let stage = IngestRunner.shared.progressStage
                let current = IngestRunner.shared.progressCurrent
                let total = IngestRunner.shared.progressTotal
                await LocalAPIJobStore.shared.update(jobId, stage: stage, current: current, total: total)
            }
        }

        let label: String
        let status: IngestRunner.Status
        switch mode {
        case .shoot(let shootId):
            label = "Evaluating shoot \(shootId)"
            status = await runEvaluateAndWait(shootId: shootId, label: label)
        case .files(let fileIds):
            label = "Evaluating \(fileIds.count) file(s)"
            status = await runEvaluateFilesAndWait(fileIds: fileIds, label: label)
        }
        pollTask.cancel()

        guard case .finished(_, let success) = status, success else {
            let tail = await MainActor.run { String(IngestRunner.shared.log.suffix(4000)) }
            await LocalAPIJobStore.shared.update(jobId, status: .failed, error: "evaluate.py failed; log tail:\n\(tail)")
            return
        }

        do {
            let db = try PhotoCriticDatabase()
            let summary: [String: Any]
            switch mode {
            case .shoot(let shootId):
                let grid = try db.shootGrid(shootId: shootId, sort: .score)
                summary = ["mode": "shoot", "shoot_id": shootId, "files_evaluated": grid.count]
            case .files(let fileIds):
                summary = ["mode": "files", "file_ids": fileIds, "count": fileIds.count]
            }
            await LocalAPIJobStore.shared.update(jobId, status: .done, result: apiJSONBody(summary))
        } catch {
            let fallback = apiJSONBody(["note": "evaluation finished; summary unavailable: \(error.localizedDescription)"])
            await LocalAPIJobStore.shared.update(jobId, status: .done, result: fallback)
        }
    }

    @MainActor
    private func runEvaluateAndWait(shootId: Int64, label: String) async -> IngestRunner.Status {
        await withCheckedContinuation { continuation in
            IngestRunner.shared.startEvaluate(shootId: shootId, shootLabel: label) {
                continuation.resume(returning: IngestRunner.shared.status)
            }
        }
    }

    @MainActor
    private func runEvaluateFilesAndWait(fileIds: [Int64], label: String) async -> IngestRunner.Status {
        await withCheckedContinuation { continuation in
            IngestRunner.shared.startEvaluateFiles(fileIds: fileIds, label: label) {
                continuation.resume(returning: IngestRunner.shared.status)
            }
        }
    }

    // MARK: - GET /jobs/{id}

    private func handleJobStatus(id: String) async -> (Int, Data) {
        guard let job = await LocalAPIJobStore.shared.get(id) else {
            return (404, apiErrorBody(code: "job_not_found", message: "no job with id \(id)"))
        }
        var payload: [String: Any] = ["id": id, "status": job.status.rawValue]
        if let stage = job.stage { payload["stage"] = stage }
        if let current = job.current { payload["current"] = current }
        if let total = job.total { payload["total"] = total }
        if let error = job.error { payload["error"] = error }
        if let resultData = job.result, let resultObject = try? JSONSerialization.jsonObject(with: resultData) {
            payload["result"] = resultObject
        }
        return (200, apiJSONBody(payload))
    }

    // MARK: - GET /results, /results/{id}

    private func handleResults(_ request: HTTPRequest) -> (Int, Data) {
        do {
            let db = try PhotoCriticDatabase()
            let minScore = request.query["min_score"].flatMap(Double.init)
            let limitParam = request.query["limit"].flatMap(Int.init)
            let limit = min(limitParam ?? 200, 2000)
            let sortParam = request.query["sort"] ?? "score_desc"

            let baseSort: SortMode = sortParam == "filename" ? .filename : .score
            var rows = try db.reviewedPhotos(minScore: minScore, sort: baseSort, limit: sortParam == "score_asc" ? nil : limit)
            if sortParam == "score_asc" {
                rows.reverse()
                if rows.count > limit { rows = Array(rows.prefix(limit)) }
            }

            return (200, apiJSONBody(rows.map(reviewedPhotoJSON)))
        } catch {
            return (500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
    }

    private func handleResultDetail(id: Int64) -> (Int, Data) {
        do {
            let db = try PhotoCriticDatabase()
            guard let detail = try db.photoDetail(fileId: id) else {
                return (404, apiErrorBody(code: "not_found", message: "no file with id \(id)"))
            }
            var payload: [String: Any] = ["id": detail.fileId, "filename": detail.filename]
            payload["calibrated_score"] = detail.calibratedScore
            payload["percentile_shoot"] = detail.percentileShoot
            payload["percentile_library"] = detail.percentileLibrary
            if let evaluation = detail.evaluation {
                payload["score"] = evaluation.overallScore
                payload["classification"] = evaluation.classification
                payload["recommendation"] = evaluation.recommendation
                payload["scores"] = Dictionary(uniqueKeysWithValues: evaluation.scores.map { ($0, $1) })
                payload["category_reasons"] = evaluation.categoryReasons
                payload["critique"] = evaluation.reasoning
                payload["strengths"] = evaluation.strengths
                payload["weaknesses"] = evaluation.weaknesses
                payload["technical_issues"] = evaluation.technicalIssues
                payload["artistic_choices"] = evaluation.artisticChoices
                // Caption-writing hints only (lighting/mood/setup/wardrobe), not the full
                // critique -- see evaluation_v4.txt's style_summary field. Empty for a
                // pre-v4 row.
                payload["style_summary"] = evaluation.styleSummary
            }
            let posted = try db.postedPlatforms(fileId: id)
            if !posted.isEmpty {
                payload["posted_to"] = posted.map { ["platform": $0.platform, "posted_at": $0.postedAt] }
            }
            if let technical = detail.technical {
                payload["technical"] = [
                    "sharpness_score": technical.sharpnessScore,
                    "exposure_mean": technical.exposureMean,
                    "highlight_clip_pct": technical.highlightClipPct,
                    "shadow_clip_pct": technical.shadowClipPct,
                    "flags": technical.flags,
                ]
            }
            if let metadata = detail.metadata {
                var metaJSON: [String: Any] = [:]
                if let v = metadata.cameraModel { metaJSON["camera_model"] = v }
                if let v = metadata.lens { metaJSON["lens"] = v }
                if let v = metadata.iso { metaJSON["iso"] = v }
                if let v = metadata.aperture { metaJSON["aperture"] = v }
                if let v = metadata.shutterSpeed { metaJSON["shutter_speed"] = v }
                if let v = metadata.focalLength { metaJSON["focal_length"] = v }
                if let v = metadata.captureTime { metaJSON["capture_time"] = v }
                payload["metadata"] = metaJSON
            }
            if let group = detail.group {
                payload["group"] = ["group_id": group.groupId, "rank": group.rank, "role": group.role as Any, "rationale": group.rationale as Any]
            }
            return (200, apiJSONBody(payload))
        } catch {
            return (500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
    }

    private func decodeEvaluation(_ row: PhotoCriticDatabase.ReviewedPhoto) -> Evaluation? {
        guard let json = row.evaluationJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Evaluation.self, from: data)
    }

    private func reviewedPhotoJSON(_ row: PhotoCriticDatabase.ReviewedPhoto) -> [String: Any] {
        let evaluation = decodeEvaluation(row)
        var tags: [String] = []
        if let classification = row.classification { tags.append(classification) }
        if let recommendation = row.recommendation { tags.append(recommendation) }
        if let look = row.lookName { tags.append(look) }
        if let person = row.personName { tags.append(person) }

        var payload: [String: Any] = [
            "id": row.fileId,
            "shoot_id": row.shootId,
            "path": row.fullPath,
            "filename": row.filename,
            "shoot": row.shootFolderPath,
            "score": row.overallScore,
            "scores": evaluation?.scores ?? [:],
            "tags": tags,
        ]
        payload["calibrated_score"] = row.calibratedScore
        payload["percentile_shoot"] = row.percentileShoot
        payload["percentile_library"] = row.percentileLibrary
        payload["classification"] = row.classification
        payload["recommendation"] = row.recommendation
        payload["critique"] = evaluation?.reasoning
        payload["reviewed_at"] = row.reviewedAt
        return payload
    }

    // MARK: - GET /report

    private func handleReport(_ request: HTTPRequest) -> (Int, Data) {
        do {
            let db = try PhotoCriticDatabase()
            let shootId = request.query["shoot"].flatMap(Int64.init)
            let since = request.query["since"] // ISO date/datetime string, compared lexically against created_at
            let rows = try db.reviewedPhotosForReport(shootId: shootId, since: since)
            guard !rows.isEmpty else {
                return (200, apiJSONBody(["photo_count": 0, "note": "no evaluated photos match this filter"]))
            }

            var categorySums: [String: Double] = [:]
            var categoryCounts: [String: Int] = [:]
            var phraseCounts: [String: Int] = [:]
            for row in rows {
                guard let evaluation = decodeEvaluation(row) else { continue }
                for (category, score) in evaluation.scores {
                    categorySums[category, default: 0] += score
                    categoryCounts[category, default: 0] += 1
                }
                for phrase in evaluation.weaknesses + evaluation.technicalIssues {
                    let normalized = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    phraseCounts[normalized, default: 0] += 1
                }
            }
            let categoryMeans = Evaluation.scoreOrder.compactMap { category -> (String, Double)? in
                guard let sum = categorySums[category], let count = categoryCounts[category], count > 0 else { return nil }
                return (category, sum / Double(count))
            }
            let ascending = categoryMeans.sorted { $0.1 < $1.1 }
            let weakest = Array(ascending.prefix(5))
            let strongest = Array(ascending.suffix(5).reversed())

            let byScoreDesc = rows.sorted { ($0.calibratedScore ?? $0.overallScore) > ($1.calibratedScore ?? $1.overallScore) }
            let best = Array(byScoreDesc.prefix(10))
            let worst = Array(byScoreDesc.suffix(min(10, byScoreDesc.count)).reversed())

            var monthSums: [String: Double] = [:], monthCounts: [String: Int] = [:]
            var shootSums: [String: Double] = [:], shootCounts: [String: Int] = [:]
            for row in rows {
                if let reviewedAt = row.reviewedAt, reviewedAt.count >= 7 {
                    let month = String(reviewedAt.prefix(7))
                    monthSums[month, default: 0] += row.overallScore
                    monthCounts[month, default: 0] += 1
                }
                shootSums[row.shootFolderPath, default: 0] += row.overallScore
                shootCounts[row.shootFolderPath, default: 0] += 1
            }
            let trendByMonth = monthSums.keys.sorted().map { month -> [String: Any] in
                ["month": month, "mean_score": round((monthSums[month]! / Double(monthCounts[month]!)) * 10) / 10, "count": monthCounts[month]!]
            }
            let trendByShoot = shootSums.keys.sorted().map { shoot -> [String: Any] in
                ["shoot": shoot, "mean_score": round((shootSums[shoot]! / Double(shootCounts[shoot]!)) * 10) / 10, "count": shootCounts[shoot]!]
            }
            let recurringIssues = phraseCounts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(10)
                .map { ["issue": $0.key, "count": $0.value] }

            let payload: [String: Any] = [
                "photo_count": rows.count,
                "strongest_categories": strongest.map { ["category": $0.0, "mean": round($0.1 * 100) / 100] },
                "weakest_categories": weakest.map { ["category": $0.0, "mean": round($0.1 * 100) / 100] },
                "trend_by_month": trendByMonth,
                "trend_by_shoot": trendByShoot,
                "recurring_issues": recurringIssues,
                "best_photos": best.map { self.bestWorstJSON($0, weakest: false) },
                "weakest_photos": worst.map { self.bestWorstJSON($0, weakest: true) },
                "things_to_practice": weakest.compactMap { Self.coachingTip(for: $0.0) },
            ]
            return (200, apiJSONBody(payload))
        } catch {
            return (500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
    }

    private func bestWorstJSON(_ row: PhotoCriticDatabase.ReviewedPhoto, weakest: Bool) -> [String: Any] {
        let evaluation = decodeEvaluation(row)
        let reason = weakest
            ? (evaluation?.distinguishingWeakness ?? evaluation?.reasoning ?? "")
            : (evaluation?.distinguishingStrength ?? evaluation?.reasoning ?? "")
        return [
            "id": row.fileId, "filename": row.filename, "shoot": row.shootFolderPath,
            "score": row.overallScore, "calibrated_score": row.calibratedScore as Any,
            "reason": reason,
        ]
    }

    private static func coachingTip(for category: String) -> String? {
        [
            "composition": "Practice deliberate cropping and negative space — review frames for awkward edge cuts before the shoot ends.",
            "subject": "Work on subject engagement and presence — direct more actively between frames rather than shooting through a pose.",
            "lighting": "Work on light direction and ratio — try a more deliberate key/fill relationship and check modeling on the face before shooting a full set.",
            "exposure": "Meter more precisely for the specific scene's dynamic range rather than a general setting.",
            "focus": "Double-check focus on the eyes/intended plane at wider apertures, especially during movement.",
            "expression": "Direct for more specific, varied expressions rather than one safe look — expression tends to vary the most, so a few extra beats of direction per setup should pay off.",
            "pose": "Work on hand placement and body angles — plan 2-3 specific poses per setup rather than improvising throughout.",
            "background": "Work on background separation — wider aperture, more subject-to-background distance, or a cleaner backdrop.",
            "color_tonality": "Refine the color grade and skin-tone accuracy in post — a consistent LUT/preset may help.",
            "emotional_impact": "Push for a genuine emotional beat per setup, not just a technically clean frame.",
            "visual_hierarchy": "Check where the eye lands first on review — simplify competing elements in-frame.",
            "professional_polish": "Review for small technical distractions (stray hairs, dust, visible equipment) before calling a setup done.",
            "client_delivery_value": "Ask, for each setup: would a client pay extra for this one? If not, adjust before moving on.",
        ][category]
    }

    // MARK: - GET /picks

    private func handlePicks(_ request: HTTPRequest) -> (Int, Data) {
        do {
            let db = try PhotoCriticDatabase()
            let minPercentile = request.query["min_percentile"].flatMap(Double.init)
            let grade = request.query["grade"]
            let notPosted = request.query["not_posted"] == "true"
            let limit = request.query["limit"].flatMap(Int.init).map { min($0, 2000) }
            let rows = try db.picks(minPercentile: minPercentile, grade: grade, notPostedOnly: notPosted, limit: limit)
            return (200, apiJSONBody(rows.map(reviewedPhotoJSON)))
        } catch {
            return (500, apiErrorBody(code: "db_error", message: error.localizedDescription))
        }
    }

    // MARK: - POST /posted

    private func handleMarkPosted(_ request: HTTPRequest) async -> (Int, Data) {
        guard let body = request.jsonBody, let fileId = (body["id"] as? NSNumber)?.int64Value else {
            return (400, apiErrorBody(code: "missing_id", message: "body must include an integer \"id\""))
        }
        guard let platform = body["platform"] as? String, !platform.isEmpty else {
            return (400, apiErrorBody(code: "missing_platform", message: "body must include \"platform\" (e.g. instagram, modelmayhem, inpose, portfolio)"))
        }
        guard await MainActor.run(body: { !CurationRunner.shared.isRunning }) else {
            return (409, apiErrorBody(code: "server_busy", message: "another curation/export job is already running"))
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CurationRunner.ActionResult, Never>) in
            Task { @MainActor in
                CurationRunner.shared.markPosted(fileId: fileId, platform: platform) { result in
                    continuation.resume(returning: result)
                }
            }
        }
        guard result.success else {
            return (500, apiErrorBody(code: "mark_posted_failed", message: result.output))
        }
        return (200, apiJSONBody(["id": fileId, "platform": platform, "posted": true]))
    }

    // MARK: - POST /export

    /// Two stages: export_photo.py decodes each RAW to a full-resolution JPEG intermediate
    /// (the only part that needs Python/rawpy) and handles EXIF; LocalAPIExportProcessor then
    /// does the subject-aware crop, resize, sRGB, and optional watermark in Swift (needs
    /// Vision, which has no Python-side equivalent here), writing the final file to `dest`.
    private func handleExport(_ request: HTTPRequest) async -> (Int, Data) {
        guard let body = request.jsonBody else {
            return (400, apiErrorBody(code: "invalid_json", message: "body must be JSON"))
        }
        guard let rawIds = body["ids"] as? [Any], !rawIds.isEmpty else {
            return (400, apiErrorBody(code: "missing_ids", message: "body must include a non-empty \"ids\" array"))
        }
        let ids = rawIds.compactMap { ($0 as? NSNumber)?.int64Value }
        guard ids.count == rawIds.count else {
            return (400, apiErrorBody(code: "invalid_ids", message: "\"ids\" must all be integers"))
        }
        guard let rawDest = body["dest"] as? String, !rawDest.isEmpty else {
            return (400, apiErrorBody(code: "missing_dest", message: "body must include \"dest\": \"/abs/folder\""))
        }
        let dest: URL
        switch LocalAPIPaths.resolve(rawDest) {
        case .success(let url): dest = url
        case .failure(let error): return (400, apiErrorBody(code: "invalid_path", message: LocalAPIPaths.errorMessage(for: error, raw: rawDest)))
        }
        let preset = (body["preset"] as? String) ?? "original"
        guard LocalAPIExportProcessor.presets[preset] != nil else {
            return (400, apiErrorBody(code: "invalid_preset", message: "preset must be one of \(LocalAPIExportProcessor.presets.keys.sorted())"))
        }
        let longEdge = (body["long_edge"] as? NSNumber)?.intValue
        let quality = (body["quality"] as? NSNumber)?.intValue
        if let quality, !(1...100).contains(quality) {
            return (400, apiErrorBody(code: "invalid_params", message: "quality must be 1-100"))
        }
        var cropOffset: CGPoint?
        if let rawOffset = body["crop_offset"] as? [String: Any] {
            guard let x = (rawOffset["x"] as? NSNumber)?.doubleValue, let y = (rawOffset["y"] as? NSNumber)?.doubleValue,
                  (0...1).contains(x), (0...1).contains(y) else {
                return (400, apiErrorBody(code: "invalid_crop_offset", message: "crop_offset must be {\"x\": 0-1, \"y\": 0-1}"))
            }
            cropOffset = CGPoint(x: x, y: y)
        }
        let watermarkText = body["watermark"] as? String

        // Only created once the busy check below passes -- never left behind for a request
        // that got rejected.
        guard await MainActor.run(body: { !CurationRunner.shared.isRunning }) else {
            return (409, apiErrorBody(code: "server_busy", message: "another curation/export job is already running"))
        }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let intermediateDir = WorkspaceConfig.root.appendingPathComponent("cache/export_intermediate")
        let decodeResult = await runDecodeIntermediatesAndWait(fileIds: ids, outDir: intermediateDir)
        guard let decodeData = decodeResult.output.data(using: .utf8),
              let decodeParsed = try? JSONSerialization.jsonObject(with: decodeData) as? [String: Any],
              let decodeResults = decodeParsed["results"] as? [[String: Any]] else {
            return (500, apiErrorBody(code: "export_failed", message: "export_photo.py produced no usable output: \(decodeResult.output.suffix(2000))"))
        }

        let filenames = (try? PhotoCriticDatabase().filenames(forFileIds: ids)) ?? [:]
        var results: [[String: Any]] = []
        for entry in decodeResults {
            guard let fileId = (entry["file_id"] as? NSNumber)?.int64Value else { continue }
            guard let intermediatePath = entry["intermediate_path"] as? String else {
                results.append(["file_id": fileId, "error": entry["error"] as? String ?? "decode failed"])
                continue
            }
            let stem = ((filenames[fileId] ?? "\(fileId)") as NSString).deletingPathExtension
            let finalURL = dest.appendingPathComponent("\(stem)_\(preset).jpg")
            do {
                let options = LocalAPIExportProcessor.Options(
                    preset: preset, longEdge: longEdge, quality: quality, cropOffset: cropOffset, watermarkText: watermarkText
                )
                try LocalAPIExportProcessor.finish(intermediatePath: intermediatePath, options: options, finalURL: finalURL)
                results.append(["file_id": fileId, "path": finalURL.path])
            } catch {
                results.append(["file_id": fileId, "error": error.localizedDescription])
            }
        }

        let failed = results.filter { $0["error"] != nil }.count
        return (200, apiJSONBody(["results": results, "exported": results.count - failed, "failed": failed]))
    }

    @MainActor
    private func runDecodeIntermediatesAndWait(fileIds: [Int64], outDir: URL) async -> CurationRunner.ActionResult {
        await withCheckedContinuation { continuation in
            CurationRunner.shared.decodeExportIntermediates(fileIds: fileIds, outDir: outDir, keepGPS: false) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

struct LocalAPIHandlerError: Error {
    let status: Int
    let code: String
    let message: String
}
