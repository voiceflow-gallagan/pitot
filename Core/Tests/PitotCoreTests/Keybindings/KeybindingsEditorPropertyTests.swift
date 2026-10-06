import Testing

@testable import PitotCore

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

@Suite struct KeybindingsEditorPropertyTests {
    private static let contexts = ["Chat", "Global", "Task", "Select"]
    private static let keys = ["ctrl+k", "Ctrl+K", "ctrl+j", "meta+p", "shift+tab", "ctrl+x ctrl+k", "y", "ctrl+shift+c"]
    private static let actions = ["chat:stash", "chat:submit", "app:exit", "select:accept", "messageSelector:up", "chat:levitate"]

    private func blockBytes(_ bytes: [UInt8]) throws -> [[UInt8]] {
        let document = try JSONScanner.scan(bytes)
        guard case .array(let elements)? = document.node(at: ["bindings"])?.kind else { return [] }
        return elements.map { document.rawBytes(of: $0) }
    }

    @Test func randomEditSequencesStayValidAndLeaveOtherBlocksAlone() throws {
        var random = SeededGenerator(seed: 20_261_006)
        let catalog = try KeybindingsEditorTests.catalog()
        var bytes = Array(KeybindingsEditorTests.sample)
        var applied = 0

        for iteration in 0..<300 {
            let editor = try KeybindingsEditor(catalog: catalog, document: JSONScanner.scan(bytes))
            let context = Self.contexts[random.next(Self.contexts.count)]
            let key = Self.keys[random.next(Self.keys.count)]
            let action = Self.actions[random.next(Self.actions.count)]
            let plan: KeybindingsEditor.Plan
            switch random.next(4) {
            case 0: plan = editor.addBinding(context: context, key: key, action: action)
            case 1: plan = editor.changeAction(context: context, key: key, newAction: action)
            case 2: plan = editor.unbind(context: context, key: key)
            default: plan = editor.removeBinding(context: context, key: key)
            }
            if plan.isBlocked {
                #expect(plan.operations.isEmpty, "iteration \(iteration)")
                continue
            }

            let before = try blockBytes(bytes)
            for operation in plan.operations {
                bytes = try JSONEdit.apply(operation, to: bytes).bytes
            }
            applied += 1
            let after = try blockBytes(bytes)
            _ = try KeybindingsFile(document: JSONScanner.scan(bytes))

            switch plan.operations.first {
            case .editElement(_, let index, _)?:
                #expect(after.count == before.count, "iteration \(iteration)")
                #expect(after.indices.filter { $0 != index }.allSatisfy { after[$0] == before[$0] }, "iteration \(iteration)")
            case .removeElement(_, let index)?:
                var expected = before
                expected.remove(at: index)
                #expect(after == expected, "iteration \(iteration)")
            case .appendElement?:
                #expect(Array(after.dropLast()) == before, "iteration \(iteration)")
            default:
                #expect(Array(after.prefix(before.count)) == before, "iteration \(iteration)")
            }
        }
        #expect(applied > 100)
    }
}
