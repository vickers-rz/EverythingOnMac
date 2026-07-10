import Foundation
import Testing
@testable import EverythingOnMacCore

@Test("Parser supports filters and flags")
func parserSupportsStructuredTokens() {
    let query = QueryParser.parse("\"hello world\" ext:md ext:txt path:/Users/me -draft regex:true case:true", mode: .mixed)

    #expect(query.terms == ["hello world"])
    #expect(query.excludedTerms == ["draft"])
    #expect(query.pathPrefix == "/Users/me")
    #expect(query.fileExtensions == Set(["md", "txt"]))
    #expect(query.isRegex)
    #expect(query.isCaseSensitive)
}

@Test("Merge unions source and content matches")
func mergeCombinesIndexAndContent() {
    let metadata = FileMetadata(
        path: "/tmp/a.txt",
        filename: "a.txt",
        fileExtension: "txt",
        size: 1,
        modificationDate: nil,
        fileID: 1,
        uti: nil
    )

    let fromIndex = SearchResult(metadata: metadata, source: [.filenameIndex])
    let fromContent = SearchResult(metadata: metadata, source: [.contentRipgrep], contentMatches: [ContentMatch(line: 5, column: 1, text: "abc")])

    let coordinator = SearchCoordinator(
        indexer: FileIndexer(configuration: IndexerConfiguration(roots: [])),
        ripgrepSearcher: RipgrepSearcher(),
        roots: []
    )

    let merged = coordinator.merge(index: [fromIndex], content: [fromContent])

    #expect(merged.count == 1)
    #expect(merged[0].source.contains(.filenameIndex))
    #expect(merged[0].source.contains(.contentRipgrep))
    #expect(merged[0].contentMatches.count == 1)
}
