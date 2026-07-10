import Foundation

public struct RipgrepConfiguration: Sendable {
    public var executablePath: String
    public var timeoutSeconds: TimeInterval

    public init(executablePath: String = "/usr/bin/rg", timeoutSeconds: TimeInterval = 8) {
        self.executablePath = executablePath
        self.timeoutSeconds = timeoutSeconds
    }
}

public actor RipgrepSearcher {
    private let configuration: RipgrepConfiguration

    public init(configuration: RipgrepConfiguration = RipgrepConfiguration()) {
        self.configuration = configuration
    }

    public func search(query: SearchQuery, roots: [URL]) async -> [SearchResult] {
        guard query.hasContentPattern, query.mode != .filenameOnly else {
            return []
        }

        let pattern = query.terms.joined(separator: " ")
        guard !pattern.isEmpty else {
            return []
        }

        var args = ["--json", "--line-number", "--column", "--color", "never", "--no-heading"]
        args.append(query.isRegex ? pattern : "--fixed-strings")
        if !query.isRegex {
            args.append(pattern)
        }
        if query.isCaseSensitive {
            args.append("--case-sensitive")
        } else {
            args.append("--ignore-case")
        }
        for ext in query.fileExtensions {
            args.append(contentsOf: ["-g", "*.\(ext)"])
        }
        for root in roots {
            args.append(root.path)
        }

        do {
            let output = try await runRipgrep(arguments: args)
            return decode(jsonLines: output)
        } catch {
            return []
        }
    }

    private func runRipgrep(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = sanitize(arguments)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(self.configuration.timeoutSeconds))
                if process.isRunning {
                    process.terminate()
                }
                throw RipgrepError.timedOut
            }

            guard let result = try await group.next() else {
                throw RipgrepError.failedToExecute
            }
            group.cancelAll()
            return result
        }
    }

    private func sanitize(_ args: [String]) -> [String] {
        args.filter { !$0.contains("\0") }
    }

    private func decode(jsonLines: String) -> [SearchResult] {
        var grouped: [String: SearchResult] = [:]

        for line in jsonLines.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(RipgrepEvent.self, from: data),
                  event.type == "match",
                  let payload = event.data,
                  let path = payload.path?.text,
                  let lines = payload.lines?.text
            else {
                continue
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

            if var existing = grouped[path] {
                existing.source.insert(.contentRipgrep)
                existing.contentMatches.append(match)
                grouped[path] = existing
            } else {
                grouped[path] = SearchResult(metadata: metadata, source: [.contentRipgrep], contentMatches: [match])
            }
        }

        return grouped.values.sorted { $0.metadata.path < $1.metadata.path }
    }
}

private enum RipgrepError: Error {
    case failedToExecute
    case timedOut
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
