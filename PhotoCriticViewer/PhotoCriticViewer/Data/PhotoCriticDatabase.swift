import Foundation

/// High-level, read-only queries mirroring photocritic/db.py's query helpers.
/// Keep the SQL here in sync with that file if the schema changes.
///
/// @unchecked Sendable: ContentView opens one inside a Task.detached (so the blocking
/// SQLite open/query doesn't run on the main actor) and then hands it to @State for
/// exclusively main-actor use afterward — never touched from two threads at once, just
/// handed off once, which the compiler can't see on its own.
final class PhotoCriticDatabase: @unchecked Sendable {
    private let conn: SQLiteConnection

    init() throws {
        conn = try SQLiteConnection(path: WorkspaceConfig.databasePath.path)
    }

    /// A file can carry more than one ai_evaluations row (one per model/prompt
    /// version, e.g. after a re-evaluation with a tuned prompt); this CTE keeps
    /// only the most recent row per file so joins against it don't fan out.
    /// Keep in sync with photocritic/db.py's `_LATEST_AE_CTE`.
    private static let latestAECTE = """
        latest_ae AS (
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY file_id ORDER BY created_at DESC, id DESC
                ) AS rn
                FROM ai_evaluations
            ) WHERE rn = 1
        )
        """

    // MARK: - Shoots

    func listShoots() throws -> [ShootSummary] {
        var results: [ShootSummary] = []
        try conn.query("""
            WITH \(Self.latestAECTE)
            SELECT s.id, s.folder_path, s.separate_people,
                   COUNT(DISTINCT f.id) AS total_files,
                   COUNT(DISTINCT ae.file_id) AS evaluated_count,
                   SUM(CASE WHEN ae.recommendation = 'KEEP' THEN 1 ELSE 0 END) AS keep_count,
                   SUM(CASE WHEN ae.recommendation = 'MAYBE' THEN 1 ELSE 0 END) AS maybe_count,
                   SUM(CASE WHEN ae.recommendation = 'REJECT' THEN 1 ELSE 0 END) AS reject_count
            FROM shoots s
            LEFT JOIN files f ON f.shoot_id = s.id
            LEFT JOIN latest_ae ae ON ae.file_id = f.id
            GROUP BY s.id
            """) { row in
            results.append(ShootSummary(
                id: row.int64(0),
                folderPath: row.text(1) ?? "",
                totalFiles: row.intOpt(3) ?? 0,
                evaluatedCount: row.intOpt(4) ?? 0,
                keepCount: row.intOpt(5) ?? 0,
                maybeCount: row.intOpt(6) ?? 0,
                rejectCount: row.intOpt(7) ?? 0,
                separatePeople: (row.intOpt(2) ?? 0) != 0,
                sampleFilePaths: []
            ))
        }
        // Spread samples per shoot in one query, then attach them to the summaries above.
        var samplesByShoot: [Int64: [String]] = [:]
        try conn.query("""
            WITH numbered AS (
                SELECT shoot_id, full_path,
                       ROW_NUMBER() OVER (PARTITION BY shoot_id ORDER BY id) AS rn,
                       COUNT(*) OVER (PARTITION BY shoot_id) AS n
                FROM files
            )
            SELECT shoot_id, full_path FROM numbered
            WHERE rn IN (1, (n + 3) / 4, (n + 1) / 2, (3 * n + 3) / 4, n)
            """) { row in
            samplesByShoot[row.int64(0), default: []].append(row.text(1) ?? "")
        }
        results = results.map { summary in
            ShootSummary(
                id: summary.id, folderPath: summary.folderPath, totalFiles: summary.totalFiles,
                evaluatedCount: summary.evaluatedCount, keepCount: summary.keepCount,
                maybeCount: summary.maybeCount, rejectCount: summary.rejectCount,
                separatePeople: summary.separatePeople,
                sampleFilePaths: samplesByShoot[summary.id] ?? []
            )
        }
        results.sort { a, b in
            let aDated = Self.isDateName(a.displayName)
            let bDated = Self.isDateName(b.displayName)
            if aDated != bDated { return aDated }
            if aDated { return a.displayName > b.displayName }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        return results
    }

    /// Matches shoot folder names produced by the date-split ingest (YYYY-MM-DD).
    private static let dateNameRegex = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")

    private static func isDateName(_ name: String) -> Bool {
        dateNameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Exact match against shoots.folder_path -- used by the local API's /open to tell an
    /// already-organized folder from a brand new one before deciding whether organize.py
    /// needs to run.
    func shootId(forFolderPath path: String) throws -> Int64? {
        var result: Int64?
        try conn.query("SELECT id FROM shoots WHERE folder_path = ?", bind: [path]) { row in
            result = row.int64(0)
        }
        return result
    }

    // MARK: - Grid

    func shootGrid(shootId: Int64, sort: SortMode) throws -> [PhotoGridItem] {
        let orderBy = sort == .filename ? "f.filename ASC" : "ae.overall_score DESC"
        var results: [PhotoGridItem] = []
        try conn.query("""
            WITH \(Self.latestAECTE)
            SELECT f.id AS file_id, f.filename, f.full_path, ta.preview_path,
                   ae.overall_score, ae.classification, ae.recommendation,
                   sgm.group_id, r.rank AS group_rank, r.role AS group_role, sg.is_composite,
                   lk.id AS look_id, lk.name AS look_name,
                   pp.id AS person_id, pp.name AS person_name
            FROM files f
            LEFT JOIN technical_analysis ta ON ta.file_id = f.id
            LEFT JOIN latest_ae ae ON ae.file_id = f.id
            LEFT JOIN similarity_group_members sgm ON sgm.file_id = f.id
            LEFT JOIN similarity_groups sg ON sg.id = sgm.group_id
            LEFT JOIN rankings r ON r.file_id = f.id AND r.group_id = sgm.group_id
            LEFT JOIN looks lk ON lk.id = (
                SELECT id FROM looks
                WHERE shoot_id = f.shoot_id AND start_filename <= f.filename
                ORDER BY start_filename DESC LIMIT 1
            )
            LEFT JOIN people pp ON pp.id = (
                SELECT id FROM people
                WHERE shoot_id = f.shoot_id AND start_filename <= f.filename
                ORDER BY start_filename DESC LIMIT 1
            )
            WHERE f.shoot_id = ?
            ORDER BY \(orderBy)
            """, bind: [shootId]) { row in
            results.append(PhotoGridItem(
                fileId: row.int64(0),
                filename: row.text(1) ?? "",
                fullPath: row.text(2) ?? "",
                previewPath: row.text(3),
                overallScore: row.doubleOpt(4),
                classification: row.text(5),
                recommendation: row.text(6),
                groupId: row.int64Opt(7),
                groupRank: row.intOpt(8),
                groupRole: row.text(9),
                groupIsComposite: (row.intOpt(10) ?? 0) != 0,
                lookId: row.int64Opt(11),
                lookName: row.text(12),
                personId: row.int64Opt(13),
                personName: row.text(14)
            ))
        }
        return results
    }

    func listLooks(shootId: Int64) throws -> [Look] {
        var results: [Look] = []
        try conn.query(
            "SELECT id, name, start_filename FROM looks WHERE shoot_id = ? ORDER BY start_filename ASC",
            bind: [shootId]
        ) { row in
            results.append(Look(id: row.int64(0), name: row.text(1) ?? "", startFilename: row.text(2) ?? ""))
        }
        return results
    }

    func listPeople(shootId: Int64) throws -> [Person] {
        var results: [Person] = []
        try conn.query(
            "SELECT id, name, start_filename FROM people WHERE shoot_id = ? ORDER BY start_filename ASC",
            bind: [shootId]
        ) { row in
            results.append(Person(id: row.int64(0), name: row.text(1) ?? "", startFilename: row.text(2) ?? ""))
        }
        return results
    }

    // MARK: - Photo detail

    func photoDetail(fileId: Int64) throws -> PhotoDetail? {
        var filename: String?
        try conn.query("SELECT filename FROM files WHERE id = ?", bind: [fileId]) { row in
            filename = row.text(0)
        }
        guard let filename else { return nil }

        var evaluation: Evaluation?
        var calibratedScore: Double?
        var percentileShoot: Double?
        var percentileLibrary: Double?
        try conn.query("""
            SELECT evaluation_json, calibrated_score, percentile_shoot, percentile_library
            FROM ai_evaluations WHERE file_id = ? ORDER BY created_at DESC, id DESC LIMIT 1
            """, bind: [fileId]
        ) { row in
            if let json = row.text(0), let data = json.data(using: .utf8) {
                evaluation = try? JSONDecoder().decode(Evaluation.self, from: data)
            }
            calibratedScore = row.doubleOpt(1)
            percentileShoot = row.doubleOpt(2)
            percentileLibrary = row.doubleOpt(3)
        }

        var technical: TechnicalInfo?
        try conn.query("""
            SELECT sharpness_score, exposure_mean, highlight_clip_pct, shadow_clip_pct, flags_json, preview_path
            FROM technical_analysis WHERE file_id = ?
            """, bind: [fileId]) { row in
            var flags: [String] = []
            if let flagsJson = row.text(4), let data = flagsJson.data(using: .utf8) {
                flags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            }
            technical = TechnicalInfo(
                sharpnessScore: row.doubleOpt(0) ?? 0,
                exposureMean: row.doubleOpt(1) ?? 0,
                highlightClipPct: row.doubleOpt(2) ?? 0,
                shadowClipPct: row.doubleOpt(3) ?? 0,
                flags: flags,
                previewPath: row.text(5)
            )
        }

        var metadata: PhotoMetadata?
        try conn.query("""
            SELECT camera_model, lens, iso, aperture, shutter_speed, focal_length, capture_time
            FROM metadata WHERE file_id = ?
            """, bind: [fileId]) { row in
            metadata = PhotoMetadata(
                cameraModel: row.text(0), lens: row.text(1), iso: row.intOpt(2),
                aperture: row.text(3), shutterSpeed: row.text(4),
                focalLength: row.text(5), captureTime: row.text(6)
            )
        }

        var group: GroupMembership?
        try conn.query("""
            SELECT sgm.group_id, r.rank, r.role, r.rationale
            FROM similarity_group_members sgm
            LEFT JOIN rankings r ON r.group_id = sgm.group_id AND r.file_id = sgm.file_id
            WHERE sgm.file_id = ?
            """, bind: [fileId]) { row in
            group = GroupMembership(
                groupId: row.int64(0),
                rank: row.intOpt(1) ?? 0,
                role: row.text(2),
                rationale: row.text(3)
            )
        }

        return PhotoDetail(fileId: fileId, filename: filename, evaluation: evaluation,
                            technical: technical, metadata: metadata, group: group,
                            calibratedScore: calibratedScore, percentileShoot: percentileShoot,
                            percentileLibrary: percentileLibrary)
    }

    // MARK: - Local API: global results

    /// A row shape for the local API's GET /results -- deliberately not PhotoGridItem (that's
    /// shoot-scoped and UI-facing). Carries the full evaluation JSON (for per-category scores
    /// and the critique text) and the evaluation's timestamp, which the grid view doesn't need.
    struct ReviewedPhoto {
        let fileId: Int64
        let shootId: Int64
        let filename: String
        let fullPath: String
        let shootFolderPath: String
        let overallScore: Double
        let calibratedScore: Double?
        let percentileShoot: Double?
        let percentileLibrary: Double?
        let classification: String?
        let recommendation: String?
        let evaluationJSON: String?
        let reviewedAt: String?
        let lookName: String?
        let personName: String?
    }

    private static let reviewedPhotoSelect = """
        SELECT f.id AS file_id, f.shoot_id, f.filename, f.full_path, s.folder_path,
               ae.overall_score, ae.calibrated_score, ae.percentile_shoot, ae.percentile_library,
               ae.classification, ae.recommendation, ae.evaluation_json, ae.created_at,
               lk.name AS look_name, pp.name AS person_name
        FROM files f
        JOIN shoots s ON s.id = f.shoot_id
        JOIN latest_ae ae ON ae.file_id = f.id
        LEFT JOIN looks lk ON lk.id = (
            SELECT id FROM looks
            WHERE shoot_id = f.shoot_id AND start_filename <= f.filename
            ORDER BY start_filename DESC LIMIT 1
        )
        LEFT JOIN people pp ON pp.id = (
            SELECT id FROM people
            WHERE shoot_id = f.shoot_id AND start_filename <= f.filename
            ORDER BY start_filename DESC LIMIT 1
        )
        """

    private static func reviewedPhoto(from row: SQLiteConnection.Row) -> ReviewedPhoto {
        ReviewedPhoto(
            fileId: row.int64(0),
            shootId: row.int64(1),
            filename: row.text(2) ?? "",
            fullPath: row.text(3) ?? "",
            shootFolderPath: row.text(4) ?? "",
            overallScore: row.doubleOpt(5) ?? 0,
            calibratedScore: row.doubleOpt(6),
            percentileShoot: row.doubleOpt(7),
            percentileLibrary: row.doubleOpt(8),
            classification: row.text(9),
            recommendation: row.text(10),
            evaluationJSON: row.text(11),
            reviewedAt: row.text(12),
            lookName: row.text(13),
            personName: row.text(14)
        )
    }

    /// Every evaluated photo across all shoots (ae.overall_score IS NOT NULL), optionally
    /// filtered by a minimum score, for the local API. Unevaluated photos are left out --
    /// "reviewed photos" in the spec means photos the model has actually scored.
    func reviewedPhotos(minScore: Double?, sort: SortMode, limit: Int?) throws -> [ReviewedPhoto] {
        let orderBy = sort == .filename ? "f.filename ASC" : "ae.overall_score DESC"
        var sql = "WITH \(Self.latestAECTE)\n" + Self.reviewedPhotoSelect + " WHERE ae.overall_score IS NOT NULL"
        var bind: [Any?] = []
        if let minScore {
            sql += " AND ae.overall_score >= ?"
            bind.append(minScore)
        }
        sql += " ORDER BY \(orderBy)"
        if let limit {
            sql += " LIMIT ?"
            bind.append(limit)
        }

        var results: [ReviewedPhoto] = []
        try conn.query(sql, bind: bind) { row in
            results.append(Self.reviewedPhoto(from: row))
        }
        return results
    }

    /// GET /picks: evaluated photos filtered by minimum calibrated-score percentile and/or
    /// exact grade, optionally excluding anything already posted to ANY platform.
    func picks(minPercentile: Double?, grade: String?, notPostedOnly: Bool, limit: Int?) throws -> [ReviewedPhoto] {
        var sql = "WITH \(Self.latestAECTE)\n" + Self.reviewedPhotoSelect + " WHERE ae.overall_score IS NOT NULL"
        var bind: [Any?] = []
        if let minPercentile {
            sql += " AND ae.percentile_library >= ?"
            bind.append(minPercentile)
        }
        if let grade {
            sql += " AND ae.classification = ?"
            bind.append(grade)
        }
        if notPostedOnly {
            sql += " AND NOT EXISTS (SELECT 1 FROM posted_to pt WHERE pt.file_id = f.id)"
        }
        sql += " ORDER BY ae.percentile_library DESC"
        if let limit {
            sql += " LIMIT ?"
            bind.append(limit)
        }

        var results: [ReviewedPhoto] = []
        try conn.query(sql, bind: bind) { row in
            results.append(Self.reviewedPhoto(from: row))
        }
        return results
    }

    /// All reviewed photos for the coaching report (GET /report), optionally scoped to one
    /// shoot and/or a minimum reviewed_at date -- unlike /results, no score filter or limit;
    /// the report aggregates across however many photos match.
    func reviewedPhotosForReport(shootId: Int64?, since: String?) throws -> [ReviewedPhoto] {
        var sql = "WITH \(Self.latestAECTE)\n" + Self.reviewedPhotoSelect + " WHERE ae.overall_score IS NOT NULL"
        var bind: [Any?] = []
        if let shootId {
            sql += " AND f.shoot_id = ?"
            bind.append(shootId)
        }
        if let since {
            sql += " AND ae.created_at >= ?"
            bind.append(since)
        }
        var results: [ReviewedPhoto] = []
        try conn.query(sql, bind: bind) { row in
            results.append(Self.reviewedPhoto(from: row))
        }
        return results
    }

    struct PostedRecord: Hashable {
        let platform: String
        let postedAt: String
    }

    func postedPlatforms(fileId: Int64) throws -> [PostedRecord] {
        var results: [PostedRecord] = []
        try conn.query(
            "SELECT platform, posted_at FROM posted_to WHERE file_id = ? ORDER BY posted_at ASC",
            bind: [fileId]
        ) { row in
            results.append(PostedRecord(platform: row.text(0) ?? "", postedAt: row.text(1) ?? ""))
        }
        return results
    }

    /// Full detail for one photo, keyed by filesystem path rather than id -- the local API's
    /// /open and /export resolve a path to its shoot, but GET /results/{id} itself uses
    /// photoDetail(fileId:) above.
    func fileId(forFullPath path: String) throws -> Int64? {
        var result: Int64?
        try conn.query("SELECT id FROM files WHERE full_path = ?", bind: [path]) { row in
            result = row.int64(0)
        }
        return result
    }

    /// technical_analysis.preview_path for one file (nil if the file or its preview row is
    /// missing) -- the local API's GET /previews/{id}, without photoDetail's evaluation decode.
    func previewPath(fileId: Int64) throws -> String? {
        var result: String?
        try conn.query("SELECT preview_path FROM technical_analysis WHERE file_id = ? LIMIT 1", bind: [fileId]) { row in
            result = row.text(0)
        }
        return result
    }

    /// file_id -> filename, for the local API's /export (building a final filename stem for
    /// each exported file without round-tripping through photoDetail for every one).
    func filenames(forFileIds fileIds: [Int64]) throws -> [Int64: String] {
        guard !fileIds.isEmpty else { return [:] }
        var out: [Int64: String] = [:]
        for chunkStart in stride(from: 0, to: fileIds.count, by: 500) {
            let chunk = Array(fileIds[chunkStart..<min(chunkStart + 500, fileIds.count)])
            let placeholders = conn.placeholders(count: chunk.count)
            try conn.query("SELECT id, filename FROM files WHERE id IN (\(placeholders))", bind: chunk.map { $0 as Any? }) { row in
                out[row.int64(0)] = row.text(1)
            }
        }
        return out
    }

    /// Distinct shoot_ids that own any of `fileIds` -- the local API's POST /critique uses this
    /// to go from a caller-supplied id list to the shoot(s) to evaluate (evaluation, look
    /// detection, and ranking all operate per-shoot; there's no partial-shoot evaluation mode).
    /// Returned in `fileIds`' first-occurrence order so the job's label/ordering is predictable.
    func shootIds(forFileIds fileIds: [Int64]) throws -> [Int64] {
        guard !fileIds.isEmpty else { return [] }
        var byFile: [Int64: Int64] = [:]
        for chunkStart in stride(from: 0, to: fileIds.count, by: 500) {
            let chunk = Array(fileIds[chunkStart..<min(chunkStart + 500, fileIds.count)])
            let placeholders = conn.placeholders(count: chunk.count)
            try conn.query("SELECT id, shoot_id FROM files WHERE id IN (\(placeholders))", bind: chunk.map { $0 as Any? }) { row in
                byFile[row.int64(0)] = row.int64(1)
            }
        }
        var seen = Set<Int64>()
        var ordered: [Int64] = []
        for id in fileIds {
            guard let shootId = byFile[id], !seen.contains(shootId) else { continue }
            seen.insert(shootId)
            ordered.append(shootId)
        }
        return ordered
    }

    // MARK: - Group detail

    func groupDetail(groupId: Int64) throws -> GroupDetail? {
        var isComposite: Bool?
        try conn.query("SELECT is_composite FROM similarity_groups WHERE id = ?", bind: [groupId]) { row in
            isComposite = (row.intOpt(0) ?? 0) != 0
        }
        guard let isComposite else { return nil }

        var members: [GroupMember] = []
        try conn.query("""
            WITH \(Self.latestAECTE)
            SELECT f.id AS file_id, f.filename, ta.preview_path, ae.overall_score,
                   r.rank, r.role, r.rationale
            FROM similarity_group_members sgm
            JOIN files f ON f.id = sgm.file_id
            LEFT JOIN technical_analysis ta ON ta.file_id = f.id
            LEFT JOIN latest_ae ae ON ae.file_id = f.id
            LEFT JOIN rankings r ON r.group_id = sgm.group_id AND r.file_id = f.id
            WHERE sgm.group_id = ?
            ORDER BY r.rank ASC
            """, bind: [groupId]) { row in
            members.append(GroupMember(
                fileId: row.int64(0), filename: row.text(1) ?? "",
                previewPath: row.text(2), overallScore: row.doubleOpt(3),
                rank: row.intOpt(4) ?? 0, role: row.text(5)
            ))
        }
        let rationale = members.first.flatMap { m -> String? in
            var r: String?
            try? conn.query(
                "SELECT rationale FROM rankings WHERE group_id = ? LIMIT 1", bind: [groupId]
            ) { row in r = row.text(0) }
            return r
        }

        return GroupDetail(groupId: groupId, rationale: rationale, isComposite: isComposite, members: members)
    }
}
