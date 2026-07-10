import Foundation

protocol ContentSearching {
    func searchContent(query: String, root: URL) throws -> [ContentMatch]
}

struct RipgrepSearcher: ContentSearching {
    func searchContent(query: String, root: URL) throws -> [ContentMatch] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rg", "--json", "--line-number", "--column", "--smart-case", query, root.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus > 1 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw SearchError.ripgrepFailed(errorText)
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            return []
        }

        return Self.parseMatches(from: output)
    }

    static func parseMatches(from jsonLines: String) -> [ContentMatch] {
        jsonLines
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8) else {
                    return nil
                }

                guard
                    let event = try? JSONDecoder().decode(RipgrepEvent.self, from: data),
                    event.type == "match",
                    let path = event.data.path?.text,
                    let lineNumber = event.data.line_number,
                    let lineText = event.data.lines?.text
                else {
                    return nil
                }

                return ContentMatch(filePath: path, lineNumber: lineNumber, lineText: lineText.trimmingCharacters(in: .newlines))
            }
    }
}

private struct RipgrepEvent: Decodable {
    struct DataPayload: Decodable {
        struct TextWrapper: Decodable {
            let text: String
        }

        let path: TextWrapper?
        let lines: TextWrapper?
        let line_number: Int?
    }

    let type: String
    let data: DataPayload
}

enum SearchError: Error {
    case ripgrepFailed(String)
}
