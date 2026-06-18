import Foundation

// MARK: - Per-session data

public struct SessionSummary: Identifiable {
    public let id: String
    public let label: String
    public let turnCount: Int
    public let totalWeightedCost: Double
    public let freshTokens: Int
    public let cacheReadTokens: Int
    public let firstTimestamp: Date
    public let lastTimestamp: Date

    public init(id: String, label: String, turnCount: Int, totalWeightedCost: Double,
                freshTokens: Int, cacheReadTokens: Int, firstTimestamp: Date, lastTimestamp: Date) {
        self.id = id; self.label = label; self.turnCount = turnCount
        self.totalWeightedCost = totalWeightedCost; self.freshTokens = freshTokens
        self.cacheReadTokens = cacheReadTokens
        self.firstTimestamp = firstTimestamp; self.lastTimestamp = lastTimestamp
    }

    public var cacheReadRatio: Double {
        let total = freshTokens + cacheReadTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(total)
    }
}

public enum InsightTone {
    case info, warning, good
}

public struct Insight: Identifiable {
    public let id = UUID()
    public let icon: String
    public let title: String
    public let detail: String
    public let tone: InsightTone

    public init(icon: String, title: String, detail: String, tone: InsightTone) {
        self.icon = icon; self.title = title; self.detail = detail; self.tone = tone
    }
}

// MARK: - Label helpers

/// Turns a Claude Code project-directory name like
/// "-Users-labern-Desktop-Clean" back into something readable.
public func humanizeProjectLabel(fromDirectoryName name: String) -> String {
    var path = name
    if path.hasPrefix("-") { path.removeFirst() }
    let parts = path.split(separator: "-")
    let joined = "/" + parts.joined(separator: "/")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if joined.hasPrefix(home) {
        return "~" + joined.dropFirst(home.count)
    }
    return joined
}

// MARK: - Pure insight generation (no ObservableObject, no I/O)

/// Linear projection from current session usage: extrapolates the rate
/// of % consumed per second since the 5-hour session window started,
/// then estimates when that rate would hit 100%. Returns nil once you're
/// on track to make it to the reset without running out.
public func sessionRunOutEstimate(percent: Double?, resetsAt: Date?) -> Date? {
    guard let percent = percent, percent > 0, let resetsAt = resetsAt else { return nil }
    let sessionLength: TimeInterval = 5 * 3600
    let sessionStart = resetsAt.addingTimeInterval(-sessionLength)
    let elapsed = Date().timeIntervalSince(sessionStart)
    guard elapsed > 1 else { return nil }
    let remaining = 100 - percent
    guard remaining > 0 else { return Date() }
    let ratePerSecond = percent / elapsed
    guard ratePerSecond > 0 else { return nil }
    let projected = Date().addingTimeInterval(remaining / ratePerSecond)
    guard projected < resetsAt else { return nil }
    return projected
}

public func generateInsights(
    sessions: [SessionSummary],
    weeklyPercent: Double?,
    sessionPercent: Double? = nil,
    sessionResetsAt: Date? = nil
) -> [Insight] {
    var result: [Insight] = []

    if let runOut = sessionRunOutEstimate(percent: sessionPercent, resetsAt: sessionResetsAt) {
        result.append(Insight(
            icon: "⏳",
            title: "Predicted end of session",
            detail: "Based on current usage, you will run out at \(runOut.formatted(date: .omitted, time: .shortened)).",
            tone: .warning
        ))
    }

    guard !sessions.isEmpty else { return result }

    let recent = Array(sessions.prefix(10))
    let avgTurns = Double(recent.map(\.turnCount).reduce(0, +)) / Double(recent.count)

    // 1. Busiest conversation
    if let busiest = recent.max(by: { $0.turnCount < $1.turnCount }),
       Double(busiest.turnCount) > avgTurns * 1.6, busiest.turnCount > 8 {
        result.append(Insight(
            icon: "💬",
            title: "\(busiest.label) is running long",
            detail: "\(busiest.turnCount) turns vs an average of \(Int(avgTurns)) across your last \(recent.count) sessions. Long-running conversations accumulate context that gets re-sent every turn — consider starting a fresh session for the next unrelated task.",
            tone: .warning
        ))
    }

    // 2. Cost concentration
    let totalRecentCost = recent.map(\.totalWeightedCost).reduce(0, +)
    if let costliest = recent.max(by: { $0.totalWeightedCost < $1.totalWeightedCost }),
       totalRecentCost > 0 {
        let share = costliest.totalWeightedCost / totalRecentCost
        if share > 0.35 {
            result.append(Insight(
                icon: "📊",
                title: "\(costliest.label) dominates recent usage",
                detail: "It accounts for ~\(Int(share * 100))% of your tracked activity across the last \(recent.count) sessions.",
                tone: .info
            ))
        }
    }

    // 3. Cache inefficiency
    let cacheCandidates = recent.filter { $0.turnCount >= 5 }
    if let worst = cacheCandidates.min(by: { $0.cacheReadRatio < $1.cacheReadRatio }),
       worst.cacheReadRatio < 0.25 {
        result.append(Insight(
            icon: "♻️",
            title: "Low cache reuse in \(worst.label)",
            detail: "Only ~\(Int(worst.cacheReadRatio * 100))% of its tokens were served from cache. Big gaps between turns, or editing very early context, can force expensive cache rewrites — keep related work close together in time when you can.",
            tone: .warning
        ))
    }

    // 4. Real weekly usage
    if let weekly = weeklyPercent, weekly > 1 {
        result.append(Insight(
            icon: "📈",
            title: "Weekly usage: \(String(format: "%.0f", weekly))%",
            detail: "Real number from your account's 7-day window — not estimated from local activity.",
            tone: weekly > 75 ? .warning : .info
        ))
    }

    // 5. Trend: cost-per-turn rising
    if sessions.count >= 6 {
        let recentHalf = Array(sessions.prefix(3))
        let priorHalf = Array(sessions.dropFirst(3).prefix(3))
        let recentAvg = recentHalf.map { $0.totalWeightedCost / Double(max($0.turnCount, 1)) }.reduce(0, +) / Double(recentHalf.count)
        let priorAvg = priorHalf.map { $0.totalWeightedCost / Double(max($0.turnCount, 1)) }.reduce(0, +) / Double(priorHalf.count)
        if priorAvg > 0, recentAvg > priorAvg * 1.3 {
            let pctUp = Int(((recentAvg / priorAvg) - 1) * 100)
            result.append(Insight(
                icon: "⚠️",
                title: "Turns are getting more expensive",
                detail: "Average cost per turn is up ~\(pctUp)% over your last 3 sessions vs the 3 before that — often a sign of context bloat. Consider trimming unused files from context or starting fresh.",
                tone: .warning
            ))
        }
    }

    if result.isEmpty {
        result.append(Insight(
            icon: "✅",
            title: "Nothing unusual",
            detail: "Your recent sessions look evenly balanced — no single conversation or pattern is driving disproportionate usage.",
            tone: .good
        ))
    }

    return result
}
