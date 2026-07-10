import Foundation

public enum SearchRelevanceScorer {
    public static func score(
        result: SearchResult,
        query: SearchQuery
    ) -> Int {
        var scoreVal = 0
        let isFilenameMatched = result.source.contains(.filenameIndex)
        let isContentMatched = result.source.contains(.contentRipgrep)

        // 1. Filename match score
        if isFilenameMatched {
            for term in query.terms where !term.isEmpty {
                let prepared = FuzzyMatcher.prepare(query: term, caseSensitive: query.isCaseSensitive)
                guard let fuzzyScore = FuzzyMatcher.score(
                    preparedQuery: prepared,
                    candidate: result.metadata.filename
                ) else {
                    return Int.min / 4
                }
                scoreVal += fuzzyScore
            }
        }

        // 2. Content match score
        if isContentMatched {
            var contentScore = 2000 // Base content score
            
            // Keep repeated content hits bounded so they cannot overwhelm a strong filename match.
            contentScore += min(result.totalContentMatchCount, 5) * 120
            for match in result.contentMatches.prefix(3) {
                let lineBonus = max(0, 100 - match.line)
                let colBonus = max(0, 50 - match.column)
                contentScore += lineBonus + colBonus
            }
            
            // Path length penalty (longer paths have a small penalty)
            let pathPenalty = min(500, result.metadata.path.utf8.count)
            contentScore -= pathPenalty
            
            scoreVal += contentScore
        }

        // 3. Hybrid bonus
        if isFilenameMatched && isContentMatched {
            scoreVal += 3000
        }

        return scoreVal
    }
}
