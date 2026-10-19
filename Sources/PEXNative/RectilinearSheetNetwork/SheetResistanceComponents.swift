/// Invocation-local disjoint sets. The smallest cell index is the stable representative.
struct SheetResistanceComponents {
    var parents: [Int]
    init(count: Int) { parents = Array(0..<count) }
    mutating func root(_ index: Int, work: inout SheetResistanceWork) throws(NativeSheetResistanceError) -> Int {
        var current = index
        while parents[current] != current { try work.visit(); current = parents[current] }
        var cursor = index
        while parents[cursor] != current {
            try work.visit()
            let next = parents[cursor]; parents[cursor] = current; cursor = next
        }
        return current
    }
    mutating func join(_ a: Int, _ b: Int, work: inout SheetResistanceWork) throws(NativeSheetResistanceError) {
        let first = try root(a, work: &work), second = try root(b, work: &work)
        if first != second { parents[max(first, second)] = min(first, second) }
    }
}
