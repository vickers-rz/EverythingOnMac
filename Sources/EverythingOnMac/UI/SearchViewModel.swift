import Foundation
import EverythingOnMacCore

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var queryText: String = ""
    @Published var mode: SearchMode = .mixed
    @Published var results: [SearchResult] = []
    @Published var indexedCount: Int = 0
    @Published var volumeCapabilities: [VolumeCapabilities] = []
    @Published var isIndexing = false
    @Published var lastError: String?
    @Published var isTruncated = false
    @Published var sortField: SortField = .relevance
    @Published var sortDirection: SortDirection = .descending

    private var coordinator: SearchCoordinator?
    private var searchTask: Task<Void, Never>?
    private var eventMonitor: FileSystemEventMonitor?

    init(roots: [URL] = [URL(fileURLWithPath: NSHomeDirectory())]) {
        let excluded = ["/System", "/private/var", "/Library/Caches"]
        volumeCapabilities = APFSVolumeInspector.inspect(roots: roots)

        do {
            let indexer = try FileIndexer(
                configuration: IndexerConfiguration(roots: roots, excludedPaths: excluded)
            )
            let ripgrep = RipgrepSearcher(configuration: RipgrepConfiguration())
            let coordinator = SearchCoordinator(indexer: indexer, ripgrepSearcher: ripgrep, roots: roots)
            self.coordinator = coordinator

            self.eventMonitor = FileSystemEventMonitor(roots: roots) { [weak self, coordinator] changes, eventID in
                Task { @MainActor [weak self] in
                    do {
                        try await coordinator.apply(changes: changes, eventID: eventID)
                    } catch {
                        self?.lastError = "文件索引增量更新失败：\(error.localizedDescription)"
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let lastEvent = await coordinator.lastEventID()
                    if let lastEvent {
                        try self.eventMonitor?.start(sinceEventId: lastEvent)
                    } else {
                        try self.eventMonitor?.start()
                    }
                } catch {
                    self.lastError = error.localizedDescription
                }
                await self.setupIndex()
            }
        } catch {
            coordinator = nil
            lastError = "索引服务初始化失败：\(error.localizedDescription)"
        }
    }

    func setupIndex() async {
        guard let coordinator else { return }
        let count = await coordinator.indexedItemCount()
        if count > 0 {
            indexedCount = count
        } else {
            await rebuildIndex()
        }
    }

    func rebuildIndex() async {
        guard let coordinator else { return }
        isIndexing = true
        defer { isIndexing = false }

        do {
            try await coordinator.rebuildIndex()
            indexedCount = await coordinator.indexedItemCount()
            lastError = nil
        } catch {
            lastError = "索引重建失败：\(error.localizedDescription)"
        }
    }

    func onQueryChanged() {
        searchTask?.cancel()
        guard let coordinator else {
            results = []
            isTruncated = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            if Task.isCancelled { return }

            var query = QueryParser.parse(queryText, mode: mode)
            if query.sortOption == nil {
                query.sortOption = SortOption(field: sortField, direction: sortDirection)
            }

            let responses = await coordinator.searchStream(query: query)
            for await response in responses {
                if Task.isCancelled { return }
                results = response.results
                isTruncated = response.isTruncated
                lastError = response.indexError?.localizedDescription
                    ?? response.contentError?.localizedDescription
            }
        }
    }

    func openResult(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.metadata.path)])
    }
}
#endif
