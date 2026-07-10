import Foundation
import Testing
@testable import EverythingOnMac

@Test func fileIndexerFiltersByName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let target = root.appendingPathComponent("target-notes.txt")
    let other = root.appendingPathComponent("image.png")
    try "hello".write(to: target, atomically: true, encoding: .utf8)
    try "binary".write(to: other, atomically: true, encoding: .utf8)

    let results = try FileIndexer().indexFiles(at: root, fileNameQuery: "notes", maxResults: 10, includeHidden: false)

    #expect(results.count == 1)
    #expect(results.first?.name == "target-notes.txt")
    #expect(results.first?.path.hasSuffix("target-notes.txt") == true)
}

@Test func ripgrepParserExtractsMatches() {
    let output = """
{"type":"begin","data":{"path":{"text":"/tmp/a.txt"}}}
{"type":"match","data":{"path":{"text":"/tmp/a.txt"},"lines":{"text":"Hello Mac\\n"},"line_number":3,"absolute_offset":10,"submatches":[]}}
{"type":"end","data":{"path":{"text":"/tmp/a.txt"},"binary_offset":null,"stats":{"elapsed":{"secs":0,"nanos":1,"human":"0.000001s"},"searches":1,"searches_with_match":1,"bytes_searched":9,"bytes_printed":0,"matched_lines":1,"matches":1}}}
"""

    let matches = RipgrepSearcher.parseMatches(from: output)

    #expect(matches.count == 1)
    #expect(matches[0] == ContentMatch(filePath: "/tmp/a.txt", lineNumber: 3, lineText: "Hello Mac"))
}

@Test func searchEngineIntersectsNameAndContent() throws {
    struct StubIndexer: FileIndexing {
        func indexFiles(at root: URL, fileNameQuery: String?, maxResults: Int, includeHidden: Bool) throws -> [IndexedFile] {
            [
                IndexedFile(path: "/tmp/a.txt", name: "a.txt", size: 1, modifiedAt: nil, fileID: nil, volumeFormatDescription: "apfs"),
                IndexedFile(path: "/tmp/b.txt", name: "b.txt", size: 1, modifiedAt: nil, fileID: nil, volumeFormatDescription: "apfs"),
            ]
        }
    }

    struct StubContentSearcher: ContentSearching {
        func searchContent(query: String, root: URL) throws -> [ContentMatch] {
            [ContentMatch(filePath: "/tmp/b.txt", lineNumber: 8, lineText: "hit")]
        }
    }

    let engine = SearchEngine(indexer: StubIndexer(), contentSearcher: StubContentSearcher())
    let options = SearchOptions(root: URL(fileURLWithPath: "/tmp"), fileNameQuery: nil, contentQuery: "hit", includeHidden: false, maxResults: 100)

    let results = try engine.search(options: options)

    #expect(results.count == 1)
    #expect(results[0].file.path == "/tmp/b.txt")
    #expect(results[0].contentMatches.count == 1)
}
