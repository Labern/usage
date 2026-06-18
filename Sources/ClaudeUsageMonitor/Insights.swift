import SwiftUI
import Foundation
import AppKit

// MARK: - Per-conversation rollup

struct SessionSummary: Identifiable {
    let id: String          // file path
    let label: String       // human-readable project/session label
    let turnCount: Int
    let totalWeightedCost: Double
    let freshTokens: Int
    let cacheReadTokens: Int
    let firstTimestamp: Date
    let lastTimestamp: Date

    var cacheReadRatio: Double {
        let total = freshTokens + cacheReadTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(total)
    }
}

/// Turns a Claude Code project-directory name like
/// "-Users-labern-Desktop-Clean" back into something readable.
func humanizeProjectLabel(fromDirectoryName name: String) -> String {
    var path = name
    if path.hasPrefix("-") { path.removeFirst() }
    let parts = path.split(separator: "-")
    let joined = "/" + parts.joined(separator: "/")
    // Heuristic: collapse the home directory prefix if present.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if joined.hasPrefix(home) {
        return "~" + joined.dropFirst(home.count)
    }
    return joined
}

enum InsightTone {
    case info, warning, good
    var color: Color {
        switch self {
        case .info: return .accentViolet
        case .warning: return .accentPink
        case .good: return .accentTeal
        }
    }
}

struct Insight: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let tone: InsightTone
}

// MARK: - Analyzer

final class InsightsAnalyzer: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var insights: [Insight] = []
    @Published var isLoading = false

    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    func refresh(weeklyPercent: Double?, sessionPercent: Double? = nil, sessionResetsAt: Date? = nil) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let summaries = self.scanAllSessions()
            let generated = Self.generateInsights(
                sessions: summaries, weeklyPercent: weeklyPercent,
                sessionPercent: sessionPercent, sessionResetsAt: sessionResetsAt
            )
            DispatchQueue.main.async {
                self.sessions = summaries
                self.insights = generated
                self.isLoading = false
            }
        }
    }

    private func scanAllSessions() -> [SessionSummary] {
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var summaries: [SessionSummary] = []

        for projectDir in projectDirs {
            guard projectDir.hasDirectoryPath else { continue }
            let label = humanizeProjectLabel(fromDirectoryName: projectDir.lastPathComponent)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var turnCount = 0
                var totalCost = 0.0
                var freshTokens = 0
                var cacheReadTokens = 0
                var first = Date.distantFuture
                var last = Date.distantPast
                var seenIDs = Set<String>()

                for line in content.split(separator: "\n") {
                    guard let turn = parseTurnUsage(fromLine: String(line), sessionPath: file.path) else { continue }
                    guard !seenIDs.contains(turn.id) else { continue }
                    seenIDs.insert(turn.id)
                    turnCount += 1
                    totalCost += turn.weightedCost
                    freshTokens += turn.freshTokens
                    cacheReadTokens += turn.cacheRead
                    if turn.timestamp < first { first = turn.timestamp }
                    if turn.timestamp > last { last = turn.timestamp }
                }

                guard turnCount > 0 else { continue }
                summaries.append(SessionSummary(
                    id: file.path, label: label, turnCount: turnCount,
                    totalWeightedCost: totalCost, freshTokens: freshTokens,
                    cacheReadTokens: cacheReadTokens, firstTimestamp: first, lastTimestamp: last
                ))
            }
        }

        return summaries.sorted { $0.lastTimestamp > $1.lastTimestamp }
    }

    // MARK: Rule-based recommendations

    /// Linear projection from current session usage: extrapolates the rate
    /// of % consumed per second since the 5-hour session window started,
    /// then estimates when that rate would hit 100%. An honest "if you keep
    /// going like this" estimate, not a guarantee — and `nil` once you're
    /// already on track to make it to the reset without running out.
    static func sessionRunOutEstimate(percent: Double?, resetsAt: Date?) -> Date? {
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
        // If the projection lands after the session would reset anyway,
        // there's nothing to warn about — current pace comfortably lasts.
        guard projected < resetsAt else { return nil }
        return projected
    }

    static func generateInsights(
        sessions: [SessionSummary], weeklyPercent: Double?,
        sessionPercent: Double? = nil, sessionResetsAt: Date? = nil
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

        // 4. Real weekly usage (from the account, not estimated)
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
}

// MARK: - Insights view

struct InsightsView: View {
    @ObservedObject var analyzer: InsightsAnalyzer
    let weeklyPercent: Double?
    var sessionPercent: Double? = nil
    var sessionResetsAt: Date? = nil

    private func refresh() {
        analyzer.refresh(weeklyPercent: weeklyPercent, sessionPercent: sessionPercent, sessionResetsAt: sessionResetsAt)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.bgDeep, .bgMid, .bgDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Insights").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        Button(analyzer.isLoading ? "Scanning…" : "Rescan") {
                            refresh()
                        }
                        .disabled(analyzer.isLoading)
                        .tint(.accentViolet)
                    }

                    if analyzer.insights.isEmpty && !analyzer.isLoading {
                        Text("No session data found yet.").foregroundStyle(.white.opacity(0.5))
                    }

                    ForEach(analyzer.insights) { insight in
                        HStack(alignment: .top, spacing: 12) {
                            Text(insight.icon).font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(insight.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(insight.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(insight.tone.color.opacity(0.4), lineWidth: 1))
                    }

                    if !analyzer.sessions.isEmpty {
                        Divider().background(Color.white.opacity(0.1))
                        Text("RECENT SESSIONS").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                        ForEach(analyzer.sessions.prefix(12)) { s in
                            HStack {
                                Text(s.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                                Spacer()
                                Text("\(s.turnCount) turns").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                                Text(s.lastTimestamp.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 560)
        .onAppear { refresh() }
    }
}

final class InsightsWindowController {
    private var window: NSWindow?

    func show(analyzer: InsightsAnalyzer, weeklyPercent: Double?, sessionPercent: Double?, sessionResetsAt: Date?, anchorFrame: NSRect?, side: WindowSide) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: InsightsView(analyzer: analyzer, weeklyPercent: weeklyPercent, sessionPercent: sessionPercent, sessionResetsAt: sessionResetsAt))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Claude Usage Insights"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        applyDarkAppearance(window)
        window.setContentSize(hosting.view.fittingSize)
        window.makeKeyAndOrderFront(nil)
        positionWindow(window, relativeTo: anchorFrame, side: side)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
