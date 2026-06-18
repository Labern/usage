import SwiftUI
import AppKit
import Foundation

// MARK: - Per-turn timeline (not per-session like Insights)

struct TurnHistoryEntry: Identifiable {
    let id: String
    let timestamp: Date
    let projectLabel: String
    let model: String
    let weightedCost: Double
    let freshTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
}

final class TurnHistoryAnalyzer: ObservableObject {
    @Published var entries: [TurnHistoryEntry] = []
    @Published var isLoading = false
    @Published var windowHours: Double = 1

    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    func refresh() {
        isLoading = true
        let hours = windowHours
        DispatchQueue.global(qos: .userInitiated).async {
            let cutoff = Date().addingTimeInterval(-hours * 3600)
            let result = self.scan(cutoff: cutoff)
            DispatchQueue.main.async {
                self.entries = result
                self.isLoading = false
            }
        }
    }

    private func scan(cutoff: Date) -> [TurnHistoryEntry] {
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var results: [TurnHistoryEntry] = []

        for projectDir in projectDirs {
            guard projectDir.hasDirectoryPath else { continue }
            let label = humanizeProjectLabel(fromDirectoryName: projectDir.lastPathComponent)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                // Quick skip: if the file hasn't been touched since the cutoff,
                // none of its turns can be in range — avoids parsing old sessions.
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let modDate = attrs[.modificationDate] as? Date, modDate < cutoff {
                    continue
                }
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var seenIDs = Set<String>()
                for line in content.split(separator: "\n") {
                    guard let turn = parseTurnUsage(fromLine: String(line), sessionPath: file.path) else { continue }
                    guard turn.timestamp >= cutoff else { continue }
                    guard !seenIDs.contains(turn.id) else { continue }
                    seenIDs.insert(turn.id)
                    results.append(TurnHistoryEntry(
                        id: turn.id, timestamp: turn.timestamp, projectLabel: label, model: turn.model,
                        weightedCost: turn.weightedCost, freshTokens: turn.freshTokens,
                        cacheReadTokens: turn.cacheRead, outputTokens: turn.outputTokens
                    ))
                }
            }
        }

        return results.sorted { $0.timestamp > $1.timestamp }
    }
}

// MARK: - View

struct TurnHistoryView: View {
    @ObservedObject var analyzer: TurnHistoryAnalyzer

    private var totalWeight: Double { analyzer.entries.map(\.weightedCost).reduce(0, +) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    var body: some View {
        ZStack {
            LinearGradient(colors: [.bgDeep, .bgMid, .bgDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Turn History").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    Button(analyzer.isLoading ? "Scanning…" : "Rescan") { analyzer.refresh() }
                        .tint(.accentViolet)
                }

                Picker("", selection: $analyzer.windowHours) {
                    Text("Last hour").tag(1.0)
                    Text("3 hours").tag(3.0)
                    Text("6 hours").tag(6.0)
                    Text("24 hours").tag(24.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: analyzer.windowHours) { _ in analyzer.refresh() }

                Text("Per-turn timestamps and token weighting come straight from your local session transcripts. The % share below is a local estimate of relative activity in this window — not a per-turn read of your real account percentage, which Anthropic only exposes as a point-in-time snapshot.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                if analyzer.entries.isEmpty {
                    Text(analyzer.isLoading ? "Scanning…" : "No turns in this window.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    Text("\(analyzer.entries.count) turns in this window")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(analyzer.entries) { entry in
                            TurnHistoryRow(entry: entry, share: totalWeight > 0 ? entry.weightedCost / totalWeight : 0, timeFormatter: Self.timeFormatter)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 620)
        .onAppear { analyzer.refresh() }
    }
}

struct TurnHistoryRow: View {
    let entry: TurnHistoryEntry
    let share: Double
    let timeFormatter: DateFormatter

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentTeal.opacity(0.12))
                    .frame(width: geo.size.width * CGFloat(min(max(share, 0), 1)))
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeFormatter.string(from: entry.timestamp))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(entry.projectLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text(entry.model.replacingOccurrences(of: "claude-", with: ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // A busy hour can have dozens of turns, so any single
                    // turn's share is often well under 1% — one decimal place
                    // keeps that visible instead of every row rounding to "0%".
                    Text(String(format: "%.1f%%", share * 100))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentTeal)
                    Text("of window")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

final class TurnHistoryWindowController {
    private var window: NSWindow?

    func show(analyzer: TurnHistoryAnalyzer, anchorFrame: NSRect?, side: WindowSide) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: TurnHistoryView(analyzer: analyzer))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Turn History"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        applyDarkAppearance(window)
        window.makeKeyAndOrderFront(nil)
        positionWindow(window, relativeTo: anchorFrame, side: side)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
