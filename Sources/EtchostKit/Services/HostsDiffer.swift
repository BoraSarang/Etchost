import Foundation

/// 행 단위 hosts diff. 적용 전 "이번 적용에서 바뀌는 줄" 미리보기용.
/// LCS 기반이므로 소규모 파일에 적합하고, 대용량은 prefix/suffix 방식으로 폴백한다.
public struct HostsDiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case added
        case removed
        case context
    }

    public let id: UUID
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.id = UUID()
        self.kind = kind
        self.text = text
    }

    public static func == (lhs: HostsDiffLine, rhs: HostsDiffLine) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}

public struct HostsDiffer: Sendable {
    /// LCS DP 상한 (행수 곱). 초과 시 prefix/suffix 폴백.
    private static let maxCells = 4_000_000

    public struct Summary: Equatable, Sendable {
        public let added: Int
        public let removed: Int

        public init(added: Int, removed: Int) {
            self.added = added
            self.removed = removed
        }

        public var isEmpty: Bool { added == 0 && removed == 0 }
    }

    /// old(현재 /etc/hosts) → new(합성 결과) diff. contextLines=0이면 변경 줄만 반환.
    public static func diff(old: String, new: String, contextLines: Int = 2) -> [HostsDiffLine] {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        if oldLines.count * newLines.count > maxCells {
            return prefixSuffixDiff(old: oldLines, new: newLines)
        }
        let script = lcsScript(old: oldLines, new: newLines)
        guard contextLines > 0 else { return script.filter { $0.kind != .context } }
        return withContext(script, context: contextLines)
    }

    public static func summary(of lines: [HostsDiffLine]) -> Summary {
        Summary(
            added: lines.count { $0.kind == .added },
            removed: lines.count { $0.kind == .removed })
    }

    // MARK: - LCS

    private static func lcsScript(old: [String], new: [String]) -> [HostsDiffLine] {
        let m = old.count
        let n = new.count
        var dp = [Int](repeating: 0, count: (m + 1) * (n + 1))
        func idx(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }
        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    if old[i - 1] == new[j - 1] {
                        dp[idx(i, j)] = dp[idx(i - 1, j - 1)] + 1
                    } else {
                        dp[idx(i, j)] = max(dp[idx(i - 1, j)], dp[idx(i, j - 1)])
                    }
                }
            }
        }
        var result: [HostsDiffLine] = []
        var i = m
        var j = n
        while i > 0, j > 0 {
            if old[i - 1] == new[j - 1] {
                result.append(HostsDiffLine(kind: .context, text: old[i - 1]))
                i -= 1
                j -= 1
            } else if dp[idx(i - 1, j)] >= dp[idx(i, j - 1)] {
                result.append(HostsDiffLine(kind: .removed, text: old[i - 1]))
                i -= 1
            } else {
                result.append(HostsDiffLine(kind: .added, text: new[j - 1]))
                j -= 1
            }
        }
        while i > 0 {
            result.append(HostsDiffLine(kind: .removed, text: old[i - 1]))
            i -= 1
        }
        while j > 0 {
            result.append(HostsDiffLine(kind: .added, text: new[j - 1]))
            j -= 1
        }
        return result.reversed()
    }

    /// 변경 덩어리 주변 context 줄만 남기고 나머지는 생략.
    private static func withContext(_ script: [HostsDiffLine], context: Int) -> [HostsDiffLine] {
        let changed = script.indices.filter { script[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed {
            for k in max(0, c - context)...min(script.count - 1, c + context) {
                keep.insert(k)
            }
        }
        return script.indices.compactMap { keep.contains($0) ? script[$0] : nil }
    }

    /// 대용량 폴백: 공통 prefix/suffix를 context로, 중간 전체를 removed+added로 취급.
    private static func prefixSuffixDiff(old: [String], new: [String]) -> [HostsDiffLine] {
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count - prefix, new.count - prefix),
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        var result: [HostsDiffLine] = []
        if prefix > 0 {
            result.append(contentsOf: old.prefix(prefix).map { HostsDiffLine(kind: .context, text: $0) })
        }
        result.append(contentsOf: old.dropFirst(prefix).dropLast(suffix).map {
            HostsDiffLine(kind: .removed, text: $0)
        })
        result.append(contentsOf: new.dropFirst(prefix).dropLast(suffix).map {
            HostsDiffLine(kind: .added, text: $0)
        })
        if suffix > 0 {
            result.append(contentsOf: old.suffix(suffix).map { HostsDiffLine(kind: .context, text: $0) })
        }
        return result
    }
}
