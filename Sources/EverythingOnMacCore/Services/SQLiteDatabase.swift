import Foundation
import SQLite3

public enum SQLiteError: Error, LocalizedError {
    case connectionFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SQLite connection failed: \(msg)"
        case .executeFailed(let msg): return "SQLite execute failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .bindFailed(let msg): return "SQLite bind failed: \(msg)"
        case .stepFailed(let msg): return "SQLite step failed: \(msg)"
        }
    }
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: String

    public init(path: String) throws {
        self.path = path
        try open()
        registerCustomFunctions()
        try setupTables()
    }

    deinit {
        close()
    }

    private func open() throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw SQLiteError.connectionFailed(msg)
        }
    }

    private func close() {
        if db != nil {
            sqlite3_close_v2(db)
            db = nil
        }
    }

    private func setupTables() throws {
        let versionRow = try query(sql: "PRAGMA user_version;")
        var currentVersion = (versionRow.first?["user_version"] as? Int64) ?? 0

        if currentVersion < 1 {
            let createMetadata = """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            """
            try execute(sql: createMetadata)
            currentVersion = 1
            try execute(sql: "PRAGMA user_version = 1;")
        }

        if currentVersion < 2 {
            // Drop old files table if it existed
            try execute(sql: "DROP TABLE IF EXISTS files;")

            let createNodes = """
            CREATE TABLE IF NOT EXISTS fs_nodes (
                volume_uuid TEXT,
                file_id INTEGER,
                parent_id INTEGER,
                name TEXT,
                name_character_mask INTEGER NOT NULL DEFAULT 0,
                is_directory INTEGER,
                file_extension TEXT,
                size INTEGER,
                modification_date REAL,
                uti TEXT,
                PRIMARY KEY (volume_uuid, file_id)
            );
            """
            let createIdxParent = "CREATE INDEX IF NOT EXISTS idx_fs_nodes_parent ON fs_nodes(volume_uuid, parent_id);"
            let createIdxName = "CREATE INDEX IF NOT EXISTS idx_fs_nodes_name ON fs_nodes(name);"
            let createIdxExtension = "CREATE INDEX IF NOT EXISTS idx_fs_nodes_extension ON fs_nodes(file_extension);"

            try execute(sql: createNodes)
            try execute(sql: createIdxParent)
            try execute(sql: createIdxName)
            try execute(sql: createIdxExtension)

            try execute(sql: "PRAGMA user_version = 2;")
            currentVersion = 2
        }

        if currentVersion < 3 {
            let createIdxParentName = "CREATE INDEX IF NOT EXISTS idx_fs_nodes_parent_name ON fs_nodes(volume_uuid, parent_id, name);"
            try execute(sql: createIdxParentName)
            try execute(sql: "PRAGMA user_version = 3;")
            currentVersion = 3
        }

        if currentVersion < 4 {
            try? execute(sql: "ALTER TABLE fs_nodes ADD COLUMN name_character_mask INTEGER NOT NULL DEFAULT 0;")
            try execute(sql: "UPDATE fs_nodes SET name_character_mask = CHARACTER_MASK(name);")
            try execute(sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('name_mask_version', '1');")
            try execute(sql: "PRAGMA user_version = 4;")
            currentVersion = 4
        }

        if currentVersion < 5 {
            // Mask v2 applies full Unicode lowercase normalization before hashing UTF-8.
            try execute(sql: "UPDATE fs_nodes SET name_character_mask = CHARACTER_MASK(name);")
            try execute(sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('name_mask_version', '2');")
            try execute(sql: "PRAGMA user_version = 5;")
            currentVersion = 5
        }

        if currentVersion < 6 {
            // fs_nodes cannot represent multiple directory entries for one hardlinked object.
            // Old data is intentionally discarded because overwritten hardlink paths cannot be recovered.
            try execute(sql: "BEGIN IMMEDIATE;")
            do {
                try execute(sql: "PRAGMA foreign_keys = ON;")
                try execute(sql: """
                    CREATE TABLE IF NOT EXISTS fs_objects (
                        volume_uuid TEXT NOT NULL,
                        file_id INTEGER NOT NULL,
                        is_directory INTEGER NOT NULL,
                        file_extension TEXT NOT NULL DEFAULT '',
                        size INTEGER NOT NULL DEFAULT 0,
                        modification_date REAL,
                        uti TEXT,
                        link_count INTEGER,
                        content_fingerprint TEXT,
                        PRIMARY KEY (volume_uuid, file_id)
                    );
                    """)
                try execute(sql: """
                    CREATE TABLE IF NOT EXISTS fs_entries (
                        entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        volume_uuid TEXT NOT NULL,
                        parent_file_id INTEGER NOT NULL,
                        target_file_id INTEGER NOT NULL,
                        name TEXT NOT NULL,
                        name_character_mask INTEGER NOT NULL DEFAULT 0,
                        UNIQUE (volume_uuid, parent_file_id, name),
                        FOREIGN KEY (volume_uuid, target_file_id)
                            REFERENCES fs_objects(volume_uuid, file_id)
                            ON DELETE CASCADE
                    );
                    """)
                try execute(sql: "CREATE INDEX IF NOT EXISTS idx_fs_entries_target ON fs_entries(volume_uuid, target_file_id);")
                try execute(sql: "CREATE INDEX IF NOT EXISTS idx_fs_entries_parent ON fs_entries(volume_uuid, parent_file_id);")
                try execute(sql: "CREATE INDEX IF NOT EXISTS idx_fs_entries_name ON fs_entries(name);")
                try execute(sql: "CREATE INDEX IF NOT EXISTS idx_fs_entries_mask ON fs_entries(name_character_mask);")
                try execute(sql: "CREATE INDEX IF NOT EXISTS idx_fs_objects_extension ON fs_objects(file_extension);")
                try execute(sql: "DROP TABLE IF EXISTS fs_nodes;")
                try execute(sql: "DELETE FROM metadata WHERE key = 'last_event_id';")
                try execute(sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('rebuild_required', '1');")
                try execute(sql: "PRAGMA user_version = 6;")
                try execute(sql: "COMMIT;")
                currentVersion = 6
            } catch {
                try? execute(sql: "ROLLBACK;")
                throw error
            }
        }

        try execute(sql: "PRAGMA foreign_keys = ON;")
    }

    private func registerCustomFunctions() {
        // Register REGEXP_LIKE(pattern, text, isCaseSensitive) -> Int (0 or 1)
        let cache = SQLiteRegexCache()
        let userData = Unmanaged.passRetained(cache).toOpaque()

        sqlite3_create_function_v2(
            db,
            "REGEXP_LIKE",
            3,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            userData,
            { (ctx, argc, argv) in
                guard argc == 3,
                      let patternPtr = sqlite3_value_text(argv?[0]),
                      let textPtr = sqlite3_value_text(argv?[1]),
                      let userData = sqlite3_user_data(ctx) else {
                    sqlite3_result_int(ctx, 0)
                    return
                }
                let isCaseSensitive = sqlite3_value_int(argv?[2]) != 0
                let pattern = String(cString: patternPtr)
                let text = String(cString: textPtr)

                let cache = Unmanaged<SQLiteRegexCache>.fromOpaque(userData).takeUnretainedValue()
                let regex: NSRegularExpression
                do {
                    regex = try cache.getOrCreate(pattern: pattern, isCaseSensitive: isCaseSensitive)
                } catch {
                    sqlite3_result_int(ctx, 0)
                    return
                }

                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let isMatch = regex.firstMatch(in: text, options: [], range: range) != nil
                sqlite3_result_int(ctx, isMatch ? 1 : 0)
            },
            nil,
            nil,
            { (userData) in
                if let userData = userData {
                    Unmanaged<SQLiteRegexCache>.fromOpaque(userData).release()
                }
            }
        )

        // Register CHARACTER_MASK(text)
        sqlite3_create_function_v2(
            db,
            "CHARACTER_MASK",
            1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            { (ctx, argc, argv) in
                guard argc == 1,
                      let textPtr = sqlite3_value_text(argv?[0]) else {
                    sqlite3_result_int64(ctx, 0)
                    return
                }
                let text = String(cString: textPtr)
                let mask = FuzzyMatcher.characterMask(for: text, caseSensitive: false)
                sqlite3_result_int64(ctx, Int64(bitPattern: mask))
            },
            nil,
            nil,
            nil
        )

        // Register FUZZY_SCORE(query, candidate, case_sensitive)
        sqlite3_create_function_v2(
            db,
            "FUZZY_SCORE",
            3,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            { (ctx, argc, argv) in
                guard argc == 3,
                      let queryPtr = sqlite3_value_text(argv?[0]),
                      let candidatePtr = sqlite3_value_text(argv?[1]) else {
                    sqlite3_result_null(ctx)
                    return
                }
                let isCaseSensitive = sqlite3_value_int(argv?[2]) != 0
                let queryStr = String(cString: queryPtr)
                let candidateStr = String(cString: candidatePtr)

                let prepared: FuzzyMatcher.PreparedQuery
                if let auxPtr = sqlite3_get_auxdata(ctx, 0) {
                    let wrapper = Unmanaged<PreparedQueryWrapper>.fromOpaque(auxPtr).takeUnretainedValue()
                    if wrapper.query.original == queryStr && wrapper.query.caseSensitive == isCaseSensitive {
                        prepared = wrapper.query
                    } else {
                        let prep = FuzzyMatcher.prepare(query: queryStr, caseSensitive: isCaseSensitive)
                        let newWrapper = PreparedQueryWrapper(query: prep)
                        let pointer = Unmanaged.passRetained(newWrapper).toOpaque()
                        prepared = prep
                        sqlite3_set_auxdata(ctx, 0, pointer) { ptr in
                            if let ptr = ptr {
                                Unmanaged<PreparedQueryWrapper>.fromOpaque(ptr).release()
                            }
                        }
                    }
                } else {
                    let prep = FuzzyMatcher.prepare(query: queryStr, caseSensitive: isCaseSensitive)
                    let wrapper = PreparedQueryWrapper(query: prep)
                    let pointer = Unmanaged.passRetained(wrapper).toOpaque()
                    prepared = prep
                    sqlite3_set_auxdata(ctx, 0, pointer) { ptr in
                        if let ptr = ptr {
                            Unmanaged<PreparedQueryWrapper>.fromOpaque(ptr).release()
                        }
                    }
                }

                if let score = FuzzyMatcher.score(preparedQuery: prepared, candidate: candidateStr) {
                    sqlite3_result_int(ctx, Int32(score))
                } else {
                    sqlite3_result_null(ctx)
                }
            },
            nil,
            nil,
            nil
        )
    }

    public func execute(sql: String, bindings: [Any] = []) throws {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(errmsg())
        }
        defer { sqlite3_finalize(statement) }

        try bind(statement: statement, bindings: bindings)

        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE && stepResult != SQLITE_ROW {
            throw SQLiteError.stepFailed(errmsg())
        }
    }

    public func executeBatch(sql: String, items: [[Any]]) throws {
        guard !items.isEmpty else { return }

        let savepoint = "everything_batch"
        try execute(sql: "SAVEPOINT \(savepoint);")
        do {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
                throw SQLiteError.prepareFailed(errmsg())
            }
            defer { sqlite3_finalize(statement) }

            let expectedBindingCount = Int(sqlite3_bind_parameter_count(statement))
            for bindings in items {
                guard bindings.count == expectedBindingCount else {
                    throw SQLiteError.bindFailed("Expected \(expectedBindingCount) bindings, received \(bindings.count)")
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(statement: statement, bindings: bindings)
                let stepResult = sqlite3_step(statement)
                if stepResult != SQLITE_DONE && stepResult != SQLITE_ROW {
                    throw SQLiteError.stepFailed(errmsg())
                }
            }
            try execute(sql: "RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? execute(sql: "ROLLBACK TO SAVEPOINT \(savepoint);")
            try? execute(sql: "RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
    }

    public func query(sql: String, bindings: [Any] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(errmsg())
        }
        defer { sqlite3_finalize(statement) }

        try bind(statement: statement, bindings: bindings)

        var results: [[String: Any]] = []
        let columnCount = sqlite3_column_count(statement)

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                return results
            }
            guard stepResult == SQLITE_ROW else {
                throw SQLiteError.stepFailed(errmsg())
            }

            var row: [String: Any] = [:]
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, i))
                let type = sqlite3_column_type(statement, i)

                switch type {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    if let text = sqlite3_column_text(statement, i) {
                        row[name] = String(cString: text)
                    } else {
                        row[name] = NSNull()
                    }
                }
            }
            results.append(row)
        }
    }

    private func bind(statement: OpaquePointer?, bindings: [Any]) throws {
        for (index, value) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            var result: Int32 = SQLITE_OK

            switch value {
            case let string as String:
                result = sqlite3_bind_text(statement, parameterIndex, string, -1, SQLITE_TRANSIENT)
            case let number as Int64:
                result = sqlite3_bind_int64(statement, parameterIndex, number)
            case let number as Int:
                result = sqlite3_bind_int64(statement, parameterIndex, Int64(number))
            case let number as Double:
                result = sqlite3_bind_double(statement, parameterIndex, number)
            case let boolean as Bool:
                result = sqlite3_bind_int(statement, parameterIndex, boolean ? 1 : 0)
            case is NSNull:
                result = sqlite3_bind_null(statement, parameterIndex)
            default:
                let strVal = String(describing: value)
                result = sqlite3_bind_text(statement, parameterIndex, strVal, -1, SQLITE_TRANSIENT)
            }

            if result != SQLITE_OK {
                throw SQLiteError.bindFailed(errmsg())
            }
        }
    }

    private func errmsg() -> String {
        return db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
    }
}

// transient binding constants
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteRegexCache: @unchecked Sendable {
    struct Key: Hashable {
        let pattern: String
        let isCaseSensitive: Bool
    }
    private let lock = NSLock()
    private var cache: [Key: NSRegularExpression] = [:]
    private let maxCapacity = 128
    
    func getOrCreate(pattern: String, isCaseSensitive: Bool) throws -> NSRegularExpression {
        let key = Key(pattern: pattern, isCaseSensitive: isCaseSensitive)
        
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        var options: NSRegularExpression.Options = []
        if !isCaseSensitive {
            options.insert(.caseInsensitive)
        }
        let compiled = try NSRegularExpression(pattern: pattern, options: options)
        
        lock.lock()
        defer { lock.unlock() }
        if cache.count >= maxCapacity {
            cache.removeAll() // Clear the cache if limit is reached
        }
        cache[key] = compiled
        return compiled
    }
}

private final class PreparedQueryWrapper {
    let query: FuzzyMatcher.PreparedQuery
    init(query: FuzzyMatcher.PreparedQuery) {
        self.query = query
    }
}
