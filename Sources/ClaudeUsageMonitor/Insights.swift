import SwiftUI
import Foundation
import AppKit
import UsageCore

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
            let generated = generateInsights(
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
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(insight.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(insight.tone.color.opacity(0.4), lineWidth: 1))
                    }

                    if !analyzer.sessions.isEmpty {
                        Divider().background(Color.white.opacity(0.1))
                        Text("RECENT SESSIONS").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                        ForEach(analyzer.sessions.prefix(12)) { s in
                            HStack {
                                Text(s.label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                                Spacer()
                                Text("\(s.turnCount) turns").font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                                Text(s.lastTimestamp.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.3))
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
        let view = InsightsView(analyzer: analyzer, weeklyPercent: weeklyPercent, sessionPercent: sessionPercent, sessionResetsAt: sessionResetsAt)
        if let window = window {
            // Reopening: swap in a view built from the CURRENT percentages and
            // rescan — onAppear won't re-fire for a window that's only been
            // ordered out and back in, so without this the reopened window
            // shows the numbers from whenever it was first created.
            (window.contentViewController as? NSHostingController<InsightsView>)?.rootView = view
            analyzer.refresh(weeklyPercent: weeklyPercent, sessionPercent: sessionPercent, sessionResetsAt: sessionResetsAt)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: view)
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
