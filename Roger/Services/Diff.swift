import Foundation

struct DiffLine: Identifiable, Hashable {
    enum Kind { case same, added, removed }
    let id = UUID()
    let kind: Kind
    let text: String
}

enum Diff {
    static let maxLines = 600

    /// Line-based diff (LCS). Falls back to remove-all/add-all for very large inputs.
    static func lines(old: String, new: String) -> [DiffLine] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        guard a.count <= maxLines, b.count <= maxLines else {
            return a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        }
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                result.append(DiffLine(kind: .removed, text: a[i])); i += 1
            } else {
                result.append(DiffLine(kind: .added, text: b[j])); j += 1
            }
        }
        while i < n { result.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
        while j < m { result.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        return result
    }

    /// Keeps only changed lines plus `context` unchanged lines around them.
    static func collapse(_ lines: [DiffLine], context: Int = 3) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return Array(lines.prefix(context * 2)) }
        var keep = Set<Int>()
        for idx in changed { for k in max(0, idx - context)...min(lines.count - 1, idx + context) { keep.insert(k) } }
        var out: [DiffLine] = []
        var last = -1
        for idx in lines.indices where keep.contains(idx) {
            if last >= 0 && idx != last + 1 { out.append(DiffLine(kind: .same, text: "⋯")) }
            out.append(lines[idx]); last = idx
        }
        return out
    }
}
