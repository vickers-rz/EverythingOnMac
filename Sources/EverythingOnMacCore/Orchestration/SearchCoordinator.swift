import Foundation

public actor SearchCoordinator {
    private let indexer: FileIndexer
    private let ripgrepSearcher: RipgrepSearcher
    private let roots: [URL]
    private let streamBatchSize: Int
    private let streamFlushInterval: Duration
    private let policy: SearchExecutionPolicy

    public init(
        indexer: FileIndexer,
        ripgrepSearcher: RipgrepSearcher,
        roots: [URL],
        policy: SearchExecutionPolicy = SearchExecutionPolicy(),
        streamBatchSize: Int = 32,
        streamFlushInterval: Duration = .milliseconds(75)
    ) {
        self.indexer = indexer
        self.ripgrepSearcher = ripgrepSearcher
        self.roots = roots
        self.policy = policy
        self.streamBatchSize = max(1, streamBatchSize)
        self.streamFlushInterval = streamFlushInterval
    }

    public func rebuildIndex() async throws { try await indexer.rebuild() }

    public func apply(changes: [FileSystemChange], eventID: UInt64) async throws {
        for change in changes {
            try Task.checkCancellation()
            if change.isRemoval {
                try await indexer.remove(path: change.path)
            } else {
                try await indexer.upsert(path: change.path)
            }
        }
        try Task.checkCancellation()
        await indexer.setLastEventID(eventID)
    }

    public func lastEventID() async -> UInt64? { await indexer.lastEventID() }
    public func indexedItemCount() async -> Int { await indexer.itemCount() }
    public nonisolated func inspectVolumes() -> [VolumeCapabilities] { APFSVolumeInspector.inspect(roots: roots) }

    public func search(query: SearchQuery) async -> SearchResponse {
        var latest = SearchResponse(results: [], contentError: nil)
        for await response in searchStream(query: query) { latest = response }
        return latest
    }

    public func searchStream(query: SearchQuery) -> AsyncStream<SearchResponse> {
        AsyncStream { continuation in
            let task = Task {
                let requestedLimit = max(1, query.limit ?? policy.defaultPresentationLimit)
                let requestedOffset = max(0, query.offset ?? 0)
                let minimumCandidates = requestedOffset + requestedLimit
                let overscan = query.filenameMatchMode == .fuzzy ? 8 : 2
                let desiredCandidates = max(policy.defaultCandidateLimit, minimumCandidates * overscan)
                let candidateLimit = min(desiredCandidates, policy.maximumCandidateLimit)

                var indexQuery = query
                indexQuery.limit = min(candidateLimit + 1, policy.maximumCandidateLimit + 1)
                indexQuery.offset = nil

                var indexed: [SearchResult] = []
                var indexError: FileIndexSearchError?
                var indexWasTruncated = desiredCandidates > policy.maximumCandidateLimit

                if query.mode != .contentOnly {
                    do {
                        indexed = try await indexer.query(indexQuery)
                        if indexed.count > candidateLimit {
                            indexWasTruncated = true
                            indexed.removeLast(indexed.count - candidateLimit)
                        }
                    } catch let error as FileIndexSearchError {
                        indexError = error
                    } catch {
                        indexError = .databaseError(error.localizedDescription)
                    }
                }

                var mergedByPath = Dictionary(uniqueKeysWithValues: indexed.map { ($0.metadata.path, $0) })
                continuation.yield(makeResponse(
                    mergedByPath: mergedByPath,
                    query: query,
                    indexError: indexError,
                    contentError: nil,
                    indexWasTruncated: indexWasTruncated
                ))

                guard query.mode != .filenameOnly else {
                    continuation.finish()
                    return
                }

                var pendingCount = 0
                var yieldedContent = false
                let clock = ContinuousClock()
                var lastFlush = clock.now

                do {
                    let stream = await ripgrepSearcher.stream(query: query, roots: roots)
                    for try await item in stream {
                        try Task.checkCancellation()
                        Self.merge(item, into: &mergedByPath, matchLimit: policy.maximumContentMatchesPerFile)
                        pendingCount += 1

                        let now = clock.now
                        if !yieldedContent || pendingCount >= streamBatchSize || lastFlush.duration(to: now) >= streamFlushInterval {
                            continuation.yield(makeResponse(
                                mergedByPath: mergedByPath,
                                query: query,
                                indexError: indexError,
                                contentError: nil,
                                indexWasTruncated: indexWasTruncated
                            ))
                            pendingCount = 0
                            yieldedContent = true
                            lastFlush = now
                        }
                    }

                    if pendingCount > 0 {
                        continuation.yield(makeResponse(
                            mergedByPath: mergedByPath,
                            query: query,
                            indexError: indexError,
                            contentError: nil,
                            indexWasTruncated: indexWasTruncated
                        ))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as RipgrepSearchError {
                    if error != .cancelled {
                        continuation.yield(makeResponse(
                            mergedByPath: mergedByPath,
                            query: query,
                            indexError: indexError,
                            contentError: error,
                            indexWasTruncated: indexWasTruncated
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(makeResponse(
                        mergedByPath: mergedByPath,
                        query: query,
                        indexError: indexError,
                        contentError: .launchFailed(error.localizedDescription),
                        indexWasTruncated: indexWasTruncated
                    ))
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public nonisolated func merge(index: [SearchResult], content: [SearchResult], query: SearchQuery) -> [SearchResult] {
        var merged = Dictionary(uniqueKeysWithValues: index.map { ($0.metadata.path, $0) })
        for item in content {
            Self.merge(item, into: &merged, matchLimit: policy.maximumContentMatchesPerFile)
        }
        return sortedResults(from: merged, query: query)
    }

    private nonisolated static func merge(
        _ item: SearchResult,
        into results: inout [String: SearchResult],
        matchLimit: Int
    ) {
        if var existing = results[item.metadata.path] {
            existing.source.formUnion(item.source)
            existing.totalContentMatchCount += max(item.totalContentMatchCount, item.contentMatches.count)
            let remaining = max(0, matchLimit - existing.contentMatches.count)
            if remaining > 0 { existing.contentMatches.append(contentsOf: item.contentMatches.prefix(remaining)) }
            results[item.metadata.path] = existing
        } else {
            var inserted = item
            inserted.totalContentMatchCount = max(item.totalContentMatchCount, item.contentMatches.count)
            if inserted.contentMatches.count > matchLimit {
                inserted.contentMatches = Array(inserted.contentMatches.prefix(matchLimit))
            }
            results[item.metadata.path] = inserted
        }
    }

    private nonisolated func sortedResults(
        from resultsByPath: [String: SearchResult],
        query: SearchQuery
    ) -> [SearchResult] {
        var results = Array(resultsByPath.values)
        let field = query.sortOption?.field ?? .relevance
        let direction = query.sortOption?.direction ?? .descending

        results.sort { lhs, rhs in
            let ordered: Bool
            switch field {
            case .relevance:
                let left = SearchRelevanceScorer.score(result: lhs, query: query)
                let right = SearchRelevanceScorer.score(result: rhs, query: query)
                if left != right { return left > right }
                if lhs.metadata.filename != rhs.metadata.filename { return lhs.metadata.filename < rhs.metadata.filename }
                return lhs.metadata.path < rhs.metadata.path
            case .path:
                ordered = lhs.metadata.path < rhs.metadata.path
            case .filename:
                if lhs.metadata.filename == rhs.metadata.filename { return lhs.metadata.path < rhs.metadata.path }
                ordered = lhs.metadata.filename < rhs.metadata.filename
            case .size:
                if lhs.metadata.size == rhs.metadata.size { return lhs.metadata.path < rhs.metadata.path }
                ordered = lhs.metadata.size < rhs.metadata.size
            case .modificationDate:
                let left = lhs.metadata.modificationDate ?? .distantPast
                let right = rhs.metadata.modificationDate ?? .distantPast
                if left == right { return lhs.metadata.path < rhs.metadata.path }
                ordered = left < right
            }
            return direction == .ascending ? ordered : !ordered
        }
        return results
    }

    private nonisolated func makeResponse(
        mergedByPath: [String: SearchResult],
        query: SearchQuery,
        indexError: FileIndexSearchError?,
        contentError: RipgrepSearchError?,
        indexWasTruncated: Bool
    ) -> SearchResponse {
        let sorted = sortedResults(from: mergedByPath, query: query)
        let offset = max(0, query.offset ?? 0)
        let limit = max(1, query.limit ?? policy.defaultPresentationLimit)
        let available = offset < sorted.count ? Array(sorted.dropFirst(offset)) : []
        let visible = Array(available.prefix(limit))
        let truncated = indexWasTruncated || available.count > limit

        return SearchResponse(
            results: visible,
            indexError: indexError,
            contentError: contentError,
            isTruncated: truncated,
            totalCandidateCount: sorted.count
        )
    }
}
