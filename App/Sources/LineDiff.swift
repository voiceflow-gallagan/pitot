import Foundation

struct DiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case context
        case added
        case removed
        case gap
    }

    let id: Int
    let kind: Kind
    let text: String
}

enum LineDiff {
    static let contextLines = 2

    static func unified(old: [UInt8], new: [UInt8]) -> [DiffLine] {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        let difference = newLines.difference(from: oldLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var merged: [(kind: DiffLine.Kind, text: String)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOffsets.contains(oldIndex) {
                merged.append((.removed, oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedOffsets.contains(newIndex) {
                merged.append((.added, newLines[newIndex]))
                newIndex += 1
            } else if oldIndex < oldLines.count {
                merged.append((.context, oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return collapse(merged)
    }

    private static func collapse(_ merged: [(kind: DiffLine.Kind, text: String)]) -> [DiffLine] {
        let changed = merged.indices.filter { merged[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            let lower = max(0, index - contextLines)
            let upper = min(merged.count - 1, index + contextLines)
            keep.formUnion(lower...upper)
        }
        var result: [DiffLine] = []
        var previous = -1
        for index in keep.sorted() {
            if previous >= 0, index != previous + 1 {
                result.append(DiffLine(id: result.count, kind: .gap, text: "..."))
            }
            result.append(DiffLine(id: result.count, kind: merged[index].kind, text: merged[index].text))
            previous = index
        }
        return result
    }

    private static func lines(of bytes: [UInt8]) -> [String] {
        var parts = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
