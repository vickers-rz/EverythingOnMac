import Foundation

@main
struct EverythingOnMac {
    static func main() {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            let engine = SearchEngine()
            let results = try engine.search(options: options)
            printResults(results)
        } catch {
            writeToStandardError("Error: \(error)\n")
            writeToStandardError("\(usage)\n")
            Foundation.exit(1)
        }
    }

    private static func parseArguments(_ args: [String]) throws -> SearchOptions {
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var nameQuery: String?
        var contentQuery: String?
        var includeHidden = false
        var maxResults = 200

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--root":
                index += 1
                root = URL(fileURLWithPath: try argumentValue(for: "--root", in: args, at: index))
            case "--name":
                index += 1
                nameQuery = try argumentValue(for: "--name", in: args, at: index)
            case "--content":
                index += 1
                contentQuery = try argumentValue(for: "--content", in: args, at: index)
            case "--hidden":
                includeHidden = true
            case "--limit":
                index += 1
                let value = try argumentValue(for: "--limit", in: args, at: index)
                maxResults = Int(value) ?? maxResults
            case "--help", "-h":
                print(usage)
                Foundation.exit(0)
            default:
                throw ArgumentError.invalidArgument(arg)
            }
            index += 1
        }

        return SearchOptions(
            root: root,
            fileNameQuery: nameQuery,
            contentQuery: contentQuery,
            includeHidden: includeHidden,
            maxResults: maxResults
        )
    }

    private static func argumentValue(for option: String, in args: [String], at index: Int) throws -> String {
        guard index < args.count else {
            throw ArgumentError.missingValue(option)
        }
        return args[index]
    }

    private static func printResults(_ results: [SearchResult]) {
        for result in results {
            let modified = result.file.modifiedAt?.formatted(date: .numeric, time: .standard) ?? "n/a"
            let idPart = result.file.fileID.map { " | id=\($0)" } ?? ""
            let fsPart = result.file.volumeFormatDescription.map { " | fs=\($0)" } ?? ""
            print("\(result.file.path) | size=\(result.file.size) | modified=\(modified)\(idPart)\(fsPart)")
            for match in result.contentMatches {
                print("  L\(match.lineNumber): \(match.lineText)")
            }
        }

        print("Total: \(results.count)")
    }

    private static func writeToStandardError(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }

    private static let usage = """
Usage: EverythingOnMac [options]
  --root <path>       Search root directory (default: current directory)
  --name <keyword>    Filter files by file name
  --content <text>    Search file contents using ripgrep (rg)
  --hidden            Include hidden files
  --limit <number>    Maximum number of files to index (default: 200)
  --help              Show this help
"""
}

enum ArgumentError: Error {
    case missingValue(String)
    case invalidArgument(String)
}
