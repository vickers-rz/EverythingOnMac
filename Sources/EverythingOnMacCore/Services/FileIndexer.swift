import Foundation
import CSearchFS

public struct IndexerConfiguration: Sendable {
    public var roots: [URL]
    public var excludedPaths: [String]
    public var databasePath: String?
    public var useFastVolumeScan: Bool

    public init(
        roots: [URL],
        excludedPaths: [String] = [],
        databasePath: String? = nil,
        useFastVolumeScan: Bool = true
    ) {
        self.roots = roots
        self.excludedPaths = excludedPaths
        self.databasePath = databasePath
        self.useFastVolumeScan = useFastVolumeScan
    }
}

// Helper class for collecting searchfs callbacks
private final class ScanContext {
    var matches: [[Any]] = []
    var writeError: Error?
    var isCancelled = false
    let volumeUUID: String
    let database: SQLiteDatabase

    init(volumeUUID: String, database: SQLiteDatabase) {
        self.volumeUUID = volumeUUID
        self.database = database
    }

    func flush() {
        guard writeError == nil, !matches.isEmpty else { return }
        let sql = "INSERT OR REPLACE INTO fs_nodes (volume_uuid, file_id, parent_id, name, name_character_mask, is_directory, file_extension, size, modification_date, uti) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
        do {
            try database.executeBatch(sql: sql, items: matches)
            matches.removeAll(keepingCapacity: true)
        } catch {
            writeError = error
        }
    }
}

public enum FileIndexSearchError: Error, Sendable, Equatable, LocalizedError {
    case invalidPathPrefix(String)
    case databaseError(String)
    case indexCorrupted(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPathPrefix(let path):
            return "无法解析搜索路径：\(path)"
        case .databaseError(let message):
            return "文件索引查询失败：\(message)"
        case .indexCorrupted(let message):
            return "文件索引结构损坏：\(message)"
        }
    }
}

public actor FileIndexer {
    private let configuration: IndexerConfiguration
    private let database: SQLiteDatabase
    
    // Cache for directory nodes: [volume_uuid: [file_id: (parent_id, name)]]
    private var directoryCache: [String: [UInt64: (parentID: UInt64, name: String)]] = [:]
    
    // Map from volume_uuid to its mount point path
    private var volumeMountPoints: [String: String] = [:]

    public init(configuration: IndexerConfiguration) throws {
        self.configuration = configuration
        let dbPath = configuration.databasePath ?? Self.defaultDatabasePath()
        self.database = try SQLiteDatabase(path: dbPath)
        
        // Resolve volume UUIDs and physical mount points when available.
        for root in configuration.roots {
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
            let volumeUUID = values?.volumeUUIDString ?? root.path
            self.volumeMountPoints[volumeUUID] = Self.realMountPoint(for: root.path) ?? root.path
        }
    }

    private static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("EverythingOnMac/everything.db").path
    }

    private func ensureCacheLoaded() async {
        guard directoryCache.isEmpty else { return }
        
        // 1. Pre-cache ancestors of configuration roots so path resolution can walk to "/"
        for root in configuration.roots {
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
            let volumeUUID = values?.volumeUUIDString ?? root.path
            cacheAncestors(of: root, volumeUUID: volumeUUID)
        }
        
        // 2. Load all directories from SQLite
        let sql = "SELECT volume_uuid, file_id, parent_id, name FROM fs_nodes WHERE is_directory = 1;"
        if let rows = try? database.query(sql: sql) {
            for row in rows {
                guard let volumeUUID = row["volume_uuid"] as? String,
                      let fileIDVal = row["file_id"] as? Int64,
                      let parentIDVal = row["parent_id"] as? Int64,
                      let name = row["name"] as? String else {
                    continue
                }
                
                let fileID = UInt64(bitPattern: fileIDVal)
                let parentID = UInt64(bitPattern: parentIDVal)
                
                if directoryCache[volumeUUID] == nil {
                    directoryCache[volumeUUID] = [:]
                }
                directoryCache[volumeUUID]?[fileID] = (parentID, name)
            }
        }
    }

    private func resetCache() async {
        directoryCache.removeAll()
        await ensureCacheLoaded()
    }

    private func cacheAncestors(of root: URL, volumeUUID: String) {
        var current = root
        while current.path != "/" && current.path != "" {
            guard let values = try? current.resourceValues(forKeys: [.fileResourceIdentifierKey, .parentDirectoryURLKey]),
                  let fileID = normalizeFileID(values.fileResourceIdentifier) else {
                break
            }
            
            let parentURL = values.parentDirectory ?? current.deletingLastPathComponent()
            let parentID: UInt64
            if let parentValues = try? parentURL.resourceValues(forKeys: [URLResourceKey.fileResourceIdentifierKey]),
               let pID = normalizeFileID(parentValues.fileResourceIdentifier) {
                parentID = pID
            } else {
                parentID = 2 // default to volume root
            }
            
            let name = current.lastPathComponent
            
            if directoryCache[volumeUUID] == nil {
                directoryCache[volumeUUID] = [:]
            }
            directoryCache[volumeUUID]?[fileID] = (parentID, name)
            
            current = parentURL
        }
    }

    private func resolvePath(volumeUUID: String, parentID: UInt64, name: String) throws -> String {
        var parts: [String] = [name]
        var currentParent = parentID
        var depth = 0
        var visited = Set<UInt64>()

        while currentParent != 0 && currentParent != 2 {
            guard depth < 100 else {
                throw FileIndexSearchError.indexCorrupted(
                    "节点 \(name) 的父目录层级超过 100。"
                )
            }
            guard visited.insert(currentParent).inserted else {
                throw FileIndexSearchError.indexCorrupted(
                    "节点 \(name) 的父目录链存在循环引用。"
                )
            }
            guard let node = directoryCache[volumeUUID]?[currentParent] else {
                throw FileIndexSearchError.indexCorrupted(
                    "节点 \(name) 缺少父目录 \(currentParent)。"
                )
            }
            parts.append(node.name)
            currentParent = node.parentID
            depth += 1
        }

        let relativePath = parts.reversed().joined(separator: "/")
        let mountPoint = volumeMountPoints[volumeUUID] ?? ""

        let fullPath: String
        if mountPoint == "/" {
            fullPath = "/" + relativePath
        } else {
            fullPath = mountPoint + "/" + relativePath
        }

        if fullPath.hasPrefix("/System/Volumes/Data/") {
            return String(fullPath.dropFirst("/System/Volumes/Data".count))
        } else if fullPath == "/System/Volumes/Data" {
            return "/"
        }

        return fullPath
    }

    public func rebuild() async throws {
        try Task.checkCancellation()
        // Clear nodes table
        try database.execute(sql: "DELETE FROM fs_nodes;")
        directoryCache.removeAll()

        // Re-cache ancestors
        for root in configuration.roots {
            try Task.checkCancellation()
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
            let volumeUUID = values?.volumeUUIDString ?? root.path
            cacheAncestors(of: root, volumeUUID: volumeUUID)
        }

        var scannedVolumes = Set<String>()
        for root in configuration.roots {
            try Task.checkCancellation()
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
            let volumeUUID = values?.volumeUUIDString ?? root.path
            
            guard !scannedVolumes.contains(volumeUUID) else { continue }
            scannedVolumes.insert(volumeUUID)
            
            let rootsOnThisVolume = configuration.roots.filter { candidate in
                let values = try? candidate.resourceValues(forKeys: [.volumeUUIDStringKey])
                return (values?.volumeUUIDString ?? candidate.path) == volumeUUID
            }

            guard configuration.useFastVolumeScan,
                  let physicalMountPoint = Self.realMountPoint(for: root.path) else {
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: rootsOnThisVolume)
                continue
            }

            let scanCtx = ScanContext(volumeUUID: volumeUUID, database: database)
            let contextPointer = Unmanaged.passUnretained(scanCtx).toOpaque()

            let errCode = scan_volume_catalog(physicalMountPoint, { fileID, parentID, namePtr, isDir, size, modDate, ctxPointer in
                guard let ctxPointer = ctxPointer else { return }
                let ctx = Unmanaged<ScanContext>.fromOpaque(ctxPointer).takeUnretainedValue()
                if Task.isCancelled {
                    ctx.isCancelled = true
                    ctx.matches.removeAll(keepingCapacity: false)
                    return
                }
                guard !ctx.isCancelled else { return }

                let name = namePtr.map { String(cString: $0) } ?? ""
                let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""

                let mask = FuzzyMatcher.characterMask(for: name, caseSensitive: false)
                ctx.matches.append([
                    ctx.volumeUUID,
                    Int64(bitPattern: fileID),
                    Int64(bitPattern: parentID),
                    name,
                    Int64(bitPattern: mask),
                    isDir,
                    ext,
                    size,
                    modDate,
                    NSNull()
                ])

                if ctx.matches.count >= 10000 {
                    ctx.flush()
                }
            }, contextPointer)

            if scanCtx.isCancelled {
                throw CancellationError()
            }
            try Task.checkCancellation()

            guard errCode == 0 else {
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: rootsOnThisVolume)
                continue
            }

            scanCtx.flush()
            if let writeError = scanCtx.writeError {
                throw writeError
            }
            try Task.checkCancellation()
            let rootIDs = rootsOnThisVolume.compactMap { candidate -> UInt64? in
                let values = try? candidate.resourceValues(forKeys: [.fileResourceIdentifierKey])
                return normalizeFileID(values?.fileResourceIdentifier)
            }

            guard rootIDs.count == rootsOnThisVolume.count else {
                // A partial root-ID result is unsafe because pruning would silently omit unresolved roots.
                try? database.execute(sql: "DELETE FROM fs_nodes WHERE volume_uuid = ?;", bindings: [volumeUUID])
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: rootsOnThisVolume)
                continue
            }

            do {
                try Task.checkCancellation()
                try pruneDatabase(volumeUUID: volumeUUID, rootIDs: rootIDs)
                try Task.checkCancellation()
                try pruneExcludedPaths(volumeUUID: volumeUUID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Never keep a partially pruned volume index.
                try? database.execute(sql: "DELETE FROM fs_nodes WHERE volume_uuid = ?;", bindings: [volumeUUID])
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: rootsOnThisVolume)
            }
        }

        try Task.checkCancellation()
        await resetCache()
    }

    public func query(_ query: SearchQuery) async throws -> [SearchResult] {
        await ensureCacheLoaded()

        let columns = "volume_uuid, file_id, parent_id, name, is_directory, file_extension, size, modification_date, uti"
        var cte = ""
        var cteBindings: [Any] = []
        var predicates = ["1=1"]
        var predicateBindings: [Any] = []

        if let rawPathPrefix = query.pathPrefix {
            let pathPrefix = Self.canonicalUserPath(rawPathPrefix)
            guard FileManager.default.fileExists(atPath: pathPrefix),
                  let values = try? URL(fileURLWithPath: pathPrefix).resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeUUIDStringKey]),
                  let prefixFID = normalizeFileID(values.fileResourceIdentifier),
                  let prefixVol = values.volumeUUIDString else {
                throw FileIndexSearchError.invalidPathPrefix(rawPathPrefix)
            }
            cte = """
            WITH RECURSIVE path_descendants(fid) AS (
                SELECT ?
                UNION ALL
                SELECT n.file_id FROM fs_nodes n
                JOIN path_descendants p ON n.parent_id = p.fid AND n.volume_uuid = ?
            )
            """
            cteBindings += [Int64(bitPattern: prefixFID), prefixVol]
            predicates += [
                "volume_uuid = ?",
                "(parent_id IN (SELECT fid FROM path_descendants) OR file_id IN (SELECT fid FROM path_descendants))"
            ]
            predicateBindings.append(prefixVol)
        }

        if !query.fileExtensions.isEmpty {
            let extensions = query.fileExtensions.map { $0.lowercased() }.sorted()
            predicates.append("file_extension IN (\(Array(repeating: "?", count: extensions.count).joined(separator: ", ")))")
            predicateBindings.append(contentsOf: extensions)
        }

        for excluded in query.excludedTerms {
            predicates.append(query.isCaseSensitive ? "name NOT GLOB ?" : "name NOT LIKE ?")
            predicateBindings.append(query.isCaseSensitive ? "*\(excluded)*" : "%\(excluded)%")
        }

        if let value = query.minSize, let op = query.minSizeOp { predicates.append("size \(op) ?"); predicateBindings.append(value) }
        if let value = query.maxSize, let op = query.maxSizeOp { predicates.append("size \(op) ?"); predicateBindings.append(value) }
        if let value = query.minDate, let op = query.minDateOp { predicates.append("modification_date \(op) ?"); predicateBindings.append(value.timeIntervalSince1970) }
        if let value = query.maxDate, let op = query.maxDateOp { predicates.append("modification_date \(op) ?"); predicateBindings.append(value.timeIntervalSince1970) }
        if let uti = query.utiFilter, !uti.isEmpty { predicates.append("uti LIKE ?"); predicateBindings.append("%\(uti)%") }

        let terms = query.terms.filter { !$0.isEmpty }
        var scoreBindings: [Any] = []
        var fuzzyScoreExpression: String?

        switch query.filenameMatchMode {
        case .fuzzy where !terms.isEmpty:
            let combinedMask = terms.reduce(UInt64(0)) {
                $0 | FuzzyMatcher.characterMask(for: $1, caseSensitive: false)
            }
            predicates.append("(name_character_mask & ?) = ?")
            predicateBindings += [Int64(bitPattern: combinedMask), Int64(bitPattern: combinedMask)]
            fuzzyScoreExpression = terms.map { _ in "FUZZY_SCORE(?, name, ?)" }.joined(separator: " + ")
            for term in terms { scoreBindings += [term, query.isCaseSensitive] }
        case .regex:
            for term in terms { predicates.append("REGEXP_LIKE(?, name, ?)"); predicateBindings += [term, query.isCaseSensitive] }
        case .literal:
            for term in terms {
                predicates.append(query.isCaseSensitive ? "name GLOB ?" : "name LIKE ?")
                predicateBindings.append(query.isCaseSensitive ? "*\(term)*" : "%\(term)%")
            }
        case .fuzzy:
            break
        }

        let whereSQL = predicates.joined(separator: " AND ")
        var sql: String
        var bindings = cteBindings
        if let fuzzyScoreExpression {
            sql = "SELECT * FROM (SELECT \(columns), \(fuzzyScoreExpression) AS fuzzy_score FROM fs_nodes WHERE \(whereSQL)) WHERE fuzzy_score IS NOT NULL"
            bindings += scoreBindings + predicateBindings
        } else {
            sql = "SELECT \(columns) FROM fs_nodes WHERE \(whereSQL)"
            bindings += predicateBindings
        }

        if let sort = query.sortOption, sort.field != .relevance {
            let field: String
            switch sort.field {
            case .relevance: field = fuzzyScoreExpression == nil ? "name" : "fuzzy_score"
            case .path: field = "name"
            case .filename: field = "name"
            case .size: field = "size"
            case .modificationDate: field = "modification_date"
            }
            sql += " ORDER BY \(field) \(sort.direction == .ascending ? "ASC" : "DESC"), name ASC"
        } else if fuzzyScoreExpression != nil {
            sql += " ORDER BY fuzzy_score DESC, name ASC"
        } else {
            sql += " ORDER BY name ASC"
        }

        let requestedLimit = max(1, query.limit ?? 5_000)
        sql += " LIMIT ?"
        bindings.append(requestedLimit)
        if let offset = query.offset, offset > 0, query.sortOption?.field != .path {
            sql += " OFFSET ?"
            bindings.append(offset)
        }
        sql += ";"

        do {
            let rows = try database.query(sql: cte.isEmpty ? sql : cte + "\n" + sql, bindings: bindings)
            var results: [SearchResult] = []
            results.reserveCapacity(rows.count)

            for row in rows {
                try Task.checkCancellation()
                guard let volumeUUID = row["volume_uuid"] as? String,
                      let fileIDValue = row["file_id"] as? Int64,
                      let parentIDValue = row["parent_id"] as? Int64,
                      let name = row["name"] as? String,
                      row["is_directory"] is Int64 else {
                    throw FileIndexSearchError.indexCorrupted(
                        "查询结果包含缺失必要字段的节点。"
                    )
                }

                let fullPath = try resolvePath(
                    volumeUUID: volumeUUID,
                    parentID: UInt64(bitPattern: parentIDValue),
                    name: name
                )
                if let rawPrefix = query.pathPrefix {
                    let prefix = Self.canonicalUserPath(rawPrefix)
                    let path = Self.canonicalUserPath(fullPath)
                    let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
                    let normalizedPath = path.hasSuffix("/") ? path : path + "/"
                    guard normalizedPath.hasPrefix(normalizedPrefix) || path == prefix else { continue }
                }
                guard !shouldExclude(fullPath) else { continue }

                results.append(SearchResult(
                    metadata: FileMetadata(
                        path: fullPath,
                        filename: name,
                        fileExtension: row["file_extension"] as? String ?? "",
                        size: row["size"] as? Int64 ?? 0,
                        modificationDate: (row["modification_date"] as? Double).map(Date.init(timeIntervalSince1970:)),
                        fileID: UInt64(bitPattern: fileIDValue),
                        uti: row["uti"] as? String
                    ),
                    source: [.filenameIndex]
                ))
            }

            if let sort = query.sortOption, sort.field == .path {
                results.sort { sort.direction == .ascending ? $0.metadata.path < $1.metadata.path : $0.metadata.path > $1.metadata.path }
                if let offset = query.offset, offset > 0 {
                    results = offset < results.count ? Array(results.dropFirst(offset)) : []
                }
            }
            return results
        } catch let error as FileIndexSearchError {
            throw error
        } catch {
            throw FileIndexSearchError.databaseError(error.localizedDescription)
        }
    }

    public func itemCount() async -> Int {
        let sql = "SELECT COUNT(*) as count FROM fs_nodes;"
        if let row = try? database.query(sql: sql).first,
           let count = row["count"] as? Int64 {
            return Int(count)
        }
        return 0
    }

    public func upsert(path: String) async throws {
        await ensureCacheLoaded()

        guard !shouldExclude(path) else {
            try await remove(path: path)
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey, .volumeUUIDStringKey, .parentDirectoryURLKey]
        
        guard let values = try? fileURL.resourceValues(forKeys: keys) else {
            try await remove(path: path)
            return
        }
        
        let isDir = values.isDirectory == true
        let isReg = values.isRegularFile == true
        guard isDir || isReg else { return }
        
        let volumeUUID = values.volumeUUIDString ?? fileURL.deletingLastPathComponent().path
        guard let fileID = normalizeFileID(values.fileResourceIdentifier) else { return }
        
        let parentID: UInt64
        if let parentURL = values.parentDirectory ?? (fileURL.path == "/" ? nil : fileURL.deletingLastPathComponent()),
           let parentValues = try? parentURL.resourceValues(forKeys: [URLResourceKey.fileResourceIdentifierKey]),
           let pID = normalizeFileID(parentValues.fileResourceIdentifier) {
            parentID = pID
        } else {
            parentID = 2
        }
        
        let name = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let size = isDir ? 0 : Int64(values.fileSize ?? 0)
        let modDate = values.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let uti = values.typeIdentifier
        
        let mask = FuzzyMatcher.characterMask(for: name, caseSensitive: false)
        let sql = "INSERT OR REPLACE INTO fs_nodes (volume_uuid, file_id, parent_id, name, name_character_mask, is_directory, file_extension, size, modification_date, uti) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
        try database.execute(sql: sql, bindings: [
            volumeUUID,
            Int64(bitPattern: fileID),
            Int64(bitPattern: parentID),
            name,
            Int64(bitPattern: mask),
            isDir ? 1 : 0,
            ext,
            size,
            modDate,
            uti ?? NSNull()
        ])
        
        if isDir {
            if directoryCache[volumeUUID] == nil {
                directoryCache[volumeUUID] = [:]
            }
            directoryCache[volumeUUID]?[fileID] = (parentID, name)
        }
    }

    private func nodeID(for path: String) -> (volumeUUID: String, fileID: UInt64)? {
        guard let root = configuration.roots.first(where: { path.hasPrefix($0.path) }) else {
            return nil
        }
        
        let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
        let volumeUUID = values?.volumeUUIDString ?? root.path
        let mountPoint = volumeMountPoints[volumeUUID] ?? ""
        
        let relativePath: String
        if mountPoint == "/" {
            relativePath = String(path.dropFirst())
        } else if path.hasPrefix(mountPoint) {
            relativePath = String(path.dropFirst(mountPoint.count + 1))
        } else {
            return nil
        }
        
        let components = relativePath.split(separator: "/").map { String($0) }
        guard !components.isEmpty else {
            return (volumeUUID, 2)
        }
        
        var currentID: UInt64 = 2
        for component in components.dropLast() {
            guard let volumeCache = directoryCache[volumeUUID] else { return nil }
            if let nextDir = volumeCache.first(where: { $0.value.parentID == currentID && $0.value.name == component }) {
                currentID = nextDir.key
            } else {
                return nil
            }
        }
        
        if let volumeCache = directoryCache[volumeUUID],
           let finalDir = volumeCache.first(where: { $0.value.parentID == currentID && $0.value.name == components.last! }) {
            return (volumeUUID, finalDir.key)
        }
        
        let sql = "SELECT file_id FROM fs_nodes WHERE volume_uuid = ? AND parent_id = ? AND name = ? AND is_directory = 0;"
        if let row = try? database.query(sql: sql, bindings: [volumeUUID, Int64(bitPattern: currentID), components.last!]).first,
           let fileIDVal = row["file_id"] as? Int64 {
            return (volumeUUID, UInt64(bitPattern: fileIDVal))
        }
        
        return nil
    }

    private func deleteDescendants(volumeUUID: String, parentID: UInt64) throws {
        let sql = """
        WITH RECURSIVE descendants(fid) AS (
            SELECT file_id FROM fs_nodes WHERE volume_uuid = ? AND parent_id = ?
            UNION
            SELECT n.file_id
            FROM fs_nodes n
            JOIN descendants d ON n.parent_id = d.fid
            WHERE n.volume_uuid = ?
        )
        DELETE FROM fs_nodes
        WHERE volume_uuid = ? AND file_id IN (SELECT fid FROM descendants);
        """
        try database.execute(sql: sql, bindings: [
            volumeUUID,
            Int64(bitPattern: parentID),
            volumeUUID,
            volumeUUID
        ])

        guard let volumeCache = directoryCache[volumeUUID] else { return }
        var stack = [parentID]
        var visited = Set<UInt64>()
        var descendants: [UInt64] = []

        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            for (fileID, node) in volumeCache where node.parentID == current {
                descendants.append(fileID)
                stack.append(fileID)
            }
        }

        for fileID in descendants {
            directoryCache[volumeUUID]?.removeValue(forKey: fileID)
        }
    }

    public func remove(path: String) async throws {
        await ensureCacheLoaded()

        if let (volumeUUID, fileID) = nodeID(for: path) {
            if directoryCache[volumeUUID]?[fileID] != nil {
                try deleteDescendants(volumeUUID: volumeUUID, parentID: fileID)
                directoryCache[volumeUUID]?.removeValue(forKey: fileID)
            }

            let sql = "DELETE FROM fs_nodes WHERE volume_uuid = ? AND file_id = ?;"
            try database.execute(sql: sql, bindings: [volumeUUID, Int64(bitPattern: fileID)])
        }
    }

    public func lastEventID() async -> UInt64? {
        let sql = "SELECT value FROM metadata WHERE key = 'last_event_id';"
        if let row = try? database.query(sql: sql).first,
           let valueStr = row["value"] as? String,
           let val = UInt64(valueStr) {
            return val
        }
        return nil
    }

    public func setLastEventID(_ eventID: UInt64) async {
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('last_event_id', ?);"
        try? database.execute(sql: sql, bindings: [String(eventID)])
    }

    private func shouldExclude(_ path: String) -> Bool {
        configuration.excludedPaths.contains { path.hasPrefix($0) }
    }

    private func pruneDatabase(volumeUUID: String, rootIDs: [UInt64]) throws {
        guard !rootIDs.isEmpty else { return }
        
        let placeholders = Array(repeating: "?", count: rootIDs.count).joined(separator: ", ")
        let sql = """
        WITH RECURSIVE valid_dirs(fid) AS (
            SELECT file_id FROM fs_nodes WHERE file_id IN (\(placeholders)) AND volume_uuid = ?
            UNION ALL
            SELECT n.file_id FROM fs_nodes n
            JOIN valid_dirs v ON n.parent_id = v.fid AND n.is_directory = 1 AND n.volume_uuid = ?
        )
        DELETE FROM fs_nodes 
        WHERE volume_uuid = ?
          AND parent_id NOT IN (SELECT fid FROM valid_dirs)
          AND file_id NOT IN (SELECT fid FROM valid_dirs);
        """
        
        var bindings: [Any] = rootIDs.map { Int64(bitPattern: $0) }
        bindings.append(volumeUUID)
        bindings.append(volumeUUID)
        bindings.append(volumeUUID)
        
        try database.execute(sql: sql, bindings: bindings)
    }

    private func pruneExcludedPaths(volumeUUID: String) throws {
        for excludedPath in configuration.excludedPaths {
            guard let values = try? URL(fileURLWithPath: excludedPath).resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeUUIDStringKey]),
                  let excludedFID = normalizeFileID(values.fileResourceIdentifier),
                  values.volumeUUIDString == volumeUUID else {
                continue
            }
            
            let sql = """
            WITH RECURSIVE excluded_dirs(fid) AS (
                SELECT ?
                UNION ALL
                SELECT n.file_id FROM fs_nodes n
                JOIN excluded_dirs e ON n.parent_id = e.fid AND n.volume_uuid = ?
            )
            DELETE FROM fs_nodes 
            WHERE volume_uuid = ?
              AND (parent_id IN (SELECT fid FROM excluded_dirs) OR file_id = ?);
            """
            
            try database.execute(sql: sql, bindings: [
                Int64(bitPattern: excludedFID),
                volumeUUID,
                volumeUUID,
                Int64(bitPattern: excludedFID)
            ])
        }
    }

    private func scanVolumeRecursively(volumeUUID: String, rootsOnThisVolume: [URL]) throws {
        for rootToScan in rootsOnThisVolume {
            try Task.checkCancellation()
            guard let enumerator = FileManager.default.enumerator(
                at: rootToScan,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey, .volumeUUIDStringKey, .parentDirectoryURLKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else {
                continue
            }
            
            var batch: [[Any]] = []
            var scannedItemCount = 0
            while let fileURL = enumerator.nextObject() as? URL {
                scannedItemCount += 1
                if scannedItemCount % 256 == 0 {
                    try Task.checkCancellation()
                }
                if shouldExclude(fileURL.path) {
                    enumerator.skipDescendants()
                    continue
                }
                
                guard let res = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey, .volumeUUIDStringKey, .parentDirectoryURLKey]) else {
                    continue
                }
                
                let isDir = res.isDirectory == true
                let isReg = res.isRegularFile == true
                guard isDir || isReg else { continue }
                
                guard let fID = normalizeFileID(res.fileResourceIdentifier) else { continue }
                let pID: UInt64
                if let parentURL = res.parentDirectory ?? (fileURL.path == "/" ? nil : fileURL.deletingLastPathComponent()),
                   let parentValues = try? parentURL.resourceValues(forKeys: [URLResourceKey.fileResourceIdentifierKey]),
                   let pIDVal = normalizeFileID(parentValues.fileResourceIdentifier) {
                    pID = pIDVal
                } else {
                    pID = 2
                }
                
                let name = fileURL.lastPathComponent
                let ext = fileURL.pathExtension.lowercased()
                let size = isDir ? 0 : Int64(res.fileSize ?? 0)
                let modDate = res.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                let uti = res.typeIdentifier
                
                let mask = FuzzyMatcher.characterMask(for: name, caseSensitive: false)
                batch.append([
                    volumeUUID,
                    Int64(bitPattern: fID),
                    Int64(bitPattern: pID),
                    name,
                    Int64(bitPattern: mask),
                    isDir ? 1 : 0,
                    ext,
                    size,
                    modDate,
                    uti ?? NSNull()
                ])
                
                if batch.count >= 10000 {
                    try Task.checkCancellation()
                    try database.executeBatch(
                        sql: "INSERT OR REPLACE INTO fs_nodes (volume_uuid, file_id, parent_id, name, name_character_mask, is_directory, file_extension, size, modification_date, uti) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
                        items: batch
                    )
                    batch.removeAll(keepingCapacity: true)
                }
            }
            
            if !batch.isEmpty {
                try Task.checkCancellation()
                try database.executeBatch(
                    sql: "INSERT OR REPLACE INTO fs_nodes (volume_uuid, file_id, parent_id, name, name_character_mask, is_directory, file_extension, size, modification_date, uti) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
                    items: batch
                )
            }
        }
    }

    private static func realMountPoint(for path: String) -> String? {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else {
            return nil
        }
        return withUnsafeBytes(of: &buf.f_mntonname) { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return nil
            }
            let mountPoint = String(cString: base)
            return mountPoint.isEmpty ? nil : mountPoint
        }
    }

    private static func canonicalUserPath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        if resolved.hasPrefix("/System/Volumes/Data/") {
            return String(resolved.dropFirst("/System/Volumes/Data".count))
        }
        if resolved == "/System/Volumes/Data" {
            return "/"
        }
        return resolved
    }

    private func normalizeFileID(_ identifier: Any?) -> UInt64? {
        switch identifier {
        case let number as NSNumber:
            return number.uint64Value
        case let data as Data:
            return data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                let byteCount = min(rawBuffer.count, MemoryLayout<UInt64>.size)
                var value: UInt64 = 0
                withUnsafeMutableBytes(of: &value) { destination in
                    destination.copyBytes(from: UnsafeRawBufferPointer(start: baseAddress, count: byteCount))
                }
                return value
            }
        default:
            return nil
        }
    }
}
