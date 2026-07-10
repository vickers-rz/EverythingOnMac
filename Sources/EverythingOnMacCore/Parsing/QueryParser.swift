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
        var filenameMatchMode = FilenameMatchMode.literal

        var minSize: Int64?
        var minSizeOp: String?
        var maxSize: Int64?
        var maxSizeOp: String?

        var minDate: Date?
        var minDateOp: String?
        var maxDate: Date?
        var maxDateOp: String?

        var utiFilter: String?
        var sortOption: SortOption?
        var limit: Int?
        var offset: Int?

        for token in tokenize(trimmed) {
            if token == "regex:true" {
                isRegex = true
                filenameMatchMode = .regex
                continue
            }
            if token == "fuzzy:true" {
                filenameMatchMode = .fuzzy
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
            if token.hasPrefix("size:") {
                let sizeStr = String(token.dropFirst("size:".count))
                if let parsed = parseSize(sizeStr) {
                    if parsed.comparison == ">" || parsed.comparison == ">=" {
                        minSize = parsed.bytes
                        minSizeOp = parsed.comparison
                    } else if parsed.comparison == "<" || parsed.comparison == "<=" {
                        maxSize = parsed.bytes
                        maxSizeOp = parsed.comparison
                    }
                }
                continue
            }
            if token.hasPrefix("date:") {
                let dateStr = String(token.dropFirst("date:".count))
                if let parsed = parseDate(dateStr) {
                    if parsed.comparison == ">" || parsed.comparison == ">=" {
                        minDate = parsed.date
                        minDateOp = parsed.comparison
                    } else if parsed.comparison == "<" || parsed.comparison == "<=" {
                        maxDate = parsed.date
                        maxDateOp = parsed.comparison
                    }
                }
                continue
            }
            if token.hasPrefix("uti:") {
                let utiVal = String(token.dropFirst("uti:".count))
                if !utiVal.isEmpty {
                    utiFilter = utiVal
                }
                continue
            }
            if token.hasPrefix("limit:"),
               let value = Int(token.dropFirst("limit:".count)), value > 0 {
                limit = value
                continue
            }
            if token.hasPrefix("offset:"),
               let value = Int(token.dropFirst("offset:".count)), value >= 0 {
                offset = value
                continue
            }
            if token.hasPrefix("sort:") {
                let value = String(token.dropFirst("sort:".count)).lowercased()
                let field: SortField?
                switch value {
                case "relevance", "score": field = .relevance
                case "path": field = .path
                case "filename", "name": field = .filename
                case "size": field = .size
                case "date", "modified", "modificationdate": field = .modificationDate
                default: field = nil
                }
                if let field {
                    sortOption = SortOption(field: field, direction: sortOption?.direction ?? (field == .relevance ? .descending : .ascending))
                }
                continue
            }
            if token.hasPrefix("order:") {
                let value = String(token.dropFirst("order:".count)).lowercased()
                let direction: SortDirection? = value == "asc" || value == "ascending" ? .ascending : (value == "desc" || value == "descending" ? .descending : nil)
                if let direction {
                    sortOption = SortOption(field: sortOption?.field ?? .relevance, direction: direction)
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
            mode: mode,
            filenameMatchMode: filenameMatchMode,
            minSize: minSize,
            minSizeOp: minSizeOp,
            maxSize: maxSize,
            maxSizeOp: maxSizeOp,
            minDate: minDate,
            minDateOp: minDateOp,
            maxDate: maxDate,
            maxDateOp: maxDateOp,
            utiFilter: utiFilter,
            sortOption: sortOption,
            limit: limit,
            offset: offset
        )
    }

    private static func parseSize(_ string: String) -> (comparison: String, bytes: Int64)? {
        let operators = [">=", "<=", ">", "<"]
        guard let op = operators.first(where: { string.hasPrefix($0) }) else { return nil }
        let valuePart = String(string.dropFirst(op.count))

        var multiplier: Int64 = 1
        var numericPart = valuePart

        if let lastChar = valuePart.last?.uppercased() {
            if lastChar == "K" {
                multiplier = 1024
                numericPart = String(valuePart.dropLast())
            } else if lastChar == "M" {
                multiplier = 1024 * 1024
                numericPart = String(valuePart.dropLast())
            } else if lastChar == "G" {
                multiplier = 1024 * 1024 * 1024
                numericPart = String(valuePart.dropLast())
            }
        }

        guard let numericValue = Int64(numericPart) else { return nil }
        return (op, numericValue * multiplier)
    }

    private static func parseDate(_ string: String) -> (comparison: String, date: Date)? {
        let operators = [">=", "<=", ">", "<"]
        guard let op = operators.first(where: { string.hasPrefix($0) }) else { return nil }
        let datePart = String(string.dropFirst(op.count))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: datePart) else { return nil }
        return (op, date)
    }

    private static func tokenize(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        var hasAddedContentForCurrentToken = false

        for char in string {
            if escaped {
                if char == "\"" || char == "\\" {
                    current.append(char)
                } else {
                    current.append("\\")
                    current.append(char)
                }
                escaped = false
                hasAddedContentForCurrentToken = true
                continue
            }

            if char == "\\" {
                escaped = true
                continue
            }

            if char == "\"" {
                inQuote.toggle()
                hasAddedContentForCurrentToken = true
                continue
            }

            if char.isWhitespace && !inQuote {
                if hasAddedContentForCurrentToken || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasAddedContentForCurrentToken = false
                }
                continue
            }

            current.append(char)
            hasAddedContentForCurrentToken = true
        }

        if escaped {
            current.append("\\")
            hasAddedContentForCurrentToken = true
        }

        if hasAddedContentForCurrentToken || !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
