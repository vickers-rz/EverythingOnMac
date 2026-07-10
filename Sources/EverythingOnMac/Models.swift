import Foundation

struct SearchOptions {
    let root: URL
    let fileNameQuery: String?
    let contentQuery: String?
    let includeHidden: Bool
    let maxResults: Int
}

struct IndexedFile: Equatable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let modifiedAt: Date?
    let fileID: String?
    let volumeFormatDescription: String?
}

struct ContentMatch: Equatable, Sendable {
    let filePath: String
    let lineNumber: Int
    let lineText: String
}

struct SearchResult: Equatable, Sendable {
    let file: IndexedFile
    let contentMatches: [ContentMatch]
}
