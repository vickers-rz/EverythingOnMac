import Foundation
import Testing
@testable import EverythingOnMacCore

private func canonicalPath(for path: String) -> String {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else {
        return path
    }
    return buffer.withUnsafeBufferPointer { ptr in
        String(cString: ptr.baseAddress!)
    }
}

private func makeExecutableScript(contents: String) throws -> String {
    let path = NSTemporaryDirectory() + UUID().uuidString + ".sh"
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: path
    )
    return path
}

private func insertIndexedEntry(
    _ db: SQLiteDatabase,
    volume: String,
    fileID: Int64,
    parentID: Int64,
    name: String,
    isDirectory: Bool,
    size: Int64 = 0,
    modificationDate: Double = 0,
    uti: Any = NSNull()
) throws {
    try db.execute(sql: "INSERT INTO fs_objects (volume_uuid, file_id, is_directory, file_extension, size, modification_date, uti) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(volume_uuid, file_id) DO UPDATE SET is_directory=excluded.is_directory, file_extension=excluded.file_extension, size=excluded.size, modification_date=excluded.modification_date, uti=excluded.uti;", bindings: [volume, fileID, isDirectory ? 1 : 0, isDirectory ? "" : URL(fileURLWithPath: name).pathExtension.lowercased(), size, modificationDate, uti])
    try db.execute(sql: "INSERT OR REPLACE INTO fs_entries (volume_uuid, parent_file_id, target_file_id, name, name_character_mask) VALUES (?, ?, ?, ?, ?);", bindings: [volume, parentID, fileID, name, Int64(bitPattern: FuzzyMatcher.characterMask(for: name))])
}

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

@Test("QueryParser parses escape sequences and quotes concatenation")
func queryParserEscapingAndConcatenation() {
    let query1 = QueryParser.parse(#"name:"a \"quoted\" file""#, mode: .mixed)
    #expect(query1.terms == ["name:a \"quoted\" file"])
    
    let query2 = QueryParser.parse("abc\"def ghi\"jkl", mode: .mixed)
    #expect(query2.terms == ["abcdef ghijkl"])
    
    let query3 = QueryParser.parse(#"path:"my folder""#, mode: .mixed)
    #expect(query3.pathPrefix == "my folder")
    
    let query4 = QueryParser.parse(#""hello"#, mode: .mixed)
    #expect(query4.terms == ["hello"])

    // Additional tests for backslash escaping behavior
    #expect(QueryParser.parse(#"\d+ regex:true"#).terms == [#"\d+"#])
    #expect(QueryParser.parse(#"\.txt$ regex:true"#).terms == [#"\.txt$"#])
    #expect(QueryParser.parse(#"foo\bar"#).terms == [#"foo\bar"#])
    #expect(QueryParser.parse(#"foo\\bar"#).terms == [#"foo\bar"#])
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
        indexer: try! FileIndexer(configuration: IndexerConfiguration(roots: [])),
        ripgrepSearcher: RipgrepSearcher(),
        roots: []
    )

    let merged = coordinator.merge(index: [fromIndex], content: [fromContent], query: QueryParser.parse(""))

    #expect(merged.count == 1)
    #expect(merged[0].source.contains(.filenameIndex))
    #expect(merged[0].source.contains(.contentRipgrep))
    #expect(merged[0].contentMatches.count == 1)
}


@Test("Default rg path prefers environment override")
func defaultRipgrepPathUsesEnvironmentCandidates() {
    let path = RipgrepConfiguration.defaultExecutablePath()
    #expect(!path.isEmpty)
}

@Test("APFS inspector returns one capability record per root")
func volumeInspectorReportsRoots() {
    let roots = [URL(fileURLWithPath: NSTemporaryDirectory())]
    let capabilities = APFSVolumeInspector.inspect(roots: roots)
    #expect(capabilities.count == 1)
    #expect(capabilities[0].rootPath == roots[0].path)
}

@Test("SQLite database basic operations and querying")
func sqliteDatabaseBasicOperations() throws {
    let dbPath = NSTemporaryDirectory() + UUID().uuidString + "_test.db"
    let db = try SQLiteDatabase(path: dbPath)
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    try insertIndexedEntry(db, volume: "vol-uuid", fileID: 12345, parentID: 2, name: "test.txt", isDirectory: false, size: 100, modificationDate: Date().timeIntervalSince1970, uti: "public.text")

    let rows = try db.query(sql: "SELECT * FROM fs_entries WHERE name = ?;", bindings: ["test.txt"])
    #expect(rows.count == 1)
    #expect(rows[0]["volume_uuid"] as? String == "vol-uuid")
}

@Test("FileIndexer SQLite integration and search features")
func fileIndexerSearchFeatures() async throws {
    let rawTempDir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: rawTempDir, withIntermediateDirectories: true)
    let tempDir = canonicalPath(for: rawTempDir) + "/"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let file1 = tempDir + "Report.pdf"
    let file2 = tempDir + "notes.txt"
    let file3 = tempDir + "vacation.jpg"

    try "pdf".write(toFile: file1, atomically: true, encoding: .utf8)
    try "text".write(toFile: file2, atomically: true, encoding: .utf8)
    try "jpg".write(toFile: file3, atomically: true, encoding: .utf8)

    let dbPath = tempDir + "indexer.db"
    let config = IndexerConfiguration(roots: [URL(fileURLWithPath: tempDir)], databasePath: dbPath)
    let indexer = try FileIndexer(configuration: config)

    // Manually add some test files to indexer DB via upsert
    try await indexer.upsert(path: file1)
    try await indexer.upsert(path: file2)
    try await indexer.upsert(path: file3)

    // Test basic query
    let query1 = QueryParser.parse("report")
    let results1 = (try await indexer.query(query1)).results
    #expect(results1.count == 1)
    #expect(results1[0].metadata.filename == "Report.pdf")

    // Test ext filter
    let query2 = QueryParser.parse("ext:txt")
    let results2 = (try await indexer.query(query2)).results
    #expect(results2.count == 1)
    #expect(results2[0].metadata.filename == "notes.txt")

    // Test path prefix filter
    let query3 = QueryParser.parse("path:\(tempDir)")
    let results3 = (try await indexer.query(query3)).results
    #expect(results3.count == 3)

    // Test regex query
    let query4 = QueryParser.parse("vacation regex:true")
    let results4 = (try await indexer.query(query4)).results
    #expect(results4.count == 1)
    #expect(results4[0].metadata.filename == "vacation.jpg")
    
    // Test regex case-sensitive query
    let query5 = QueryParser.parse("^notes.*txt$ regex:true")
    let results5 = (try await indexer.query(query5)).results
    #expect(results5.count == 1)
}

@Test("QueryParser parses size and dates")
func queryParserParsesSizeAndDates() {
    let query = QueryParser.parse("size:>10M date:<2026-07-01 uti:public.image")
    #expect(query.minSize == Int64(10 * 1024 * 1024))
    #expect(query.minSizeOp == ">")
    #expect(query.maxDate != nil)
    #expect(query.maxDateOp == "<")
    #expect(query.utiFilter == "public.image")
}

@Test("FileIndexer SQLite sorting and paging")
func fileIndexerSortingAndPaging() async throws {
    let rawTempDir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: rawTempDir, withIntermediateDirectories: true)
    let tempDir = canonicalPath(for: rawTempDir) + "/"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let file1 = tempDir + "small.txt"
    let file2 = tempDir + "large.txt"

    // small file: 10 bytes
    try "0123456789".write(toFile: file1, atomically: true, encoding: .utf8)
    // large file: 20 bytes
    try "01234567890123456789".write(toFile: file2, atomically: true, encoding: .utf8)

    let dbPath = tempDir + "sort_test.db"
    let config = IndexerConfiguration(roots: [URL(fileURLWithPath: tempDir)], databasePath: dbPath)
    let indexer = try FileIndexer(configuration: config)

    try await indexer.upsert(path: file1)
    try await indexer.upsert(path: file2)

    // Test sort by size ascending
    var query = QueryParser.parse("ext:txt")
    query.sortOption = SortOption(field: .size, direction: .ascending)
    let ascResults = (try await indexer.query(query)).results
    #expect(ascResults.count == 2)
    #expect(ascResults[0].metadata.filename == "small.txt")
    #expect(ascResults[1].metadata.filename == "large.txt")

    // Test sort by size descending
    query.sortOption = SortOption(field: .size, direction: .descending)
    let descResults = (try await indexer.query(query)).results
    #expect(descResults.count == 2)
    #expect(descResults[0].metadata.filename == "large.txt")
    #expect(descResults[1].metadata.filename == "small.txt")

    // Test paging (limit = 1)
    query.limit = 1
    query.sortOption = SortOption(field: .size, direction: .ascending)
    let limitResults = (try await indexer.query(query)).results
    #expect(limitResults.count == 1)
    #expect(limitResults[0].metadata.filename == "small.txt")

    // Test paging with offset (limit = 1, offset = 1)
    query.offset = 1
    let offsetResults = (try await indexer.query(query)).results
    #expect(offsetResults.count == 1)
    #expect(offsetResults[0].metadata.filename == "large.txt")
}

@Test("Database migration creates hardlink-aware schema and requests rebuild")
func databaseMigrationToV6() throws {
    let dbPath = NSTemporaryDirectory() + UUID().uuidString + "_v6_test.db"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let db = try SQLiteDatabase(path: dbPath)
    let version = try db.query(sql: "PRAGMA user_version;")
    #expect(version.first?["user_version"] as? Int64 == 6)

    let tables = try db.query(sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('fs_objects', 'fs_entries');")
    #expect(tables.count == 2)
    let legacy = try db.query(sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='fs_nodes';")
    #expect(legacy.isEmpty)
    let rebuild = try db.query(sql: "SELECT value FROM metadata WHERE key='rebuild_required';")
    #expect(rebuild.first?["value"] as? String == "1")
}

@Test("Hardlink schema enforces object-entry identity and foreign keys")
func hardlinkSchemaConstraints() throws {
    let dbPath = NSTemporaryDirectory() + UUID().uuidString + "_constraints.db"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }
    let db = try SQLiteDatabase(path: dbPath)

    try insertIndexedEntry(db, volume: "vol-1", fileID: 100, parentID: 2, name: "original.txt", isDirectory: false)
    try insertIndexedEntry(db, volume: "vol-1", fileID: 100, parentID: 3, name: "linked.txt", isDirectory: false)
    let objects = try db.query(sql: "SELECT * FROM fs_objects WHERE volume_uuid='vol-1' AND file_id=100;")
    let entries = try db.query(sql: "SELECT * FROM fs_entries WHERE volume_uuid='vol-1' AND target_file_id=100;")
    #expect(objects.count == 1)
    #expect(entries.count == 2)

    #expect(throws: (any Error).self) {
        try db.execute(sql: "INSERT INTO fs_entries (volume_uuid, parent_file_id, target_file_id, name) VALUES ('vol-1', 2, 999, 'orphan.txt');")
    }
}

@Test("FileIndexer pathPrefix CTE filtering restricts search space before LIMIT")
func pathPrefixCTEFilteringRestrictsBeforeLimit() async throws {
    let rawTempDir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: rawTempDir, withIntermediateDirectories: true)
    let tempDir = canonicalPath(for: rawTempDir) + "/"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    // Create nested subdirectories
    let subDir = tempDir + "matching_sub/"
    try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)

    // Create matching files outside the requested subtree. Without SQL-level
    // path filtering, filename ordering plus LIMIT would select one of these.
    for i in 1...5 {
        try "data".write(toFile: tempDir + String(format: "match_%02d.txt", i), atomically: true, encoding: .utf8)
    }

    // Create one matching file inside the requested subtree.
    try "data".write(toFile: subDir + "match_target.txt", atomically: true, encoding: .utf8)

    let dbPath = tempDir + "cte_test.db"
    let config = IndexerConfiguration(roots: [URL(fileURLWithPath: tempDir)], databasePath: dbPath)
    let indexer = try FileIndexer(configuration: config)

    // Upsert all files.
    for i in 1...5 {
        try await indexer.upsert(path: tempDir + String(format: "match_%02d.txt", i))
    }
    try await indexer.upsert(path: subDir)
    try await indexer.upsert(path: subDir + "match_target.txt")

    // Query with pathPrefix = subDir and LIMIT = 1. All files match the term,
    // so the CTE must restrict the candidate set before LIMIT is applied.
    var query = QueryParser.parse("match path:\(subDir)")
    query.limit = 1
    query.sortOption = SortOption(field: .filename, direction: .ascending)

    let results = (try await indexer.query(query)).results
    #expect(results.count == 1)
    #expect(results[0].metadata.filename == "match_target.txt")
}

@Test("FileIndexer rebuild prunes excluded paths")
func rebuildPrunesExcludedPaths() async throws {
    let rawTempDir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: rawTempDir, withIntermediateDirectories: true)
    let tempDir = canonicalPath(for: rawTempDir) + "/"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let excludedDir = tempDir + "ExcludedDir/"
    try FileManager.default.createDirectory(atPath: excludedDir, withIntermediateDirectories: true)

    try "ok".write(toFile: tempDir + "keep.txt", atomically: true, encoding: .utf8)
    try "noop".write(toFile: excludedDir + "skip.txt", atomically: true, encoding: .utf8)

    let dbPath = tempDir + "pruning_test.db"
    let config = IndexerConfiguration(
        roots: [URL(fileURLWithPath: tempDir)],
        excludedPaths: [excludedDir],
        databasePath: dbPath,
        useFastVolumeScan: false
    )
    let indexer = try FileIndexer(configuration: config)

    // Trigger rebuilding (which scans the volume/root and prunes)
    try await indexer.rebuild()

    // Query all results
    let results = (try await indexer.query(QueryParser.parse(""))).results

    // keep.txt should exist, skip.txt should be pruned
    let filenames = results.map { $0.metadata.filename }
    #expect(filenames.contains("keep.txt"))
    #expect(!filenames.contains("skip.txt"))
}

@Test("FileIndexer resolvePath filters out corrupted structures, reports count, and back-fills results up to LIMIT")
func fileIndexerResolvePathInvalidStructures() async throws {
    let dbPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let db = try SQLiteDatabase(path: dbPath)

    // We create structural objects and entries directly in DB.
    try insertIndexedEntry(db, volume: "vol-1", fileID: 100, parentID: 9999, name: "missing_parent.txt", isDirectory: false, size: 10, modificationDate: Date().timeIntervalSince1970)
    try insertIndexedEntry(db, volume: "vol-1", fileID: 200, parentID: 201, name: "dirA", isDirectory: true, modificationDate: Date().timeIntervalSince1970)
    try insertIndexedEntry(db, volume: "vol-1", fileID: 201, parentID: 200, name: "dirB", isDirectory: true, modificationDate: Date().timeIntervalSince1970)
    try insertIndexedEntry(db, volume: "vol-1", fileID: 202, parentID: 200, name: "cycle.txt", isDirectory: false, size: 10, modificationDate: Date().timeIntervalSince1970)

    for i in 1...5 {
        try insertIndexedEntry(db, volume: "vol-1", fileID: Int64(300 + i), parentID: 2, name: "valid_\(i).txt", isDirectory: false, size: 10, modificationDate: Date().timeIntervalSince1970)
    }

    let config = IndexerConfiguration(roots: [URL(fileURLWithPath: "/tmp")], databasePath: dbPath)
    let indexer = try FileIndexer(configuration: config)

    // We search with limit = 3. Even though there are corrupt files, we expect to get exactly 3 valid results back-filled!
    var query = QueryParser.parse("valid")
    query.limit = 3
    let result = try await indexer.query(query)
    
    #expect(result.results.count == 3)
    let filenames = result.results.map { $0.metadata.filename }
    #expect(filenames.contains("valid_1.txt"))
    #expect(filenames.contains("valid_2.txt"))
    #expect(filenames.contains("valid_3.txt"))
    #expect(!filenames.contains("missing_parent.txt"))
    #expect(!filenames.contains("cycle.txt"))

    // Querying everything to check skipped counts
    let allResult = try await indexer.query(QueryParser.parse(""))
    #expect(allResult.skippedCorruptNodeCount == 4)
    #expect(allResult.firstCorruptionDescription != nil)
    
    let allFilenames = allResult.results.map { $0.metadata.filename }
    #expect(allFilenames.count == 5)
    #expect(!allFilenames.contains("missing_parent.txt"))
    #expect(!allFilenames.contains("cycle.txt"))

    // OFFSET is defined over valid results, not raw SQLite rows. Corrupt rows sort
    // before valid_* and must not consume the requested offset.
    var pagedQuery = QueryParser.parse("")
    pagedQuery.limit = 2
    pagedQuery.offset = 1
    pagedQuery.sortOption = SortOption(field: .filename, direction: .ascending)
    let pagedResult = try await indexer.query(pagedQuery)
    #expect(pagedResult.results.map { $0.metadata.filename } == ["valid_2.txt", "valid_3.txt"])
}

@Test("Unresolvable pathPrefix throws invalidPathPrefix error")
func unresolvablePathPrefixReturnsEmpty() async throws {
    let rawTempDir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: rawTempDir, withIntermediateDirectories: true)
    let tempDir = canonicalPath(for: rawTempDir) + "/"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let filePath = tempDir + "visible.txt"
    try "data".write(toFile: filePath, atomically: true, encoding: .utf8)

    let indexer = try FileIndexer(configuration: IndexerConfiguration(
        roots: [URL(fileURLWithPath: tempDir)],
        databasePath: tempDir + "invalid_prefix.db"
    ))
    try await indexer.upsert(path: filePath)

    let missingPath = tempDir + "does-not-exist/"
    let query = QueryParser.parse("visible path:\(missingPath)")
    await #expect(throws: FileIndexSearchError.self) {
        _ = try await indexer.query(query)
    }
}

@Test("Ripgrep reports an unavailable executable")
func ripgrepReportsUnavailableExecutable() async {
    let missingPath = NSTemporaryDirectory() + UUID().uuidString + "/rg"
    let searcher = RipgrepSearcher(configuration: RipgrepConfiguration(executablePath: missingPath))

    do {
        _ = try await searcher.search(query: QueryParser.parse("needle", mode: .contentOnly), roots: [URL(fileURLWithPath: NSTemporaryDirectory())])
        Issue.record("Expected executableUnavailable")
    } catch let error as RipgrepSearchError {
        #expect(error == .executableUnavailable(missingPath))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Ripgrep preserves bounded stderr and exit status")
func ripgrepPreservesBoundedStderr() async throws {
    let script = try makeExecutableScript(contents: """
    #!/bin/sh
    printf 'prefix-0123456789-error-detail' >&2
    exit 2
    """)
    defer { try? FileManager.default.removeItem(atPath: script) }

    let searcher = RipgrepSearcher(configuration: RipgrepConfiguration(
        executablePath: script,
        timeoutSeconds: 6,
        maximumStderrBytes: 12
    ))

    do {
        _ = try await searcher.search(query: QueryParser.parse("needle", mode: .contentOnly), roots: [URL(fileURLWithPath: NSTemporaryDirectory())])
        Issue.record("Expected failed exit status")
    } catch let error as RipgrepSearchError {
        guard case .failed(let exitCode, let stderr) = error else {
            Issue.record("Unexpected ripgrep error: \(error)")
            return
        }
        #expect(exitCode == 2)
        #expect(stderr == "error-detail")
    }
}

@Test("Ripgrep times out and terminates the child process")
func ripgrepTimesOut() async throws {
    let script = try makeExecutableScript(contents: """
    #!/bin/sh
    sleep 2
    exit 0
    """)
    defer { try? FileManager.default.removeItem(atPath: script) }

    let searcher = RipgrepSearcher(configuration: RipgrepConfiguration(
        executablePath: script,
        timeoutSeconds: 0.05
    ))

    do {
        _ = try await searcher.search(query: QueryParser.parse("needle", mode: .contentOnly), roots: [URL(fileURLWithPath: NSTemporaryDirectory())])
        Issue.record("Expected timeout")
    } catch let error as RipgrepSearchError {
        guard case .timedOut(let seconds) = error else {
            Issue.record("Unexpected ripgrep error: \(error)")
            return
        }
        #expect(seconds == 0.05)
    }
}

@Test("Ripgrep streams the first match before the process finishes")
func ripgrepStreamsIncrementally() async throws {
    let markerPath = NSTemporaryDirectory() + UUID().uuidString + ".done"
    let script = try makeExecutableScript(contents: """
    #!/bin/sh
    printf '%s\\n' '{"type":"match","data":{"path":{"text":"/tmp/first.txt"},"lines":{"text":"first\\n"},"line_number":1,"submatches":[{"start":0}]}}'
    sleep 2
    touch '\(markerPath)'
    printf '%s\\n' '{"type":"match","data":{"path":{"text":"/tmp/second.txt"},"lines":{"text":"second\\n"},"line_number":2,"submatches":[{"start":0}]}}'
    exit 0
    """)
    defer {
        try? FileManager.default.removeItem(atPath: script)
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    let searcher = RipgrepSearcher(configuration: RipgrepConfiguration(
        executablePath: script,
        timeoutSeconds: 15
    ))
    let stream = await searcher.stream(
        query: QueryParser.parse("needle", mode: .contentOnly),
        roots: [URL(fileURLWithPath: NSTemporaryDirectory())]
    )
    var iterator = stream.makeAsyncIterator()

    let first = try await iterator.next()
    #expect(first?.metadata.path == "/tmp/first.txt")
    #expect(!FileManager.default.fileExists(atPath: markerPath))

    let second = try await iterator.next()
    #expect(second?.metadata.path == "/tmp/second.txt")
    #expect(FileManager.default.fileExists(atPath: markerPath))
    #expect(try await iterator.next() == nil)
}

@Test("SearchCoordinator batches streaming updates while preserving the first result")
func searchCoordinatorBatchesStreamingUpdates() async throws {
    let rawTempDir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: rawTempDir, withIntermediateDirectories: true)
    let tempDir = canonicalPath(for: rawTempDir) + "/"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let jsonLines = (1...10).map { index in
        "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"/tmp/item_\(index).txt\"},\"lines\":{\"text\":\"match \(index)\\\\n\"},\"line_number\":\(index),\"submatches\":[{\"start\":0}]}}"
    }.joined(separator: "\n")
    let script = try makeExecutableScript(contents: """
    #!/bin/sh
    cat <<'JSON'
    \(jsonLines)
    JSON
    """)
    defer { try? FileManager.default.removeItem(atPath: script) }

    let indexer = try FileIndexer(configuration: IndexerConfiguration(
        roots: [URL(fileURLWithPath: tempDir)],
        databasePath: tempDir + "stream_batch.db"
    ))
    let searcher = RipgrepSearcher(configuration: RipgrepConfiguration(
        executablePath: script,
        timeoutSeconds: 15
    ))
    let coordinator = SearchCoordinator(
        indexer: indexer,
        ripgrepSearcher: searcher,
        roots: [URL(fileURLWithPath: tempDir)],
        streamBatchSize: 4,
        streamFlushInterval: .seconds(60)
    )

    let stream = await coordinator.searchStream(
        query: QueryParser.parse("match", mode: .contentOnly)
    )
    var responses: [SearchResponse] = []
    for await response in stream {
        responses.append(response)
    }

    #expect(responses.first?.results.isEmpty == true)
    #expect(responses.dropFirst().first?.results.count == 1)
    #expect(responses.last?.results.count == 10)
    #expect(responses.count == 5)
}

@Test("SearchCoordinator incrementally merges content into an indexed file")
func searchCoordinatorIncrementallyMergesIndexedFile() async throws {
    let rawTempDir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: rawTempDir, withIntermediateDirectories: true)
    let tempDir = canonicalPath(for: rawTempDir) + "/"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let filePath = tempDir + "needle-shared.txt"
    try "needle".write(toFile: filePath, atomically: true, encoding: .utf8)
    let escapedPath = filePath.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = try makeExecutableScript(contents: """
    #!/bin/sh
    cat <<'JSON'
    {"type":"match","data":{"path":{"text":"\(escapedPath)"},"lines":{"text":"needle\\n"},"line_number":1,"submatches":[{"start":0}]}}
    JSON
    """)
    defer { try? FileManager.default.removeItem(atPath: script) }

    let indexer = try FileIndexer(configuration: IndexerConfiguration(
        roots: [URL(fileURLWithPath: tempDir)],
        databasePath: tempDir + "incremental_merge.db"
    ))
    try await indexer.upsert(path: filePath)

    let coordinator = SearchCoordinator(
        indexer: indexer,
        ripgrepSearcher: RipgrepSearcher(configuration: RipgrepConfiguration(
            executablePath: script,
            timeoutSeconds: 15
        )),
        roots: [URL(fileURLWithPath: tempDir)]
    )

    let stream = await coordinator.searchStream(query: QueryParser.parse("needle", mode: .mixed))
    var finalResponse = SearchResponse(results: [], contentError: nil)
    for await response in stream {
        finalResponse = response
    }

    #expect(finalResponse.results.count == 1)
    #expect(finalResponse.results[0].source.contains(.filenameIndex))
    #expect(finalResponse.results[0].source.contains(.contentRipgrep))
    #expect(finalResponse.results[0].contentMatches.count == 1)
}

@Test("Ripgrep decodes JSON match output")
func ripgrepDecodesJSONMatchOutput() async throws {
    let script = try makeExecutableScript(contents: """
    #!/bin/sh
    printf '%s\\n' '{"type":"match","data":{"path":{"text":"/tmp/example.txt"},"lines":{"text":"hello needle\\n"},"line_number":7,"submatches":[{"start":6}]}}'
    exit 0
    """)
    defer { try? FileManager.default.removeItem(atPath: script) }

    let searcher = RipgrepSearcher(configuration: RipgrepConfiguration(
        executablePath: script,
        timeoutSeconds: 6
    ))
    let results = try await searcher.search(
        query: QueryParser.parse("needle", mode: .contentOnly),
        roots: [URL(fileURLWithPath: NSTemporaryDirectory())]
    )

    #expect(results[0].contentMatches.first?.column == 6)
}

@Test("Character mask supports ASCII letters and digits")
func characterMaskSupportsASCIIAndDigits() {
    let mask = FuzzyMatcher.characterMask(for: "abc123")
    let qMask = FuzzyMatcher.characterMask(for: "abc")
    let invalidQ = FuzzyMatcher.characterMask(for: "xyz")

    #expect((mask & qMask) == qMask)
    #expect((mask & invalidQ) != invalidQ)
}

@Test("Character mask never rejects a valid fuzzy subsequence")
func characterMaskNeverRejectsFuzzySubsequence() {
    let text = "ApplicationCache"
    let query = "apc"

    let textMask = FuzzyMatcher.characterMask(for: text)
    let queryMask = FuzzyMatcher.characterMask(for: query)

    #expect((textMask & queryMask) == queryMask)
}

@Test("Repeated query characters are validated by fuzzy scoring")
func repeatedQueryCharactersValidatedByFuzzyScoring() {
    let query = FuzzyMatcher.prepare(query: "app", caseSensitive: false)
    let score = FuzzyMatcher.score(preparedQuery: query, candidate: "ap")
    #expect(score == nil)
}

@Test("Unicode candidate survives character-mask prefilter")
func unicodeCandidateSurvivesMaskPrefilter() {
    let text = "我的文件_report"
    let textMask = FuzzyMatcher.characterMask(for: text)
    let queryMask = FuzzyMatcher.characterMask(for: "文件")

    #expect((textMask & queryMask) == queryMask)
}

@Test("Fuzzy scoring ranks exact matches, prefix matches, and subsequence compactness")
func fuzzyScoringRanksCorrectly() {
    let q = FuzzyMatcher.prepare(query: "report", caseSensitive: false)

    let exact = FuzzyMatcher.score(preparedQuery: q, candidate: "report") ?? 0
    let prefix = FuzzyMatcher.score(preparedQuery: q, candidate: "report_july.txt") ?? 0
    let sub = FuzzyMatcher.score(preparedQuery: q, candidate: "july_report.txt") ?? 0
    let sparse = FuzzyMatcher.score(preparedQuery: q, candidate: "r_e_p_o_r_t_long.txt") ?? 0

    #expect(exact > prefix)
    #expect(prefix > sub)
    #expect(sub > sparse)
}

@Test("SQLite FUZZY_SCORE function tests")
func sqliteFuzzyScoreFunctionTests() throws {
    let dbPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let db = try SQLiteDatabase(path: dbPath)

    // Test match
    let rows = try db.query(sql: "SELECT FUZZY_SCORE(?, ?, ?) as score;", bindings: ["apc", "ApplicationCache", false])
    #expect(rows.first?["score"] is Int64)

    // Test non-match
    let rowsNoMatch = try db.query(sql: "SELECT FUZZY_SCORE(?, ?, ?) as score;", bindings: ["xyz", "ApplicationCache", false])
    #expect(rowsNoMatch.first?["score"] is NSNull)

    // Test that auxdata updates correctly when case-sensitivity changes or when query changes
    // within the same query execution statement.
    try db.execute(sql: "CREATE TABLE test_scores (name TEXT, case_flag INTEGER);")
    try db.execute(sql: "INSERT INTO test_scores (name, case_flag) VALUES ('abc', 0);")
    try db.execute(sql: "INSERT INTO test_scores (name, case_flag) VALUES ('abc', 1);")

    let rowsMixed = try db.query(sql: "SELECT FUZZY_SCORE('ABC', name, case_flag) as score FROM test_scores;")
    #expect(rowsMixed.count == 2)
    #expect(rowsMixed[0]["score"] is Int64)  // case_flag = 0 -> case insensitive match -> positive score
    #expect(rowsMixed[1]["score"] is NSNull) // case_flag = 1 -> case sensitive match -> no match (NULL)
}

@Test("Relevance scorer correctly ranks hybrid and base scores")
func relevanceScorerRanksCorrectly() {
    let query = QueryParser.parse("ApplicationCache")

    let meta = FileMetadata(path: "/a/ApplicationCache", filename: "ApplicationCache", fileExtension: "", size: 100, modificationDate: Date(), fileID: 1, uti: nil)

    let onlyFilename = SearchResult(metadata: meta, source: [.filenameIndex])
    let onlyContent = SearchResult(metadata: meta, source: [.contentRipgrep], contentMatches: [ContentMatch(line: 5, column: 10, text: "ApplicationCache")])
    let hybrid = SearchResult(metadata: meta, source: [.filenameIndex, .contentRipgrep], contentMatches: [ContentMatch(line: 5, column: 10, text: "ApplicationCache")])

    let scoreFilename = SearchRelevanceScorer.score(result: onlyFilename, query: query)
    let scoreContent = SearchRelevanceScorer.score(result: onlyContent, query: query)
    let scoreHybrid = SearchRelevanceScorer.score(result: hybrid, query: query)

    #expect(scoreHybrid > scoreFilename)
    #expect(scoreHybrid > scoreContent)
}

@Test("SearchCoordinator caps content matches at 10 to avoid bloat")
func searchCoordinatorCapsContentMatches() async throws {
    let dbPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let config = IndexerConfiguration(roots: [URL(fileURLWithPath: NSTemporaryDirectory())], databasePath: dbPath)
    let indexer = try FileIndexer(configuration: config)
    let searcher = RipgrepSearcher(configuration: RipgrepConfiguration(executablePath: "rg"))

    let coordinator = SearchCoordinator(
        indexer: indexer,
        ripgrepSearcher: searcher,
        roots: [URL(fileURLWithPath: NSTemporaryDirectory())],
        policy: SearchExecutionPolicy(maximumContentMatchesPerFile: 10)
    )

    let meta = FileMetadata(path: "/a/test.txt", filename: "test.txt", fileExtension: "txt", size: 10, modificationDate: Date(), fileID: 10, uti: nil)
    var items: [SearchResult] = []
    for i in 1...15 {
        items.append(SearchResult(metadata: meta, source: [.contentRipgrep], contentMatches: [ContentMatch(line: i, column: 1, text: "match")]))
    }

    let merged = coordinator.merge(index: [], content: items, query: QueryParser.parse("match"))
    #expect(merged.count == 1)
    #expect(merged[0].contentMatches.count == 10)
    #expect(merged[0].totalContentMatchCount == 15)
}

@Test("Hardlinks keep distinct searchable entries and delete independently")
func hardlinkIndexingAndRemoval() async throws {
    let root = NSTemporaryDirectory() + UUID().uuidString + "/"
    let dirA = root + "A/"
    let dirB = root + "B/"
    try FileManager.default.createDirectory(atPath: dirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: dirB, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }

    let original = dirA + "report.txt"
    let linked = dirB + "report-copy.txt"
    try "shared content".write(toFile: original, atomically: true, encoding: .utf8)
    try FileManager.default.linkItem(atPath: original, toPath: linked)

    let dbPath = root + "hardlinks.db"
    let indexer = try FileIndexer(configuration: IndexerConfiguration(
        roots: [URL(fileURLWithPath: root)],
        databasePath: dbPath,
        useFastVolumeScan: false
    ))
    try await indexer.upsert(path: dirA)
    try await indexer.upsert(path: dirB)
    try await indexer.upsert(path: original)
    try await indexer.upsert(path: linked)

    let all = (try await indexer.query(QueryParser.parse(""))).results
        .filter { $0.metadata.filename.hasPrefix("report") }
    #expect(all.count == 2)
    #expect(Set(all.compactMap(\.metadata.fileID)).count == 1)
    #expect(Set(all.compactMap(\.metadata.entryID)).count == 2)
    #expect((try await indexer.query(QueryParser.parse("report-copy"))).results.map(\.metadata.path).contains(canonicalPath(for: linked)))

    let db = try SQLiteDatabase(path: dbPath)
    let objectCount = try db.query(sql: "SELECT COUNT(*) AS count FROM fs_objects WHERE file_id = ?;", bindings: [Int64(bitPattern: all[0].metadata.fileID!)])
    let entryCount = try db.query(sql: "SELECT COUNT(*) AS count FROM fs_entries WHERE target_file_id = ?;", bindings: [Int64(bitPattern: all[0].metadata.fileID!)])
    #expect(objectCount.first?["count"] as? Int64 == 1)
    #expect(entryCount.first?["count"] as? Int64 == 2)

    try FileManager.default.removeItem(atPath: original)
    try await indexer.remove(path: original)
    #expect((try await indexer.query(QueryParser.parse("report-copy"))).results.count == 1)
    let remainingEntries = try db.query(sql: "SELECT COUNT(*) AS count FROM fs_entries WHERE target_file_id = ?;", bindings: [Int64(bitPattern: all[0].metadata.fileID!)])
    #expect(remainingEntries.first?["count"] as? Int64 == 1)

    try FileManager.default.removeItem(atPath: linked)
    try await indexer.remove(path: linked)
    let remainingObjects = try db.query(sql: "SELECT COUNT(*) AS count FROM fs_objects WHERE file_id = ?;", bindings: [Int64(bitPattern: all[0].metadata.fileID!)])
    #expect(remainingObjects.first?["count"] as? Int64 == 0)
}

@Test("Benchmark fuzzy query with bitmask pre-filtering on 10000 synthetic rows")
func benchmarkFuzzyBitmaskQuery() async throws {
    let dbPath = NSTemporaryDirectory() + UUID().uuidString + "_bench.db"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let config = IndexerConfiguration(roots: [URL(fileURLWithPath: NSTemporaryDirectory())], databasePath: dbPath)
    let db = try SQLiteDatabase(path: dbPath)
    var items: [[Any]] = []

    let now = Date().timeIntervalSince1970
    items.append([
        "vol-1",
        Int64(1),
        Int64(2),
        "ApplicationCache",
        Int64(bitPattern: FuzzyMatcher.characterMask(for: "ApplicationCache")),
        Int64(0),
        "cache",
        Int64(1024),
        now,
        "public.data"
    ])

    for i in 2...10000 {
        let name = "file_\(i)_random_name_\(UUID().uuidString.prefix(8)).txt"
        let mask = FuzzyMatcher.characterMask(for: name)
        items.append([
            "vol-1",
            Int64(i),
            Int64(2),
            name,
            Int64(bitPattern: mask),
            Int64(0),
            "txt",
            Int64(100),
            now,
            "public.text"
        ])
    }

    let objectItems = items.map { row in [row[0], row[1], row[5], row[6], row[7], row[8], row[9]] }
    let entryItems = items.map { row in [row[0], row[2], row[1], row[3], row[4]] }
    try db.executeBatch(sql: "INSERT INTO fs_objects (volume_uuid, file_id, is_directory, file_extension, size, modification_date, uti) VALUES (?, ?, ?, ?, ?, ?, ?);", items: objectItems)
    try db.executeBatch(sql: "INSERT INTO fs_entries (volume_uuid, parent_file_id, target_file_id, name, name_character_mask) VALUES (?, ?, ?, ?, ?);", items: entryItems)

    let activeIndexer = try FileIndexer(configuration: config)

    let start = DispatchTime.now()

    let query = SearchQuery(raw: "apc", terms: ["apc"], filenameMatchMode: .fuzzy, limit: 100)
    let results = (try await activeIndexer.query(query)).results

    let end = DispatchTime.now()
    let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
    let timeInterval = Double(nanoTime) / 1_000_000.0

    print("Benchmark complete: fuzzy search took \(timeInterval) ms")

    #expect(results.count >= 1)
    #expect(results[0].metadata.filename == "ApplicationCache")
    #expect(timeInterval < 50.0)
}

@Test("Case-sensitive fuzzy search is not rejected by the persisted mask")
func caseSensitiveFuzzyMaskIsSafe() async throws {
    let dir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "ABC.txt"
    try "x".write(toFile: path, atomically: true, encoding: .utf8)
    let indexer = try FileIndexer(configuration: IndexerConfiguration(roots: [URL(fileURLWithPath: dir)], databasePath: dir + "case.db"))
    try await indexer.upsert(path: path)
    let query = SearchQuery(raw: "ABC", terms: ["ABC"], isCaseSensitive: true, mode: .filenameOnly, filenameMatchMode: .fuzzy, limit: 10)
    let results = (try await indexer.query(query)).results
    #expect(results.map(\.metadata.filename).contains("ABC.txt"))
}

@Test("Multi-token fuzzy search scores tokens independently")
func multiTokenFuzzySearch() async throws {
    let dir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "ApplicationCache.txt"
    try "x".write(toFile: path, atomically: true, encoding: .utf8)
    let indexer = try FileIndexer(configuration: IndexerConfiguration(roots: [URL(fileURLWithPath: dir)], databasePath: dir + "tokens.db"))
    try await indexer.upsert(path: path)
    let query = SearchQuery(raw: "app cache", terms: ["app", "cache"], mode: .filenameOnly, filenameMatchMode: .fuzzy, limit: 10)
    let results = (try await indexer.query(query)).results
    #expect(results.count == 1)
    #expect(results[0].metadata.filename == "ApplicationCache.txt")
}

@Test("Coordinator preserves explicit offset and limit after relevance sorting")
func coordinatorPreservesPaging() async throws {
    let dir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for name in ["report.txt", "report-old.txt", "my-report.txt"] { try "x".write(toFile: dir + name, atomically: true, encoding: .utf8) }
    let indexer = try FileIndexer(configuration: IndexerConfiguration(roots: [URL(fileURLWithPath: dir)], databasePath: dir + "paging.db"))
    for name in ["report.txt", "report-old.txt", "my-report.txt"] { try await indexer.upsert(path: dir + name) }
    let coordinator = SearchCoordinator(indexer: indexer, ripgrepSearcher: RipgrepSearcher(configuration: RipgrepConfiguration(executablePath: "/missing/rg")), roots: [URL(fileURLWithPath: dir)])
    var query = SearchQuery(raw: "report", terms: ["report"], mode: .filenameOnly, filenameMatchMode: .fuzzy, limit: 1, offset: 1)
    query.sortOption = SortOption(field: .relevance, direction: .descending)
    let response = await coordinator.search(query: query)
    #expect(response.results.count == 1)
    #expect(response.results[0].metadata.filename == "report-old.txt")
}

@Test("Coordinator exposes file-index query errors")
func coordinatorExposesIndexErrors() async throws {
    let dir = NSTemporaryDirectory() + UUID().uuidString + "/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let indexer = try FileIndexer(configuration: IndexerConfiguration(roots: [URL(fileURLWithPath: dir)], databasePath: dir + "errors.db"))
    let coordinator = SearchCoordinator(indexer: indexer, ripgrepSearcher: RipgrepSearcher(configuration: RipgrepConfiguration(executablePath: "/missing/rg")), roots: [URL(fileURLWithPath: dir)])
    let query = SearchQuery(raw: "x", terms: ["x"], pathPrefix: dir + "missing", mode: .filenameOnly)
    let response = await coordinator.search(query: query)
    #expect(response.indexError == .invalidPathPrefix(dir + "missing"))
}

@Test("QueryParser parses paging and sort directives")
func queryParserParsesPagingAndSort() {
    let query = QueryParser.parse("report fuzzy:true sort:size order:desc limit:25 offset:50")
    #expect(query.filenameMatchMode == .fuzzy)
    #expect(query.sortOption == SortOption(field: .size, direction: .descending))
    #expect(query.limit == 25)
    #expect(query.offset == 50)
    #expect(query.terms == ["report"])
}

@Test("Unicode case-folded masks remain compatible")
func unicodeCaseFoldedMasksRemainCompatible() {
    let candidate = FuzzyMatcher.characterMask(for: "Ärger", caseSensitive: false)
    let query = FuzzyMatcher.characterMask(for: "är", caseSensitive: false)
    #expect((candidate & query) == query)
}
