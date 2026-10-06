import PitotCore
import ConformanceKit
import Foundation

let usage = """
    Usage: conformance [--cases | --dry-run] [--work-dir <path>]

      --cases           List the cases and the values Pitot expects. Writes and runs nothing.
      --dry-run         Write the fixtures and print the Claude Code commands. Runs nothing.
      --work-dir <path> Folder for the throwaway projects. Default: a new folder in the temporary directory.

    Without --cases or --dry-run it runs Claude Code once per batch and exits 1 if any case fails.
    CONFORMANCE_MUTATE=1 flips one expected value, so that run must fail.

    """

enum Mode {
    case run, cases, dryRun
}

func parse(_ arguments: [String]) -> (mode: Mode, workDirectory: URL?)? {
    var mode = Mode.run
    var workDirectory: URL?
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "--cases":
            mode = .cases
        case "--dry-run":
            mode = .dryRun
        case "--work-dir":
            guard let path = remaining.popFirst() else { return nil }
            workDirectory = URL(fileURLWithPath: path, isDirectory: true)
        default:
            return nil
        }
    }
    return (mode, workDirectory)
}

func fail(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("conformance: \(message)\n".utf8))
    exit(status)
}

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
guard Catalog.batches.count <= Catalog.maximumRuns else {
    fail("\(Catalog.batches.count) batches, more than the \(Catalog.maximumRuns) runs allowed")
}

let environment = ProcessInfo.processInfo.environment
let mutate = environment["CONFORMANCE_MUTATE"] == "1"
let requestedDirectory = options.workDirectory ?? FileManager.default.temporaryDirectory
    .appendingPathComponent("pitot-conformance-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)

if options.mode == .cases {
    print(Report.caseList(Catalog.batches.map { BatchPlan(batch: $0, workDirectory: requestedDirectory) }, mutate: mutate), terminator: "")
    exit(0)
}

let plans: [BatchPlan]
do {
    let workDirectory = try Workspace.create(requestedDirectory)
    plans = Catalog.batches.map { BatchPlan(batch: $0, workDirectory: workDirectory) }
    try plans.forEach(Workspace.write)
} catch {
    fail("cannot write the fixtures: \(error)")
}

let located = try? ClaudeProbe().locate()

if options.mode == .dryRun {
    let executable = located ?? URL(fileURLWithPath: "claude")
    for plan in plans {
        print(ClaudeRunner.commandLine(executable: executable, plan: plan))
    }
    exit(0)
}

guard let executable = located else {
    fail("claude not found in \(ClaudeProbe.defaultSearchPaths.map(\.path).joined(separator: ", "))")
}
let version = (try? await ClaudeProbe(timeout: .seconds(10)).probe()).map { "\($0.version)" } ?? "unknown version"
if mutate {
    print("CONFORMANCE_MUTATE=1: the expected value of \(Catalog.mutationTarget.check) in \(Catalog.mutationTarget.caseID) is flipped. This run must fail.")
}

let folders = ProjectFolders(environment: environment)
let foldersBefore = folders.names()
let childEnvironment = ClaudeRunner.environment(from: environment)
var results: [CaseResult] = []
var cost = 0.0
for plan in plans {
    print("Running batch \(plan.batch.name)")
    if let problem = ClaudeRunner.run(plan, executable: executable, environment: childEnvironment) {
        print("  Claude Code \(problem). Its error output is in \(plan.stderrURL.path)")
    }
    let observation = Observation.read(plan)
    cost += observation.costUSD ?? 0
    let expectation = Expectation(plan: plan)
    results += plan.batch.cases.map { CaseResult($0, expectation: expectation, observation: observation, mutate: mutate) }
}
let cleanup = folders.removeEmpty(projects: plans.map(\.projectDirectory), before: foldersBefore)

print("")
print(Report.table(results))
print("Claude Code \(version), \(plans.count) runs, reported cost $\(String(format: "%.4f", cost)).")
print("Fixtures and raw output: \(plans.first.map { $0.projectDirectory.deletingLastPathComponent().path } ?? "")")
if !cleanup.removed.isEmpty {
    print("Removed empty folders Claude Code created in \(folders.root.path): \(cleanup.removed.joined(separator: ", "))")
}
if !cleanup.kept.isEmpty {
    print("Left in \(folders.root.path) because they hold files: \(cleanup.kept.joined(separator: ", "))")
}
exit(results.allSatisfy(\.passed) ? 0 : 1)
