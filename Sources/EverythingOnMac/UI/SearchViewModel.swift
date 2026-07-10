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

    private let coordinator: SearchCoordinator
    private var searchTask: Task<Void, Never>?
    private var eventMonitor: FileSystemEventMonitor?

    init(roots: [URL] = [URL(fileURLWithPath: NSHomeDirectory())]) {
        let excluded = ["/System", "/private/var", "/Library/Caches"]
        do {
            let indexer = try FileIndexer(configuration: IndexerConfiguration(roots: roots, excludedPaths: excluded))
            let ripgrep = RipgrepSearcher(configuration: RipgrepConfiguration())
            self.coordinator = SearchCoordinator(indexer: indexer, ripgrepSearcher: ripgrep, roots: roots)
            self.volumeCapabilities = coordinator.inspectVolumes()
            self.eventMonitor = FileSystemEventMonitor(roots: roots) { [coordinator] changes, eventID in
                Task { await coordinator.apply(changes: changes, eventID: eventID) }
            }
            
            Task {
                let lastEvent = await coordinator.lastEventID()
                if let lastEvent {
                    self.eventMonitor?.start(sinceEventId: lastEvent)
                } else {
                    self.eventMonitor?.start()
                }
                await setupIndex()
            }
        } catch {
            fatalError("Failed to initialize FileIndexer: \(error)")
        }
    }

    func setupIndex() async {
        let count = await coordinator.indexedItemCount()
        if count > 0 {
            indexedCount = count
        } else {
            await rebuildIndex()
        }
    }

    func rebuildIndex() async {
        isIndexing = true
        await coordinator.rebuildIndex()
        indexedCount = await coordinator.indexedItemCount()
        isIndexing = false
    }

    func onQueryChanged() {
        searchTask?.cancel()
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
                self.results = response.results
                self.isTruncated = response.isTruncated
                self.lastError = response.indexError?.localizedDescription
                    ?? response.contentError?.localizedDescription
            }
        }
    }

    func openResult(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.metadata.path)])
    }
}
#endif
