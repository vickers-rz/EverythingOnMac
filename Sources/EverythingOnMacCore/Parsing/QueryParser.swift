import Foundation

public enum QueryParser {
    public static func parse(_ raw: String, mode: SearchMode = .mixed) -> SearchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return SearchQuery(raw: raw, terms: [], mode: mode)
        }

        var terms: [String] = []
        var excluded: [String] = []
        var pathPrefix: String?
        var fileExtensions = Set<String>()
        var isRegex = false
        var isCaseSensitive = false

        for token in tokenize(trimmed) {
            if token == "regex:true" {
                isRegex = true
                continue
            }
            if token == "case:true" {
                isCaseSensitive = true
                continue
            }
            if token.hasPrefix("path:") {
                pathPrefix = String(token.dropFirst("path:".count))
                continue
            }
            if token.hasPrefix("ext:") {
                let ext = String(token.dropFirst("ext:".count)).lowercased()
                if !ext.isEmpty {
                    fileExtensions.insert(ext)
                }
                continue
            }
            if token.hasPrefix("-") {
                let excludedToken = String(token.dropFirst())
                if !excludedToken.isEmpty {
                    excluded.append(excludedToken)
                }
                continue
            }
            terms.append(token)
        }

        return SearchQuery(
            raw: raw,
            terms: terms,
            excludedTerms: excluded,
            pathPrefix: pathPrefix,
            fileExtensions: fileExtensions,
            isRegex: isRegex,
            isCaseSensitive: isCaseSensitive,
            mode: mode
        )
    }

    private static func tokenize(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for char in string {
            if char == "\"" {
                inQuote.toggle()
                if !inQuote && !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            if char.isWhitespace && !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
