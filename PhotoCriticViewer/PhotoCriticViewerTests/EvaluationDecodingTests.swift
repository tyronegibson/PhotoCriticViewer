import Testing
import Foundation
@testable import PhotoCriticViewer

/// Evaluation must decode BOTH the legacy (v1-v3) flat "scores" shape and the v4+ nested
/// "category_evaluations" shape into the same struct -- old rows are never rewritten (see
/// API.md's calibrated-scoring section), so both have to keep working side by side forever.
struct EvaluationDecodingTests {
    @Test func decodesV4NestedCategoryEvaluations() throws {
        let json = """
        {
          "category_evaluations": {
            "composition": {"reason": "tight crop on the hand", "score": 7.5},
            "lighting": {"reason": "flat key light", "score": 4.0}
          },
          "style_summary": {"lighting": "soft", "mood": "moody", "setup": "studio", "wardrobe": "lingerie"},
          "distinguishing_strength": "the exact angle of the head",
          "reasoning": "A solid frame overall.",
          "strengths": ["good crop"],
          "weaknesses": ["flat lighting"],
          "technical_issues": [],
          "artistic_choices": [],
          "overall_score": 62.3,
          "classification": "C",
          "recommendation": "MAYBE"
        }
        """
        let evaluation = try JSONDecoder().decode(Evaluation.self, from: Data(json.utf8))

        #expect(evaluation.scores["composition"] == 7.5)
        #expect(evaluation.scores["lighting"] == 4.0)
        #expect(evaluation.categoryReasons["composition"] == "tight crop on the hand")
        #expect(evaluation.styleSummary["mood"] == "moody")
        #expect(evaluation.overallScore == 62.3)
        #expect(evaluation.classification == "C")
        #expect(evaluation.distinguishingStrength == "the exact angle of the head")
    }

    @Test func decodesLegacyFlatScoresShape() throws {
        let json = """
        {
          "scores": {"composition": 8.0, "lighting": 6.0},
          "reasoning": "An older row.",
          "strengths": [], "weaknesses": [], "technical_issues": [], "artistic_choices": [],
          "overall_score": 78.0,
          "classification": "B",
          "recommendation": "KEEP"
        }
        """
        let evaluation = try JSONDecoder().decode(Evaluation.self, from: Data(json.utf8))

        #expect(evaluation.scores["composition"] == 8.0)
        #expect(evaluation.categoryReasons.isEmpty) // legacy rows never had per-category reasons
        #expect(evaluation.styleSummary.isEmpty)     // legacy rows never had style_summary
        #expect(evaluation.overallScore == 78.0)
    }

    @Test func missingOptionalFieldsDoNotFailDecoding() throws {
        let json = #"{"reasoning": "minimal row"}"#
        let evaluation = try JSONDecoder().decode(Evaluation.self, from: Data(json.utf8))

        #expect(evaluation.scores.isEmpty)
        #expect(evaluation.overallScore == 0)
        #expect(evaluation.confidence == nil)
    }

    @Test func orderedScoresFollowsThePromptSchemaOrderNotAlphabetical() throws {
        let json = """
        {"category_evaluations": {
          "subject": {"reason": "x", "score": 1},
          "composition": {"reason": "x", "score": 2}
        }}
        """
        let evaluation = try JSONDecoder().decode(Evaluation.self, from: Data(json.utf8))
        let order = evaluation.orderedScores.map(\.0)
        #expect(order == ["composition", "subject"]) // composition precedes subject in scoreOrder
    }
}
