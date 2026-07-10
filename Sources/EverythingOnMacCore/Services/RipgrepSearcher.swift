import Foundation

public struct RipgrepConfiguration: Sendable {
    public var executablePath: String
    public var timeoutSeconds: TimeInterval
    public var maximumStderrBytes: Int

    public init(
        executablePath: String = RipgrepConfiguration.defaultExecutablePath(),
        timeoutSeconds: TimeInterval = 8,
        maximumStderrBytes: Int = 16 * 1024
    ) {
        self.executablePath = executablePath
        self.timeoutSeconds = timeoutSeconds
        self.maximumStderrBytes = maximumStderrBytes
    }

    public static func defaultExecutablePath() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["RG_PATH"],
            Bundle.main.path(forResource: "rg", ofType: nil),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/rg").path,
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
            executableOnPATH(named: "rg")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "rg"
    }

    private static func executableOnPATH(named executableName: String) -> String? {
        ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executableName).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum RipgrepSearchError: Error, Sendable, Equatable, LocalizedError {
    case executableUnavailable(String)
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)
    case cancelled
    case failed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path):
            return "找不到可执行的 ripgrep：\(path)"
        case .launchFailed(let message):
            return "无法启动 ripgrep：\(message)"
        case .timedOut(let seconds):
            return "ripgrep 搜索超过 \(seconds) 秒，已终止。"
        case .cancelled:
            return "ripgrep 搜索已取消。"
        case .failed(let exitCode, let stderr):
            let detail = stderr.isEmpty ? "未提供错误信息" : stderr
            return "ripgrep 执行失败（退出码 \(exitCode)）：\(detail)"
        }
    }
}

public actor RipgrepSearcher {
    private let configuration: RipgrepConfiguration
    private var activeProcess: Process?
    private var activeSearchID: UUID?

    public init(configuration: RipgrepConfiguration = RipgrepConfiguration()) {
        self.configuration = configuration
    }

    public func search(query: SearchQuery, roots: [URL]) async throws -> [SearchResult] {
        var grouped: [String: SearchResult] = [:]
        let resultStream = stream(query: query, roots: roots)

        for try await result in resultStream {
            if var existing = grouped[result.metadata.path] {
                existing.source.formUnion(result.source)
                existing.contentMatches.append(contentsOf: result.contentMatches)
                grouped[result.metadata.path] = existing
            } else {
                grouped[result.metadata.path] = result
            }
        }

        return grouped.values.sorted { $0.metadata.path < $1.metadata.path }
    }

    public func stream(
        query: SearchQuery,
        roots: [URL]
    ) -> AsyncThrowingStream<SearchResult, Error> {
        let pattern = query.terms.joined(separator: " ")
        guard query.hasContentPattern, query.mode != .filenameOnly, !pattern.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        let paths = contentRoots(for: query, roots: roots).map(\.path)
        return makeStream(argumentBatches: [makeArguments(query: query, paths: paths, pattern: pattern)])
    }

    public func stream(
        query: SearchQuery,
        paths: [String]
    ) -> AsyncThrowingStream<SearchResult, Error> {
        let pattern = query.terms.joined(separator: " ")
        guard query.hasContentPattern, query.mode != .filenameOnly, !pattern.isEmpty, !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        let batches = chunkedPaths(paths, maximumArgumentBytes: 96 * 1024)
            .map { makeArguments(query: query, paths: $0, pattern: pattern) }
        return makeStream(argumentBatches: batches)
    }

    private func makeStream(argumentBatches: [[String]]) -> AsyncThrowingStream<SearchResult, Error> {
        let searchID = UUID()
        return AsyncThrowingStream { continuation in
            let executionTask = Task {
                await self.executeStreaming(
                    argumentBatches: argumentBatches,
                    searchID: searchID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in
                executionTask.cancel()
                Task { await self.cancelSearch(searchID: searchID) }
            }
        }
    }

    private func makeArguments(query: SearchQuery, paths: [String], pattern: String) -> [String] {
        var arguments = [
            "--json", "--line-number", "--column", "--color", "never",
            "--no-heading", "--with-filename"
        ]
        if !query.isRegex { arguments.append("--fixed-strings") }
        arguments.append(query.isCaseSensitive ? "--case-sensitive" : "--ignore-case")
        arguments.append(contentsOf: ["--regexp", pattern, "--"])
        arguments.append(contentsOf: paths)
        return sanitize(arguments)
    }

    private func chunkedPaths(_ paths: [String], maximumArgumentBytes: Int) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var currentBytes = 0
        for path in paths {
            let bytes = path.utf8.count + 1
            if !current.isEmpty && currentBytes + bytes > maximumArgumentBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(path)
            currentBytes += bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func contentRoots(for query: SearchQuery, roots: [URL]) -> [URL] {
        guard let pathPrefix = query.pathPrefix, !pathPrefix.isEmpty else {
            return roots
        }

        let prefixURL = URL(fileURLWithPath: pathPrefix)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: pathPrefix, isDirectory: &isDirectory), isDirectory.boolValue {
            return [prefixURL]
        }

        let matchingRoots = roots.filter { root in
            pathPrefix.hasPrefix(root.path) || root.path.hasPrefix(pathPrefix)
        }
        return matchingRoots.isEmpty ? roots : matchingRoots
    }

    private func executeStreaming(
        argumentBatches: [[String]],
        searchID: UUID,
        continuation: AsyncThrowingStream<SearchResult, Error>.Continuation
    ) async {
        let executablePath = configuration.executablePath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            continuation.finish(throwing: RipgrepSearchError.executableUnavailable(executablePath))
            return
        }

        do {
            for arguments in argumentBatches {
                try Task.checkCancellation()
                try await executeBatch(
                    executablePath: executablePath,
                    arguments: arguments,
                    searchID: searchID,
                    continuation: continuation
                )
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: RipgrepSearchError.cancelled)
        } catch let error as RipgrepSearchError {
            continuation.finish(throwing: error)
        } catch {
            continuation.finish(throwing: RipgrepSearchError.launchFailed(error.localizedDescription))
        }
    }

    private func executeBatch(
        executablePath: String,
        arguments: [String],
        searchID: UUID,
        continuation: AsyncThrowingStream<SearchResult, Error>.Continuation
    ) async throws {
        if let activeProcess, activeProcess.isRunning { activeProcess.terminate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        activeProcess = process
        activeSearchID = searchID

        let stderrTask = Task { await Self.readToEnd(stderrPipe.fileHandleForReading) }
        let stdoutTask = Task {
            try await Self.consumeJSONLines(
                from: stdoutPipe.fileHandleForReading,
                continuation: continuation
            )
        }

        do {
            try process.run()
            let exitCode = try await waitForExit(process)
            try Task.checkCancellation()
            try await stdoutTask.value
            let stderr = await stderrTask.value
            guard exitCode == 0 || exitCode == 1 else {
                throw RipgrepSearchError.failed(
                    exitCode: exitCode,
                    stderr: limitedStderr(from: stderr)
                )
            }
        } catch {
            terminate(process)
            stdoutTask.cancel()
            stderrTask.cancel()
            throw error
        }

        if activeSearchID == searchID {
            activeProcess = nil
        }
    }

    private func cancelSearch(searchID: UUID) {
        guard activeSearchID == searchID, let activeProcess, activeProcess.isRunning else {
            return
        }
        activeProcess.terminate()
    }

    private func waitForExit(_ process: Process) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                await Self.blockingWaitForExit(process)
            }

            let timeoutSeconds = configuration.timeoutSeconds
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                if process.isRunning {
                    process.terminate()
                }
                throw RipgrepSearchError.timedOut(seconds: timeoutSeconds)
            }

            guard let first = try await group.next() else {
                throw RipgrepSearchError.launchFailed("进程未返回退出状态")
            }
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func consumeJSONLines(
        from handle: FileHandle,
        continuation: AsyncThrowingStream<SearchResult, Error>.Continuation
    ) async throws {
        var buffer = Data()

        for try await byte in handle.bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                if let result = decodeJSONLine(buffer) {
                    continuation.yield(result)
                }
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }

        if !buffer.isEmpty, let result = decodeJSONLine(buffer) {
            continuation.yield(result)
        }
    }

    private nonisolated static func decodeJSONLine(_ data: Data) -> SearchResult? {
        guard let event = try? JSONDecoder().decode(RipgrepEvent.self, from: data),
              event.type == "match",
              let payload = event.data,
              let path = payload.path?.text,
              let lines = payload.lines?.text else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        let metadata = FileMetadata(
            path: path,
            filename: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            size: 0,
            modificationDate: nil,
            fileID: nil,
            uti: nil
        )
        let match = ContentMatch(
            line: payload.lineNumber ?? 0,
            column: payload.submatches?.first?.start ?? 0,
            text: lines.trimmingCharacters(in: .newlines)
        )
        return SearchResult(
            metadata: metadata,
            source: [.contentRipgrep],
            contentMatches: [match]
        )
    }

    private nonisolated static func blockingWaitForExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    private nonisolated static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func limitedStderr(from data: Data) -> String {
        let limit = max(0, configuration.maximumStderrBytes)
        let limitedData = data.count > limit ? data.suffix(limit) : data
        return String(decoding: limitedData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitize(_ arguments: [String]) -> [String] {
        arguments.filter { !$0.contains("\0") }
    }
}

private struct RipgrepEvent: Codable {
    struct DataPayload: Codable {
        struct TextNode: Codable {
            var text: String
        }

        struct Submatch: Codable {
            var start: Int
        }

        var path: TextNode?
        var lines: TextNode?
        var lineNumber: Int?
        var submatches: [Submatch]?

        enum CodingKeys: String, CodingKey {
            case path
            case lines
            case lineNumber = "line_number"
            case submatches
        }
    }

    var type: String
    var data: DataPayload?
}
