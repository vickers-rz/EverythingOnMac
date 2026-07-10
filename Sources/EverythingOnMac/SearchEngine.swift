import Foundation

struct SearchEngine {
    private let indexer: FileIndexing
    private let contentSearcher: ContentSearching

    init(indexer: FileIndexing = FileIndexer(), contentSearcher: ContentSearching = RipgrepSearcher()) {
        self.indexer = indexer
        self.contentSearcher = contentSearcher
    }

    func search(options: SearchOptions) throws -> [SearchResult] {
        let indexedFiles = try indexer.indexFiles(
            at: options.root,
            fileNameQuery: options.fileNameQuery,
            maxResults: options.maxResults,
            includeHidden: options.includeHidden
        )

        let contentMatches: [ContentMatch]
        if let query = options.contentQuery, query.isEmpty == false {
            contentMatches = try contentSearcher.searchContent(query: query, root: options.root)
        } else {
            contentMatches = []
        }

        let matchesByPath = Dictionary(grouping: contentMatches, by: \.filePath)

        if options.contentQuery == nil || options.contentQuery?.isEmpty == true {
            return indexedFiles.map { SearchResult(file: $0, contentMatches: []) }
        }

        return indexedFiles.compactMap { file in
            guard let matches = matchesByPath[file.path] else {
                return nil
            }
            return SearchResult(file: file, contentMatches: matches)
        }
    }
}
