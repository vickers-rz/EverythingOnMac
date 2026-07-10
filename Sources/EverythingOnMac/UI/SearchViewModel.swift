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
    @Published var isIndexing = false
    @Published var lastError: String?

    private let coordinator: SearchCoordinator
    private var searchTask: Task<Void, Never>?

    init(roots: [URL] = [URL(fileURLWithPath: NSHomeDirectory())]) {
        let excluded = ["/System", "/private/var", "/Library/Caches"]
        let indexer = FileIndexer(configuration: IndexerConfiguration(roots: roots, excludedPaths: excluded))
        let ripgrep = RipgrepSearcher(configuration: RipgrepConfiguration(executablePath: "/opt/homebrew/bin/rg"))
        self.coordinator = SearchCoordinator(indexer: indexer, ripgrepSearcher: ripgrep, roots: roots)

        Task { await rebuildIndex() }
    }

    func rebuildIndex() async {
        isIndexing = true
        await coordinator.rebuildIndex()
        indexedCount = await coordinator.search(query: SearchQuery(raw: "", terms: [])).count
        isIndexing = false
    }

    func onQueryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            if Task.isCancelled { return }

            let query = QueryParser.parse(queryText, mode: mode)
            let merged = await coordinator.search(query: query)
            if Task.isCancelled { return }
            self.results = merged
            self.lastError = nil
        }
    }

    func openResult(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.metadata.path)])
    }
}
#endif
