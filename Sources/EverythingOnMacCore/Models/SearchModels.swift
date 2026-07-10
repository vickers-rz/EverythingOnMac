import Foundation

public enum SearchMode: Sendable {
    case filenameOnly
    case contentOnly
    case mixed
}

public enum FilenameMatchMode: String, Sendable, Equatable, Codable {
    case literal
    case fuzzy
    case regex
}

public enum SortField: String, Sendable, Codable {
    case relevance
    case path
    case filename
    case size
    case modificationDate
}

public enum SortDirection: String, Sendable, Codable {
    case ascending
    case descending
}

public struct SortOption: Sendable, Equatable, Codable {
    public var field: SortField
    public var direction: SortDirection

    public init(field: SortField, direction: SortDirection = .ascending) {
        self.field = field
        self.direction = direction
    }
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
    public var filenameMatchMode: FilenameMatchMode


    public var minSize: Int64?
    public var minSizeOp: String?
    public var maxSize: Int64?
    public var maxSizeOp: String?

    public var minDate: Date?
    public var minDateOp: String?
    public var maxDate: Date?
    public var maxDateOp: String?

    public var utiFilter: String?
    public var sortOption: SortOption?
    public var limit: Int?
    public var offset: Int?

    public init(
        raw: String,
        terms: [String],
        excludedTerms: [String] = [],
        pathPrefix: String? = nil,
        fileExtensions: Set<String> = [],
        isRegex: Bool = false,
        isCaseSensitive: Bool = false,
        mode: SearchMode = .mixed,
        filenameMatchMode: FilenameMatchMode = .literal,
        minSize: Int64? = nil,
        minSizeOp: String? = nil,
        maxSize: Int64? = nil,
        maxSizeOp: String? = nil,
        minDate: Date? = nil,
        minDateOp: String? = nil,
        maxDate: Date? = nil,
        maxDateOp: String? = nil,
        utiFilter: String? = nil,
        sortOption: SortOption? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.raw = raw
        self.terms = terms
        self.excludedTerms = excludedTerms
        self.pathPrefix = pathPrefix
        self.fileExtensions = fileExtensions
        self.isRegex = isRegex
        self.isCaseSensitive = isCaseSensitive
        self.mode = mode
        self.filenameMatchMode = filenameMatchMode
        self.minSize = minSize
        self.minSizeOp = minSizeOp
        self.maxSize = maxSize
        self.maxSizeOp = maxSizeOp
        self.minDate = minDate
        self.minDateOp = minDateOp
        self.maxDate = maxDate
        self.maxDateOp = maxDateOp
        self.utiFilter = utiFilter
        self.sortOption = sortOption
        self.limit = limit
        self.offset = offset
    }

    public var hasContentPattern: Bool {
        !terms.isEmpty
    }
}

public struct FileIdentity: Sendable, Hashable {
    public let volumeUUID: String
    public let fileID: UInt64

    public init(volumeUUID: String, fileID: UInt64) {
        self.volumeUUID = volumeUUID
        self.fileID = fileID
    }
}

public struct IndexedEntry: Sendable, Hashable {
    public let entryID: Int64
    public let identity: FileIdentity
    public let path: String
    public let filename: String
    public let fileExtension: String
    public let size: Int64
    public let modificationDate: Date?
    public let uti: String?

    public init(
        entryID: Int64,
        identity: FileIdentity,
        path: String,
        filename: String,
        fileExtension: String,
        size: Int64,
        modificationDate: Date?,
        uti: String?
    ) {
        self.entryID = entryID
        self.identity = identity
        self.path = path
        self.filename = filename
        self.fileExtension = fileExtension
        self.size = size
        self.modificationDate = modificationDate
        self.uti = uti
    }

    public var metadata: FileMetadata {
        FileMetadata(
            path: path,
            filename: filename,
            fileExtension: fileExtension,
            size: size,
            modificationDate: modificationDate,
            volumeUUID: identity.volumeUUID,
            fileID: identity.fileID,
            entryID: entryID,
            uti: uti
        )
    }
}

public struct FileMetadata: Sendable, Hashable {
    public var path: String
    public var filename: String
    public var fileExtension: String
    public var size: Int64
    public var modificationDate: Date?
    public var volumeUUID: String?
    public var fileID: UInt64?
    public var entryID: Int64?
    public var uti: String?

    public init(
        path: String,
        filename: String,
        fileExtension: String,
        size: Int64,
        modificationDate: Date?,
        volumeUUID: String? = nil,
        fileID: UInt64?,
        entryID: Int64? = nil,
        uti: String?
    ) {
        self.path = path
        self.filename = filename
        self.fileExtension = fileExtension
        self.size = size
        self.modificationDate = modificationDate
        self.volumeUUID = volumeUUID
        self.fileID = fileID
        self.entryID = entryID
        self.uti = uti
    }

    public var identity: FileIdentity? {
        guard let volumeUUID, let fileID else { return nil }
        return FileIdentity(volumeUUID: volumeUUID, fileID: fileID)
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

public struct SearchResponse: Sendable, Equatable {
    public var results: [SearchResult]
    public var indexError: FileIndexSearchError?
    public var contentError: RipgrepSearchError?
    public var isTruncated: Bool
    public var totalCandidateCount: Int?
    public var skippedCorruptNodeCount: Int
    public var firstCorruptionDescription: String?

    public init(
        results: [SearchResult],
        indexError: FileIndexSearchError? = nil,
        contentError: RipgrepSearchError?,
        isTruncated: Bool = false,
        totalCandidateCount: Int? = nil,
        skippedCorruptNodeCount: Int = 0,
        firstCorruptionDescription: String? = nil
    ) {
        self.results = results
        self.indexError = indexError
        self.contentError = contentError
        self.isTruncated = isTruncated
        self.totalCandidateCount = totalCandidateCount
        self.skippedCorruptNodeCount = skippedCorruptNodeCount
        self.firstCorruptionDescription = firstCorruptionDescription
    }
}

public struct SearchResult: Sendable, Hashable {
    public var metadata: FileMetadata
    public var source: Set<SearchSource>
    public var contentMatches: [ContentMatch]
    public var totalContentMatchCount: Int

    public init(
        metadata: FileMetadata,
        source: Set<SearchSource>,
        contentMatches: [ContentMatch] = [],
        totalContentMatchCount: Int? = nil
    ) {
        self.metadata = metadata
        self.source = source
        self.contentMatches = contentMatches
        self.totalContentMatchCount = totalContentMatchCount ?? contentMatches.count
    }
}

public struct SearchExecutionPolicy: Sendable, Equatable {
    public var defaultCandidateLimit: Int
    public var maximumCandidateLimit: Int
    public var defaultPresentationLimit: Int
    public var maximumContentMatchesPerFile: Int

    public init(
        defaultCandidateLimit: Int = 5_000,
        maximumCandidateLimit: Int = 50_000,
        defaultPresentationLimit: Int = 500,
        maximumContentMatchesPerFile: Int = 20
    ) {
        self.defaultCandidateLimit = max(1, defaultCandidateLimit)
        self.maximumCandidateLimit = max(self.defaultCandidateLimit, maximumCandidateLimit)
        self.defaultPresentationLimit = max(1, defaultPresentationLimit)
        self.maximumContentMatchesPerFile = max(1, maximumContentMatchesPerFile)
    }
}
