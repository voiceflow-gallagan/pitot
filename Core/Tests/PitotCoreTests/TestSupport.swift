import Foundation

@testable import PitotCore

enum Fixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let directory = repoRoot.appendingPathComponent("Fixtures")

    static let validNames = [
        "settings-synthetic", "crlf", "tabs", "no-trailing-newline", "unicode-escapes",
        "numbers", "integer-like-keys", "nested-arrays", "empty-object", "single-line",
        "deep-nest", "env-block", "keybindings", "keybindings-tabs", "keybindings-crlf", "array-single-line",
        "array-empty", "array-numbers", "nested-array-objects",
    ]

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    static func bytes(atRepoPath path: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: repoRoot.appendingPathComponent(path)))
    }
}

extension Array where Element == UInt8 {
    init(_ text: String) {
        self = Array(text.utf8)
    }

    var text: String {
        String(decoding: self, as: UTF8.self)
    }
}

final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitot-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL {
        let file = file(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    deinit {
        makeWritable(url)
        try? FileManager.default.removeItem(at: url)
    }

    private func makeWritable(_ directory: URL) {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { return }
        chmod(directory.path, 0o755)
        for case let relative as String in enumerator {
            chmod(directory.appendingPathComponent(relative).path, 0o755)
        }
    }
}

func readBytes(_ url: URL) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: url))
}
