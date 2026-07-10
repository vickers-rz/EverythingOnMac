import Foundation

public enum SearchMode: Sendable {
    case filenameOnly
    case contentOnly
    case mixed
}

public struct SearchQuery: Sendable, Equatable {
    public var raw: String
    public var terms: [String]
    public var excludedTerms: [String]
    public var pathPrefix: String?
    public var fileExtensions: Set<String>
    public var isRegex: Bool
    public var isCaseSensitive: Bool
    public var mode: SearchMode

    public init(
        raw: String,
        terms: [String],
        excludedTerms: [String] = [],
        pathPrefix: String? = nil,
        fileExtensions: Set<String> = [],
        isRegex: Bool = false,
        isCaseSensitive: Bool = false,
        mode: SearchMode = .mixed
    ) {
        self.raw = raw
        self.terms = terms
        self.excludedTerms = excludedTerms
        self.pathPrefix = pathPrefix
        self.fileExtensions = fileExtensions
        self.isRegex = isRegex
        self.isCaseSensitive = isCaseSensitive
        self.mode = mode
    }

    public var hasContentPattern: Bool {
        !terms.isEmpty
    }
}

public struct FileMetadata: Sendable, Hashable {
    public var path: String
    public var filename: String
    public var fileExtension: String
    public var size: Int64
    public var modificationDate: Date?
    public var fileID: UInt64?
    public var uti: String?

    public init(
        path: String,
        filename: String,
        fileExtension: String,
        size: Int64,
        modificationDate: Date?,
        fileID: UInt64?,
        uti: String?
    ) {
        self.path = path
        self.filename = filename
        self.fileExtension = fileExtension
        self.size = size
        self.modificationDate = modificationDate
        self.fileID = fileID
        self.uti = uti
    }
}

public struct ContentMatch: Sendable, Hashable {
    public var line: Int
    public var column: Int
    public var text: String

    public init(line: Int, column: Int, text: String) {
        self.line = line
        self.column = column
        self.text = text
    }
}

public enum SearchSource: String, Sendable, Hashable {
    case filenameIndex
    case contentRipgrep
}

public struct SearchResult: Sendable, Hashable {
    public var metadata: FileMetadata
    public var source: Set<SearchSource>
    public var contentMatches: [ContentMatch]

    public init(metadata: FileMetadata, source: Set<SearchSource>, contentMatches: [ContentMatch] = []) {
        self.metadata = metadata
        self.source = source
        self.contentMatches = contentMatches
    }
}
