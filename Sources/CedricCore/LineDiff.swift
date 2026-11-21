import Foundation

/// A line diff (Myers' O(ND) algorithm, no dependencies) and its
/// side-by-side layout for File › Compare › Compare With….
public enum LineDiff {
    public enum Op: Equatable, Sendable {
        case equal(Int, Int)   // a line, b line
        case delete(Int)       // a line
        case insert(Int)       // b line
    }

    public enum RowKind: Equatable, Sendable { case same, removed, added, changed }

    /// One row of the side-by-side view: a line on the left, the right, or both.
    public struct Row: Equatable, Sendable {
        public var kind: RowKind
        public var left: Int?
        public var right: Int?
        public init(_ kind: RowKind, _ left: Int?, _ right: Int?) { self.kind = kind; self.left = left; self.right = right }
    }

    /// Beyond this many differences the middle part is reported as one
    /// replaced block instead (memory is O(D²)).
    public static let maxEditDistance = 4000

    /// The shortest edit script turning `a` into `b`, in order.
    public static func diff(_ a: [String], _ b: [String]) -> [Op] {
        // Lines as integers: hashing once makes the inner loop cheap.
        var ids: [String: Int] = [:]
        let x = a.map { s in ids[s] ?? { let n = ids.count; ids[s] = n; return n }() }
        let y = b.map { s in ids[s] ?? { let n = ids.count; ids[s] = n; return n }() }
        var ops: [Op] = []
        // Common prefix and suffix need no search.
        var pre = 0
        while pre < x.count, pre < y.count, x[pre] == y[pre] { ops.append(.equal(pre, pre)); pre += 1 }
        var suf = 0
        while suf < x.count - pre, suf < y.count - pre, x[x.count - 1 - suf] == y[y.count - 1 - suf] { suf += 1 }
        let xa = Array(x[pre..<(x.count - suf)]), yb = Array(y[pre..<(y.count - suf)])
        ops += middle(xa, yb).map {
            switch $0 {
            case .equal(let i, let j): return .equal(i + pre, j + pre)
            case .delete(let i): return .delete(i + pre)
            case .insert(let j): return .insert(j + pre)
            }
        }
        for k in 0..<suf { ops.append(.equal(x.count - suf + k, y.count - suf + k)) }
        return ops
    }

    static func middle(_ x: [Int], _ y: [Int]) -> [Op] {
        let n = x.count, m = y.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        let maxD = min(n + m, maxEditDistance)
        let off = maxD + 1
        var v = [Int32](repeating: 0, count: 2 * maxD + 3)
        // trace[d] holds v[-d...d] after step d.
        var trace: [[Int32]] = []
        var found = -1
        outer: for d in 0...maxD {
            for k in stride(from: -d, through: d, by: 2) {
                var px: Int
                if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) {
                    px = Int(v[off + k + 1])          // down: insertion
                } else {
                    px = Int(v[off + k - 1]) + 1      // right: deletion
                }
                var py = px - k
                while px < n, py < m, x[px] == y[py] { px += 1; py += 1 }
                v[off + k] = Int32(px)
                if px >= n && py >= m {
                    trace.append(Array(v[(off - d)...(off + d)]))
                    found = d
                    break outer
                }
            }
            trace.append(Array(v[(off - d)...(off + d)]))
        }
        guard found >= 0 else {
            // Too different: one replaced block.
            return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) }
        }
        // Walk back through the trace.
        var ops: [Op] = []
        var px = n, py = m
        for d in stride(from: found, to: 0, by: -1) {
            let prev = trace[d - 1]                  // v after step d-1, indexed k + (d-1)
            func pv(_ k: Int) -> Int { Int(prev[k + d - 1]) }
            let k = px - py
            let down = k == -d || (k != d && pv(k - 1) < pv(k + 1))
            let pk = down ? k + 1 : k - 1
            let sx = pv(pk), sy = sx - pk
            let mx = down ? sx : sx + 1
            let my = mx - k
            while px > mx && py > my { px -= 1; py -= 1; ops.append(.equal(px, py)) }
            if down { ops.append(.insert(sy)) } else { ops.append(.delete(sx)) }
            px = sx; py = sy
        }
        while px > 0 && py > 0 { px -= 1; py -= 1; ops.append(.equal(px, py)) }
        return ops.reversed()
    }

    /// Side-by-side rows: a run of deletions followed by insertions pairs
    /// up as changed lines; the leftovers are removed or added lines with
    /// a blank on the other side.
    public static func rows(_ ops: [Op]) -> [Row] {
        var rows: [Row] = []
        var dels: [Int] = [], ins: [Int] = []
        func flush() {
            let paired = min(dels.count, ins.count)
            for k in 0..<paired { rows.append(Row(.changed, dels[k], ins[k])) }
            for k in paired..<dels.count { rows.append(Row(.removed, dels[k], nil)) }
            for k in paired..<ins.count { rows.append(Row(.added, nil, ins[k])) }
            dels = []; ins = []
        }
        for op in ops {
            switch op {
            case .equal(let i, let j): flush(); rows.append(Row(.same, i, j))
            case .delete(let i): dels.append(i)
            case .insert(let j): ins.append(j)
            }
        }
        flush()
        return rows
    }

    /// Splits text into lines for diffing (a trailing newline isn't an extra line).
    public static func lines(_ text: String) -> [String] {
        var l = text.components(separatedBy: "\n")
        if l.count > 1, l.last == "" { l.removeLast() }
        if l == [""] { return [] }
        return l
    }

    /// Applies an edit script to `a`, for checking: must give `b`.
    public static func apply(_ ops: [Op], a: [String], b: [String]) -> [String] {
        ops.compactMap { op in
            switch op {
            case .equal(let i, _): return a[i]
            case .delete: return nil
            case .insert(let j): return b[j]
            }
        }
    }
}
