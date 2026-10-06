import Testing

@testable import PitotCore

@Test func packageLoads() {
    #expect(PitotCore.name == "PitotCore")
}
