import Testing

@testable import PitotCore

@Suite("Version gate")
struct VersionGateTests {
    private let gated = CatalogSamples.tweak("gated", minVersion: "2.1.257")

    private func version(_ text: String) throws -> ClaudeVersion {
        try #require(ClaudeVersion(parsing: text))
    }

    @Test func tweakWithoutMinimumIsAlwaysAvailable() throws {
        let tweak = CatalogSamples.tweak("plain")

        #expect(VersionGate.status(tweak, installed: try version("1.0.0")) == .available)
        #expect(VersionGate.status(tweak, installed: nil) == .available)
    }

    @Test func equalVersionIsAvailable() throws {
        #expect(VersionGate.status(gated, installed: try version("2.1.257")) == .available)
    }

    @Test func olderVersionNeedsTheMinimum() throws {
        #expect(VersionGate.status(gated, installed: try version("2.1.256")) == .needs("2.1.257"))
        #expect(VersionGate.status(gated, installed: try version("1.9.999")) == .needs("2.1.257"))
    }

    @Test func newerVersionIsAvailable() throws {
        #expect(VersionGate.status(gated, installed: try version("2.1.258")) == .available)
        #expect(VersionGate.status(gated, installed: try version("3.0.0")) == .available)
    }

    @Test func unknownInstalledVersionIsUnknown() {
        #expect(VersionGate.status(gated, installed: nil) == .unknown)
    }

    @Test func prereleaseOfTheMinimumIsBelowIt() throws {
        #expect(VersionGate.status(gated, installed: try version("2.1.257-beta.1")) == .needs("2.1.257"))
        #expect(VersionGate.status(gated, installed: try version("2.1.258-beta.1")) == .available)
    }

    @Test func prereleaseMinimumAcceptsItsRelease() throws {
        let tweak = CatalogSamples.tweak("preview", minVersion: "2.1.257-beta.2")

        #expect(VersionGate.status(tweak, installed: try version("2.1.257")) == .available)
        #expect(VersionGate.status(tweak, installed: try version("2.1.257-beta.1")) == .needs("2.1.257-beta.2"))
    }

    @Test func unparsableMinimumIsUnknown() throws {
        #expect(VersionGate.status(CatalogSamples.tweak("odd", minVersion: "v2.1"), installed: try version("2.1.257")) == .unknown)
    }
}
