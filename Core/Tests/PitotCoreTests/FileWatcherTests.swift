import Foundation
import Testing

@testable import PitotCore

private actor Recorder {
    private(set) var changes: [FileChange] = []

    func append(_ change: FileChange) {
        changes.append(change)
    }
}

@Suite("Watcher", .serialized)
struct FileWatcherTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// Starts a watcher, runs `action` once it is live, and returns every event
    /// delivered within a window well past the 200 ms debounce.
    private func changes(of url: URL, during action: () throws -> Void) async throws -> [FileChange] {
        let watcher = try FileWatcher(url: url)
        let recorder = Recorder()
        let consumer = Task {
            for await change in watcher.changes {
                await recorder.append(change)
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        try action()
        try await Task.sleep(for: .milliseconds(1500))
        watcher.stop()
        await consumer.value
        return await recorder.changes
    }

    @Test func inPlaceWriteGivesOneEvent() async throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        let events = try await changes(of: url) {
            let handle = try FileHandle(forUpdating: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("{\"a\": 2}\n".utf8))
            try handle.close()
        }
        #expect(events == [.modified])
    }

    @Test func scriptedAtomicRenameGivesOneEvent() async throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        let events = try await changes(of: url) {
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/bin/sh")
            script.arguments = ["-c", "printf '{\"a\": 2}\\n' > \"$1.swp\" && mv -f \"$1.swp\" \"$1\"", "sh", url.path]
            try script.run()
            script.waitUntilExit()
            #expect(script.terminationStatus == 0)
        }
        #expect(events == [.modified])
        #expect(try readBytes(url).text == "{\"a\": 2}\n")
    }

    @Test func deleteGivesOneEvent() async throws {
        let url = try directory.write("settings.json", "{}\n")
        let events = try await changes(of: url) {
            try FileManager.default.removeItem(at: url)
        }
        #expect(events == [.deleted])
    }

    @Test func createGivesOneEvent() async throws {
        let url = directory.file("settings.json")
        let events = try await changes(of: url) {
            try Data("{}\n".utf8).write(to: url)
        }
        #expect(events == [.created])
    }

    @Test func burstOfWritesIsDebouncedIntoOneEvent() async throws {
        let url = try directory.write("settings.json", "{\"n\": 0}\n")
        let events = try await changes(of: url) {
            for value in 1...5 {
                try Data("{\"n\": \(value)}\n".utf8).write(to: url)
            }
        }
        #expect(events == [.modified])
    }

    @Test func ignoresOtherFilesInTheFolder() async throws {
        let url = try directory.write("settings.json", "{}\n")
        let events = try await changes(of: url) {
            try Data("{}\n".utf8).write(to: directory.file("settings.local.json"))
            try Data("{}\n".utf8).write(to: directory.file("other.json"), options: .atomic)
        }
        #expect(events.isEmpty)
    }

    @Test func rejectsMissingFolder() {
        let url = directory.file("missing/settings.json")
        #expect(throws: FileWatcherError.directoryMissing(path: directory.file("missing").path)) {
            try FileWatcher(url: url)
        }
    }
}
