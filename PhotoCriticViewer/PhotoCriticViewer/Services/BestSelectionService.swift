import Foundation

/// Picks a curated "best of shoot" set for social posts / client soft-delivery:
/// filters to KEEP (optionally + MAYBE), then — since a similarity group is a
/// burst of near-duplicates — keeps only the top-ranked frame per group so a
/// delivery set never contains two near-identical shots. Ungrouped photos
/// pass through untouched (nothing to dedupe against). A group flagged as a
/// composite set (GroupComparisonView) is exempt from dedup entirely — those
/// frames are source layers for one final image, not redundant duplicates.
enum BestSelectionScope: String, CaseIterable, Identifiable {
    case keepOnly = "Keep Only"
    case keepAndMaybe = "Keep + Maybe"
    var id: String { rawValue }

    fileprivate func matches(_ item: PhotoGridItem) -> Bool {
        switch self {
        case .keepOnly: item.recommendation == "KEEP"
        case .keepAndMaybe: item.recommendation == "KEEP" || item.recommendation == "MAYBE"
        }
    }
}

enum BestSelectionService {
    static func select(
        from grid: [PhotoGridItem],
        scope: BestSelectionScope,
        dedupeGroups: Bool,
        maxCount: Int?
    ) -> [PhotoGridItem] {
        var items = grid.filter(scope.matches)

        if dedupeGroups {
            items = items.filter { item in
                guard item.groupId != nil else { return true }
                if item.groupIsComposite { return true }
                return item.groupRole == "strongest" || item.groupRank == 1
            }
        }

        items.sort { ($0.overallScore ?? 0) > ($1.overallScore ?? 0) }

        if let maxCount, items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }

        return items
    }
}
