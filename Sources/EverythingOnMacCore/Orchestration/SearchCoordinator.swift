import Foundation

public actor SearchCoordinator {
    private let indexer: FileIndexer
    private let ripgrepSearcher: RipgrepSearcher
    private let roots: [URL]

    public init(indexer: FileIndexer, ripgrepSearcher: RipgrepSearcher, roots: [URL]) {
        self.indexer = indexer
        self.ripgrepSearcher = ripgrepSearcher
        self.roots = roots
    }

    public func rebuildIndex() async {
        await indexer.rebuild()
    }

    public func apply(changes: [FileSystemChange]) async {
        for change in changes {
            if change.isRemoval {
                await indexer.remove(path: change.path)
            } else {
                await indexer.upsert(path: change.path)
            }
        }
    }

    public func indexedItemCount() async -> Int {
        await indexer.itemCount()
    }

    public nonisolated func inspectVolumes() -> [VolumeCapabilities] {
        APFSVolumeInspector.inspect(roots: roots)
    }

    public func search(query: SearchQuery) async -> [SearchResult] {
        async let indexResults: [SearchResult] = {
            guard query.mode != .contentOnly else { return [] }
            return await indexer.query(query)
        }()

        async let contentResults: [SearchResult] = {
            guard query.mode != .filenameOnly else { return [] }
            return await ripgrepSearcher.search(query: query, roots: roots)
        }()

        return merge(index: await indexResults, content: await contentResults)
    }

    public nonisolated func merge(index: [SearchResult], content: [SearchResult]) -> [SearchResult] {
        var merged: [String: SearchResult] = [:]

        for item in index {
            merged[item.metadata.path] = item
        }

        for item in content {
            if var existing = merged[item.metadata.path] {
                existing.source.formUnion(item.source)
                if existing.contentMatches.isEmpty {
                    existing.contentMatches = item.contentMatches
                } else {
                    existing.contentMatches.append(contentsOf: item.contentMatches)
                }
                merged[item.metadata.path] = existing
            } else {
                merged[item.metadata.path] = item
            }
        }

        return merged.values.sorted { lhs, rhs in
            if lhs.source.contains(.filenameIndex) != rhs.source.contains(.filenameIndex) {
                return lhs.source.contains(.filenameIndex)
            }
            if lhs.contentMatches.count != rhs.contentMatches.count {
                return lhs.contentMatches.count > rhs.contentMatches.count
            }
            return lhs.metadata.path < rhs.metadata.path
        }
    }
}
