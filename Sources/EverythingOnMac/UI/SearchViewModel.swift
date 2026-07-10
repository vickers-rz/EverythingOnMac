import Foundation
import EverythingOnMacCore

#if os(macOS)
import AppKit
import SwiftUI

enum PresentedError: Identifiable, Equatable {
    case initialization(String)
    case database(String)
    case databaseMaintenance(String)
    case eventMonitor(String)
    case indexUpdate(String)
    case search(String)
    case contentSearch(String)

    var id: String {
        switch self {
        case .initialization(let message): return "init:\(message)"
        case .database(let message): return "db:\(message)"
        case .databaseMaintenance(let message): return "db-maintenance:\(message)"
        case .eventMonitor(let message): return "monitor:\(message)"
        case .indexUpdate(let message): return "update:\(message)"
        case .search(let message): return "search:\(message)"
        case .contentSearch(let message): return "content:\(message)"
        }
    }

    var message: String {
        switch self {
        case .initialization(let message): return "索引服务初始化失败：\(message)"
        case .database(let message): return "数据库错误：\(message)"
        case .databaseMaintenance(let message): return message
        case .eventMonitor(let message): return "文件系统监控启动失败：\(message)"
        case .indexUpdate(let message): return "文件索引增量更新失败：\(message)"
        case .search(let message): return "搜索失败：\(message)"
        case .contentSearch(let message): return "正文搜索失败：\(message)"
        }
    }

    var canRetryInitialization: Bool {
        switch self {
        case .initialization, .database, .databaseMaintenance, .eventMonitor:
            return true
        default:
            return false
        }
    }

    var canRebuildDatabase: Bool {
        switch self {
        case .initialization, .database, .databaseMaintenance:
            return true
        default:
            return false
        }
    }

    var canOpenDatabaseDirectory: Bool {
        switch self {
        case .initialization, .database, .databaseMaintenance:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var queryText: String = ""
    @Published var mode: SearchMode = .mixed
    @Published var results: [SearchResult] = []
    @Published var indexedCount: Int = 0
    @Published var volumeCapabilities: [VolumeCapabilities] = []
    @Published var isIndexing = false
    @Published var lastError: PresentedError?
    @Published var integrityWarning: String? = nil
    @Published var isTruncated = false
    @Published var sortField: SortField = .relevance
    @Published var sortDirection: SortDirection = .descending

    private let roots: [URL]
    private var coordinator: SearchCoordinator?
    private var searchTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var eventApplyTasks: [UUID: Task<Void, Never>] = [:]
    private var eventMonitor: FileSystemEventMonitor?
    private var serviceGeneration = UUID()
    private var isRestartingService = false

    init(roots: [URL] = [URL(fileURLWithPath: NSHomeDirectory())]) {
        self.roots = roots
        startService()
    }

    private func startService() {
        let generation = UUID()
        serviceGeneration = generation
        let excluded = ["/System", "/private/var", "/Library/Caches"]
        volumeCapabilities = APFSVolumeInspector.inspect(roots: roots)

        do {
            let indexer = try FileIndexer(
                configuration: IndexerConfiguration(roots: roots, excludedPaths: excluded)
            )
            let ripgrep = RipgrepSearcher(configuration: RipgrepConfiguration())
            let coordinator = SearchCoordinator(indexer: indexer, ripgrepSearcher: ripgrep, roots: roots)
            self.coordinator = coordinator

            eventMonitor = FileSystemEventMonitor(roots: roots) { [weak self, coordinator] changes, eventID in
                Task { @MainActor [weak self] in
                    guard let self, self.serviceGeneration == generation else { return }
                    let taskID = UUID()
                    let applyTask = Task { @MainActor [weak self] in
                        defer { self?.eventApplyTasks[taskID] = nil }
                        guard let self, self.serviceGeneration == generation else { return }
                        do {
                            try await coordinator.apply(changes: changes, eventID: eventID)
                            guard self.serviceGeneration == generation else { return }
                        } catch is CancellationError {
                            return
                        } catch {
                            guard self.serviceGeneration == generation else { return }
                            self.lastError = .indexUpdate(error.localizedDescription)
                        }
                    }
                    self.eventApplyTasks[taskID] = applyTask
                }
            }

            startupTask = Task { @MainActor [weak self] in
                guard let self, self.serviceGeneration == generation else { return }
                do {
                    let lastEvent = await coordinator.lastEventID()
                    try Task.checkCancellation()
                    guard self.serviceGeneration == generation else { return }
                    if let lastEvent {
                        try self.eventMonitor?.start(sinceEventId: lastEvent)
                    } else {
                        try self.eventMonitor?.start()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.serviceGeneration == generation else { return }
                    self.lastError = .eventMonitor(error.localizedDescription)
                }

                guard !Task.isCancelled, self.serviceGeneration == generation else { return }
                await self.setupIndex(using: coordinator, generation: generation)
            }
        } catch {
            guard serviceGeneration == generation else { return }
            coordinator = nil
            lastError = .initialization(error.localizedDescription)
        }
    }

    private func stopCurrentService() async {
        serviceGeneration = UUID()
        eventMonitor?.stop()
        eventMonitor = nil

        let startup = startupTask
        let search = searchTask
        let eventTasks = Array(eventApplyTasks.values)

        startup?.cancel()
        search?.cancel()
        for task in eventTasks { task.cancel() }

        await startup?.value
        await search?.value
        for task in eventTasks { await task.value }

        startupTask = nil
        searchTask = nil
        eventApplyTasks.removeAll()
        coordinator = nil
        isIndexing = false
    }

    private func restartService(deleteDatabase: Bool) {
        guard !isRestartingService else { return }
        isRestartingService = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestartingService = false }

            await self.stopCurrentService()
            self.lastError = nil
            self.results = []
            self.isTruncated = false
            self.indexedCount = 0

            if deleteDatabase {
                do {
                    try self.removeDatabaseFiles()
                } catch {
                    self.lastError = .databaseMaintenance(
                        "无法删除索引数据库：\(error.localizedDescription)"
                    )
                    return
                }
            }

            self.startService()
        }
    }

    func retryInitialization() {
        restartService(deleteDatabase: false)
    }

    private func removeDatabaseFiles() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let databaseDirectory = appSupport.appendingPathComponent("EverythingOnMac")
        let fileManager = FileManager.default

        for suffix in ["", "-wal", "-shm"] {
            let fileURL = databaseDirectory.appendingPathComponent("everything.db" + suffix)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    func deleteDatabaseAndRetry() {
        restartService(deleteDatabase: true)
    }

    func openDatabaseDirectory() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let databaseDirectory = appSupport.appendingPathComponent("EverythingOnMac")
        do {
            try FileManager.default.createDirectory(
                at: databaseDirectory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(databaseDirectory)
        } catch {
            lastError = .databaseMaintenance(
                "无法打开数据库目录：\(error.localizedDescription)"
            )
        }
    }

    private func setupIndex(using coordinator: SearchCoordinator, generation: UUID) async {
        let count = await coordinator.indexedItemCount()
        guard !Task.isCancelled, serviceGeneration == generation else { return }
        if count > 0 {
            indexedCount = count
        } else {
            await rebuildIndex(using: coordinator, generation: generation)
        }
    }

    func rebuildIndex() async {
        guard let coordinator else { return }
        await rebuildIndex(using: coordinator, generation: serviceGeneration)
    }

    private func rebuildIndex(using coordinator: SearchCoordinator, generation: UUID) async {
        guard serviceGeneration == generation else { return }
        isIndexing = true
        defer {
            if serviceGeneration == generation {
                isIndexing = false
            }
        }

        do {
            try await coordinator.rebuildIndex()
            try Task.checkCancellation()
            guard serviceGeneration == generation else { return }
            indexedCount = await coordinator.indexedItemCount()
            guard serviceGeneration == generation else { return }
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            guard serviceGeneration == generation else { return }
            lastError = .database("索引重建失败：\(error.localizedDescription)")
        }
    }

    func onQueryChanged() {
        searchTask?.cancel()
        guard let coordinator else {
            results = []
            isTruncated = false
            return
        }

        let generation = serviceGeneration
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                try Task.checkCancellation()
                guard self.serviceGeneration == generation else { return }

                var query = QueryParser.parse(self.queryText, mode: self.mode)
                if query.sortOption == nil {
                    query.sortOption = SortOption(
                        field: self.sortField,
                        direction: self.sortDirection
                    )
                }

                let responses = await coordinator.searchStream(query: query)
                for await response in responses {
                    try Task.checkCancellation()
                    guard self.serviceGeneration == generation else { return }
                    self.results = response.results
                    self.isTruncated = response.isTruncated
                    if response.skippedCorruptNodeCount > 0 {
                        self.integrityWarning = "索引中发现 \(response.skippedCorruptNodeCount) 条无法恢复路径的记录，结果可能不完整。建议重建索引。"
                    } else {
                        self.integrityWarning = nil
                    }
                    if let indexError = response.indexError {
                        switch indexError {
                        case .databaseError, .indexCorrupted:
                            self.lastError = .database(indexError.localizedDescription)
                        case .invalidPathPrefix:
                            self.lastError = .search(indexError.localizedDescription)
                        }
                    } else if let contentError = response.contentError {
                        self.lastError = .contentSearch(contentError.localizedDescription)
                    } else {
                        self.lastError = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.serviceGeneration == generation else { return }
                self.lastError = .search(error.localizedDescription)
            }
        }
    }

    func openResult(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: result.metadata.path)
        ])
    }
}
#endif
