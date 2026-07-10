import Foundation

public struct FuzzyScoringWeights: Sendable, Equatable {
    public var exactFilename: Int
    public var caseExactFilename: Int
    public var prefixFilename: Int
    public var substringFilename: Int
    public var subsequenceBase: Int
    public var consecutiveCharacter: Int
    public var wordBoundary: Int
    public var camelCaseBoundary: Int
    public var startBonus: Int
    public var gapPenalty: Int
    public var matchedSpanPenalty: Int
    public var lengthPenalty: Int

    public init(
        exactFilename: Int = 10000,
        caseExactFilename: Int = 500,
        prefixFilename: Int = 3000,
        substringFilename: Int = 1500,
        subsequenceBase: Int = 100,
        consecutiveCharacter: Int = 80,
        wordBoundary: Int = 60,
        camelCaseBoundary: Int = 40,
        startBonus: Int = 250,
        gapPenalty: Int = 5,
        matchedSpanPenalty: Int = 2,
        lengthPenalty: Int = 1
    ) {
        self.exactFilename = exactFilename
        self.caseExactFilename = caseExactFilename
        self.prefixFilename = prefixFilename
        self.substringFilename = substringFilename
        self.subsequenceBase = subsequenceBase
        self.consecutiveCharacter = consecutiveCharacter
        self.wordBoundary = wordBoundary
        self.camelCaseBoundary = camelCaseBoundary
        self.startBonus = startBonus
        self.gapPenalty = gapPenalty
        self.matchedSpanPenalty = matchedSpanPenalty
        self.lengthPenalty = lengthPenalty
    }
}

public enum FuzzyMatcher {
    public struct PreparedQuery: Sendable {
        public let original: String
        public let normalizedUTF8: [UInt8]
        public let characterMask: UInt64
        public let caseSensitive: Bool

        public init(original: String, normalizedUTF8: [UInt8], characterMask: UInt64, caseSensitive: Bool) {
            self.original = original
            self.normalizedUTF8 = normalizedUTF8
            self.characterMask = characterMask
            self.caseSensitive = caseSensitive
        }
    }

    public static func prepare(query: String, caseSensitive: Bool) -> PreparedQuery {
        let normalized = caseSensitive ? query : query.lowercased()
        let utf8 = Array(normalized.utf8)
        let mask = characterMask(for: query, caseSensitive: caseSensitive)
        return PreparedQuery(original: query, normalizedUTF8: utf8, characterMask: mask, caseSensitive: caseSensitive)
    }

    public static func characterMask(for text: String, caseSensitive: Bool = false) -> UInt64 {
        var mask: UInt64 = 0
        let normalized = caseSensitive ? text : text.lowercased()
        for val in normalized.utf8 {
            let bit: Int
            if val >= 97 && val <= 122 { // a-z
                bit = Int(val - 97) // Bits 0-25
            } else if val >= 48 && val <= 57 { // 0-9
                bit = Int(26 + (val - 48)) // Bits 26-35
            } else if val == 46 { // '.'
                bit = 36
            } else if val == 47 { // '/'
                bit = 37
            } else if val == 95 { // '_'
                bit = 38
            } else if val == 45 { // '-'
                bit = 39
            } else {
                // Modulo hash for non-ASCII/other Unicode characters (bits 40-63)
                bit = Int(40 + (UInt64(val) % 24))
            }
            mask |= (1 << bit)
        }
        return mask
    }

    public static func score(
        preparedQuery: PreparedQuery,
        candidate: String,
        weights: FuzzyScoringWeights = FuzzyScoringWeights()
    ) -> Int? {
        let originalCandidateBytes = Array(candidate.utf8)
        let candidateNormalized = preparedQuery.caseSensitive ? candidate : candidate.lowercased()
        let candidateBytes = Array(candidateNormalized.utf8)
        let queryBytes = preparedQuery.normalizedUTF8

        guard !queryBytes.isEmpty else { return 0 }
        guard !candidateBytes.isEmpty else { return nil }

        // 1. Bitmask pre-filter check
        let candMask = characterMask(for: candidate, caseSensitive: preparedQuery.caseSensitive)
        if (candMask & preparedQuery.characterMask) != preparedQuery.characterMask {
            return nil
        }

        let qLen = queryBytes.count
        let cLen = candidateBytes.count

        // 2. Dynamic programming for optimal subsequence matching
        var prevDP = [Int](repeating: Int.min / 2, count: cLen)
        var prevConsecutive = [Int](repeating: 0, count: cLen)

        // Initialize matching the first character of the query
        let firstQ = queryBytes[0]
        for j in 0..<cLen {
            if candidateBytes[j] == firstQ {
                var score = weights.subsequenceBase
                if j == 0 {
                    score += weights.startBonus
                } else {
                    if isWordBoundary(candidateBytes, at: j) {
                        score += weights.wordBoundary
                    } else if candidateBytes.count == originalCandidateBytes.count,
                              isCamelCaseBoundary(originalCandidateBytes, at: j) {
                        score += weights.camelCaseBoundary
                    }
                    score -= j * weights.gapPenalty
                }
                prevDP[j] = score
                prevConsecutive[j] = 1
            }
        }

        // DP state transition for subsequent characters of the query
        if qLen > 1 {
            for i in 1..<qLen {
                let qChar = queryBytes[i]
                var currDP = [Int](repeating: Int.min / 2, count: cLen)
                var currConsecutive = [Int](repeating: 0, count: cLen)

                for j in i..<cLen {
                    if candidateBytes[j] == qChar {
                        var bestScore = Int.min / 2
                        var bestConsec = 0

                        for k in (i - 1)..<j {
                            let prevScore = prevDP[k]
                            if prevScore > Int.min / 2 {
                                var score = prevScore + weights.subsequenceBase
                                let gap = j - k - 1
                                if gap == 0 {
                                    score += weights.consecutiveCharacter
                                } else {
                                    score -= gap * weights.gapPenalty
                                }

                                if gap > 0 {
                                    if isWordBoundary(candidateBytes, at: j) {
                                        score += weights.wordBoundary
                                    } else if candidateBytes.count == originalCandidateBytes.count,
                                              isCamelCaseBoundary(originalCandidateBytes, at: j) {
                                        score += weights.camelCaseBoundary
                                    }
                                }

                                if score > bestScore {
                                    bestScore = score
                                    bestConsec = (gap == 0) ? (prevConsecutive[k] + 1) : 1
                                }
                            }
                        }

                        currDP[j] = bestScore
                        currConsecutive[j] = bestConsec
                    }
                }

                prevDP = currDP
                prevConsecutive = currConsecutive
            }
        }

        // Find the maximum score in the final DP row
        var maxScore = Int.min / 2
        for j in 0..<cLen {
            if prevDP[j] > maxScore {
                maxScore = prevDP[j]
            }
        }

        guard maxScore > Int.min / 2 else { return nil }

        // 3. Apply exact and prefix match bonuses
        let comparisonQuery = preparedQuery.caseSensitive
            ? preparedQuery.original
            : preparedQuery.original.lowercased()
        if candidateNormalized == comparisonQuery {
            maxScore += weights.exactFilename
            if candidate == preparedQuery.original {
                maxScore += weights.caseExactFilename
            }
        } else if candidateNormalized.hasPrefix(comparisonQuery) {
            maxScore += weights.prefixFilename
        } else if candidateNormalized.contains(comparisonQuery) {
            maxScore += weights.substringFilename
        }

        // 4. Apply length penalty
        let excessLength = cLen - qLen
        maxScore -= excessLength * weights.lengthPenalty

        return maxScore
    }

    private static func isWordBoundary(_ bytes: [UInt8], at index: Int) -> Bool {
        if index == 0 { return true }
        let prev = bytes[index - 1]
        // Space, Underscore, Dash, Slash, Dot, Backslash, Colon
        return prev == 32 || prev == 95 || prev == 45 || prev == 47 || prev == 46 || prev == 92 || prev == 58
    }

    private static func isCamelCaseBoundary(_ originalBytes: [UInt8], at index: Int) -> Bool {
        if index == 0 { return false }
        let char = originalBytes[index]
        let prevChar = originalBytes[index - 1]
        // Char is A-Z, prevChar is a-z
        return (char >= 65 && char <= 90) && (prevChar >= 97 && prevChar <= 122)
    }
}
