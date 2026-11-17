import Foundation

struct ShootSummary: Identifiable, Hashable {
    let id: Int64
    let folderPath: String
    let totalFiles: Int
    let evaluatedCount: Int
    let keepCount: Int
    let maybeCount: Int
    let rejectCount: Int
    let separatePeople: Bool
    /// Up to five photos spread across the shoot (first, last, quartiles). A shoot is flagged as
    /// missing RAW files if any of these is gone, so losing all but one file can't hide behind a green row.
    let sampleFilePaths: [String]

    var displayName: String {
        (folderPath as NSString).lastPathComponent
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case score = "Score"
    case filename = "Filename"
    var id: String { rawValue }
}

struct PhotoGridItem: Identifiable, Hashable {
    let fileId: Int64
    let filename: String
    let fullPath: String
    let previewPath: String?
    let overallScore: Double?
    let classification: String?
    let recommendation: String?
    let groupId: Int64?
    let groupRank: Int?
    let groupRole: String?
    let groupIsComposite: Bool
    let lookId: Int64?
    let lookName: String?
    let personId: Int64?
    let personName: String?

    var id: Int64 { fileId }
}

/// A look/outfit boundary — every file in the shoot from startFilename (in
/// filename order) up to the next look's startFilename belongs to this one.
struct Look: Identifiable, Hashable {
    let id: Int64
    let name: String
    let startFilename: String
}

/// A person boundary, for shoots with more than one subject — same
/// live-query membership model as Look (see PhotoCriticDatabase.shootGrid).
/// Hidden behind ShootSummary.separatePeople since most shoots are one
/// subject or an event with no need to split by person.
struct Person: Identifiable, Hashable {
    let id: Int64
    let name: String
    let startFilename: String
}

/// Matches the JSON shape written by photocritic's evaluation prompts. v1-v3 wrote a flat
/// "scores": {cat: number} dict with the model also choosing overall_score/classification/
/// recommendation itself. v4+ writes a nested "category_evaluations": {cat: {reason, score}}
/// (so `scores`/`categoryReasons` here are both DERIVED from whichever shape is present, not a
/// direct 1:1 decode of either), adds "style_summary", and overall_score/classification/
/// recommendation are computed in code (photocritic.scoring) rather than model-provided --
/// still the same three fields/columns, just a different author. A custom init(from:) rather
/// than synthesized Codable, specifically so BOTH shapes decode into the same struct and old
/// rows never need rewriting (see API.md's calibrated-scoring section).
struct Evaluation: Hashable {
    let overallScore: Double
    let classification: String
    let recommendation: String
    let scores: [String: Double]
    /// v4+ only -- the one-line reason written immediately before each category's score.
    /// Empty for a v1-v3 row, which only ever had one shoot-level `reasoning` sentence.
    let categoryReasons: [String: String]
    let technicalIssues: [String]
    let artisticChoices: [String]
    let strengths: [String]
    let weaknesses: [String]
    let reasoning: String
    let confidence: Double?
    let distinguishingStrength: String?
    let distinguishingWeakness: String?
    /// v4+ only -- short caption-writing hints (lighting/mood/setup/wardrobe). Empty dict
    /// for an older row.
    let styleSummary: [String: String]

    private enum CodingKeys: String, CodingKey {
        case overallScore = "overall_score"
        case classification, recommendation, scores
        case categoryEvaluations = "category_evaluations"
        case technicalIssues = "technical_issues"
        case artisticChoices = "artistic_choices"
        case strengths, weaknesses, reasoning, confidence
        case distinguishingStrength = "distinguishing_strength"
        case distinguishingWeakness = "distinguishing_weakness"
        case styleSummary = "style_summary"
    }

    private struct CategoryEntry: Decodable {
        let reason: String?
        let score: Double?
    }

    /// Category order matches the evaluation prompt's schema, not alphabetical.
    static let scoreOrder = [
        "composition", "subject", "lighting", "exposure", "focus", "expression",
        "pose", "background", "color_tonality", "emotional_impact",
        "visual_hierarchy", "professional_polish", "client_delivery_value",
    ]

    var orderedScores: [(String, Double)] {
        Self.scoreOrder.compactMap { key in scores[key].map { (key, $0) } }
    }
}

extension Evaluation: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overallScore = try c.decodeIfPresent(Double.self, forKey: .overallScore) ?? 0
        classification = try c.decodeIfPresent(String.self, forKey: .classification) ?? ""
        recommendation = try c.decodeIfPresent(String.self, forKey: .recommendation) ?? ""
        technicalIssues = try c.decodeIfPresent([String].self, forKey: .technicalIssues) ?? []
        artisticChoices = try c.decodeIfPresent([String].self, forKey: .artisticChoices) ?? []
        strengths = try c.decodeIfPresent([String].self, forKey: .strengths) ?? []
        weaknesses = try c.decodeIfPresent([String].self, forKey: .weaknesses) ?? []
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        distinguishingStrength = try c.decodeIfPresent(String.self, forKey: .distinguishingStrength)
        distinguishingWeakness = try c.decodeIfPresent(String.self, forKey: .distinguishingWeakness)
        styleSummary = try c.decodeIfPresent([String: String].self, forKey: .styleSummary) ?? [:]

        if let nested = try c.decodeIfPresent([String: CategoryEntry].self, forKey: .categoryEvaluations) {
            scores = nested.compactMapValues(\.score)
            categoryReasons = nested.compactMapValues(\.reason)
        } else {
            scores = try c.decodeIfPresent([String: Double].self, forKey: .scores) ?? [:]
            categoryReasons = [:]
        }
    }
}

struct TechnicalInfo: Hashable {
    let sharpnessScore: Double
    let exposureMean: Double
    let highlightClipPct: Double
    let shadowClipPct: Double
    let flags: [String]
    let previewPath: String?
}

struct PhotoMetadata: Hashable {
    let cameraModel: String?
    let lens: String?
    let iso: Int?
    let aperture: String?
    let shutterSpeed: String?
    let focalLength: String?
    let captureTime: String?
}

struct GroupMembership: Hashable {
    let groupId: Int64
    let rank: Int
    let role: String?
    let rationale: String?
}

struct PhotoDetail: Identifiable, Hashable {
    let fileId: Int64
    let filename: String
    let evaluation: Evaluation?
    let technical: TechnicalInfo?
    let metadata: PhotoMetadata?
    let group: GroupMembership?
    // From ai_evaluations directly, not from evaluation_json -- see
    // PhotoCriticDatabase.photoDetail. nil until calibration.recompute_all has run at least
    // once after this evaluation was written.
    let calibratedScore: Double?
    let percentileShoot: Double?
    let percentileLibrary: Double?

    var id: Int64 { fileId }
}

struct GroupMember: Identifiable, Hashable {
    let fileId: Int64
    let filename: String
    let previewPath: String?
    let overallScore: Double?
    let rank: Int
    let role: String?

    var id: Int64 { fileId }
}

struct GroupDetail: Identifiable, Hashable {
    let groupId: Int64
    let rationale: String?
    let isComposite: Bool
    let members: [GroupMember]

    var id: Int64 { groupId }
}
