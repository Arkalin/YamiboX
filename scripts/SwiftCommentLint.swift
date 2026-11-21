import CryptoKit
import Foundation
import SwiftParser
import SwiftSyntax

private struct Comment: Encodable {
    let path: String
    let line: Int
    let column: Int
    let endLine: Int
    let offset: Int
    let length: Int
    let kind: String
    let text: String
    let exempt: Bool
    var wholeLines: [Int] = []

    var fingerprint: String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private func scan(_ path: String, includeWholeLines: Bool) throws -> [Comment] {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    let source = String(decoding: bytes, as: UTF8.self)
    guard source.utf8.elementsEqual(bytes) else {
        throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: path])
    }
    let tree = Parser.parse(source: source)
    let locations = SourceLocationConverter(fileName: path, tree: tree)
    var comments: [Comment] = []

    func collect(_ trivia: Trivia, startingAt position: AbsolutePosition) {
        var offset = position.utf8Offset
        for piece in trivia {
            let length = piece.sourceLength.utf8Length
            let start = offset
            offset += length
            let kind: String
            let text: String
            switch piece {
            case .lineComment(let value): (kind, text) = ("line", value)
            case .docLineComment(let value): (kind, text) = ("docLine", value)
            case .blockComment(let value): (kind, text) = ("block", value)
            case .docBlockComment(let value): (kind, text) = ("docBlock", value)
            default: continue
            }
            let location = locations.location(for: AbsolutePosition(utf8Offset: start))
            let end = locations.location(for: AbsolutePosition(utf8Offset: offset - 1))
            let exempt = path == "Package.swift" && start == 0
                && text.range(of: #"^// swift-tools-version: [0-9]+\.[0-9]+(\.[0-9]+)?[ \t]*$"#,
                              options: .regularExpression) != nil
            comments.append(Comment(
                path: path, line: location.line, column: location.column, endLine: end.line,
                offset: start, length: length, kind: kind, text: text, exempt: exempt
            ))
        }
    }

    for token in tree.tokens(viewMode: .sourceAccurate) {
        collect(token.leadingTrivia, startingAt: token.position)
        collect(token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia)
    }
    if includeWholeLines && !comments.isEmpty {
        var marked = Array(source.utf8)
        for comment in comments {
            for byte in comment.offset..<(comment.offset + comment.length) where marked[byte] != 10 && marked[byte] != 13 {
                marked[byte] = 32
            }
        }
        var blankLines: Set<Int> = []
        var line = 1
        var blank = true
        for (index, byte) in marked.enumerated() {
            switch byte {
            case 10 where index > 0 && marked[index - 1] == 13: continue
            case 10, 13:
                if blank { blankLines.insert(line) }
                line += 1
                blank = true
            case 9, 11, 12, 32: continue
            default: blank = false
            }
        }
        if blank { blankLines.insert(line) }
        for index in comments.indices {
            comments[index].wholeLines = (comments[index].line...comments[index].endLine).filter {
                blankLines.remove($0) != nil
            }
        }
    }
    return comments
}

private typealias Baseline = [String: [String: Int]]

private func readBaseline(_ path: String) throws -> Baseline {
    try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

private func writeBaseline(_ baseline: Baseline, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(baseline)
    data.append(10)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func excess(in current: Baseline, over prior: Baseline) -> Int {
    current.reduce(0) { total, entry in
        total + entry.value.reduce(0) { subtotal, fingerprint in
            subtotal + max(0, fingerprint.value - (prior[entry.key]?[fingerprint.key] ?? 0))
        }
    }
}

private func error(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func run() throws -> Int32 {
    let arguments = CommandLine.arguments
    let mode = arguments[1]
    let paths = Set(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\0").map(String.init)).sorted()
    let inventory = mode == "inventory"
    let bootstrap = mode == "bootstrap"
    let verifiedBaseline = inventory || bootstrap ? [:] : try readBaseline(arguments[2])
    if arguments.count == 4 {
        let old = try readBaseline(arguments[3])
        let growth = excess(in: verifiedBaseline, over: old)
        if growth != 0 {
            error("The Swift comment baseline adds \(growth) allowance(s) relative to the reference commit.")
            return 1
        }
    }
    var current: Baseline = [:]
    var violations = 0
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for path in paths where path.hasSuffix(".swift") && FileManager.default.fileExists(atPath: path) {
        for comment in try scan(path, includeWholeLines: inventory) {
            if inventory {
                var encoded = try encoder.encode(comment)
                encoded.append(10)
                FileHandle.standardOutput.write(encoded)
                continue
            }
            if comment.exempt { continue }
            let hash = comment.fingerprint
            let count = (current[path]?[hash] ?? 0) + 1
            current[path, default: [:]][hash] = count
            if !bootstrap && count > (verifiedBaseline[path]?[hash] ?? 0) {
                error("\(path):\(comment.line):\(comment.column): error: New Swift comment; explain a decision in an ADR instead.")
                violations += 1
            }
        }
    }
    if inventory { return 0 }
    if violations > 0 { return 1 }
    let stale = excess(in: verifiedBaseline, over: current)
    if mode == "check" && stale > 0 {
        error("\(stale) removed Swift comment allowance(s). Run bash scripts/check-comments.sh prune.")
        return 1
    }
    if bootstrap || mode == "prune" {
        try writeBaseline(current, to: arguments[2])
    }
    let count = current.values.flatMap(\.values).reduce(0, +)
    print("Swift comment ratchet: \(count) grandfathered comments across \(current.count) files.")
    return 0
}

do {
    exit(try run())
} catch {
    FileHandle.standardError.write(Data("Swift comment lint failed: \(error)\n".utf8))
    exit(1)
}
