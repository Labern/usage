import SwiftUI
import Foundation
import AppKit
import Combine
import ServiceManagement
import UsageCore

// MARK: - Theme

extension Color {
    static let bgDeep = Color(red: 0.059, green: 0.047, blue: 0.161)   // #0f0c29
    static let bgMid  = Color(red: 0.188, green: 0.169, blue: 0.388)   // #302b63
    static let accentTeal   = Color(red: 0.369, green: 0.918, blue: 0.831) // #5eead4
    static let accentViolet = Color(red: 0.655, green: 0.545, blue: 0.980) // #a78bfa
    static let accentPink   = Color(red: 0.957, green: 0.447, blue: 0.714) // #f472b6
}

func menuBarSeparator(_ style: SeparatorStyle) -> String { "  \(style.glyph)  " }

func gaugeColor(for percent: Double) -> Color {
    switch percent {
    case ..<50: return .accentTeal
    case 50..<80: return Color(red: 0.98, green: 0.75, blue: 0.35)
    default: return Color(red: 0.96, green: 0.35, blue: 0.4)
    }
}

// MARK: - InsightTone color (view-layer extension; InsightTone itself is in UsageCore)

extension InsightTone {
    var color: Color {
        switch self {
        case .info:    return .accentViolet
        case .warning: return .accentPink
        case .good:    return .accentTeal
        }
    }
}

// MARK: - Real usage state, persisted to disk

struct SyncState: Codable {
    var sessionPercent: Double?
    var sessionResetsAt: Date?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    var lastFetchAt: Date?
    var lastFetchFailed: Bool = false
    var hasConnectedOnce: Bool = false
    /// Learned ratio: (API % delta) / (sum of turn weightedCosts since last delta).
    /// nil until the API has ticked at least once while the app was running.
    var calibrationFactor: Double?
    /// Running sum of turn weightedCosts since the last observed API tick.
    /// Persisted so a relaunch doesn't reset mid-window accumulation.
    var accumulatedWeightedCost: Double = 0

    static let empty = SyncState()
}

let stateFileURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeUsageMonitor")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("state.json")
}()

func loadSyncState() -> SyncState {
    guard let data = try? Data(contentsOf: stateFileURL),
          let decoded = try? JSONDecoder().decode(SyncState.self, from: data)
    else { return .empty }
    return decoded
}

func saveSyncState(_ state: SyncState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: stateFileURL)
}

// MARK: - JSONL tailing across ALL local Claude Code sessions on this Mac

/// Positions an auxiliary window (Settings, Insights, Turn History) just
/// below and to the right of the menu bar icon, instead of screen-centered —
/// centered windows tend to land underneath whatever you were just looking
/// at. Falls back to centering if the button isn't available for some reason.
/// Native controls (segmented pickers, checkboxes) render with light-mode
/// label colors by default — black text on our dark gradient backgrounds is
/// unreadable when deselected. Forcing dark appearance on the window fixes
/// it at the source instead of fighting each control's text color.
func applyDarkAppearance(_ window: NSWindow) {
    window.appearance = NSAppearance(named: .darkAqua)
}

/// Positions an auxiliary window flush against the left or right edge of the
/// main popover (or the menu bar button if the popover isn't available),
/// top-aligned with it — so Settings/Insights/Turn History visibly sit
/// beside the app instead of replacing or covering it.
func positionWindow(_ window: NSWindow, relativeTo anchorFrame: NSRect?, side: WindowSide) {
    guard let anchorFrame = anchorFrame else {
        window.center()
        return
    }
    // Always resolve some screen — falling through to .first if .main is
    // somehow unavailable — so clamping never silently gets skipped. The
    // menu bar sits at the top-right corner, so the popover (and therefore
    // anchorFrame) is often already hard against the right edge; without
    // this clamp, "open to the right" reliably runs off-screen there.
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) })
        ?? NSScreen.main
        ?? NSScreen.screens.first
    let width = window.frame.width
    let x = screen.map { targetWindowX(windowWidth: width, anchorFrame: anchorFrame, side: side, screenVisibleFrame: $0.visibleFrame) }
        ?? (side == .left ? anchorFrame.minX - width - 14 : anchorFrame.maxX + 14)
    window.setFrameTopLeftPoint(NSPoint(x: x, y: anchorFrame.maxY))

    // The popover stays open (semitransient) and renders at a popover-level
    // window layer above ordinary windows — without this, our window is
    // frontmost among normal windows but still visually buried beneath it.
    window.level = .floating
}

final class UsageMonitor: ObservableObject {
    @Published var lastTurn: TurnUsage?
    @Published var lastTurnPercentImpact: Double?
    @Published var recentTurns: [TurnUsage] = []
    @Published var turnCount: Int = 0
    @Published var syncState: SyncState = loadSyncState()
    @Published var settings: AppSettings = loadSettings()
    /// Returns the screen-space frame to position auxiliary windows against —
    /// the popover's own frame while it's open, falling back to the menu bar
    /// button. Set once by AppDelegate at launch.
    var anchorFrameProvider: (() -> NSRect?)?

    private var fileOffsets: [String: UInt64] = [:]
    private var seenMessageIDs = Set<String>()
    private var timer: Timer?
    private var fetchTimer: Timer?

    private let connectController = ConnectWindowController()
    let insightsAnalyzer = InsightsAnalyzer()
    private let insightsWindow = InsightsWindowController()
    private let settingsWindow = SettingsWindowController()
    let turnHistoryAnalyzer = TurnHistoryAnalyzer()
    private let turnHistoryWindow = TurnHistoryWindowController()
    let localServer = LocalUsageServer()

    @Published var statusMessage: String = ""
    @Published var isFetching: Bool = false

    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// The headline number — the real "five_hour" (session) utilization
    /// percent from claude.ai, not an estimate.
    var estimatedPercent: Double { syncState.sessionPercent ?? 0 }

    var isConnected: Bool { syncState.hasConnectedOnce }

    var phoneURL: String {
        let ip = getLocalIPAddress() ?? "127.0.0.1"
        return "http://\(ip):\(localServer.port)"
    }

    /// Menu bar text, respecting which segments are enabled in Settings.
    /// The pie icon (if enabled) is composed alongside this in MenuBarLabelView.
    var menuBarText: String {
        var segments: [String] = []
        if settings.showPercent {
            segments.append(String(format: "%.0f%%", estimatedPercent))
        }
        if settings.showLastTurn, let impact = lastTurnPercentImpact {
            segments.append(String(format: "+%.2f%% last turn", impact))
        }
        if settings.showNextSession, let resets = syncState.sessionResetsAt {
            segments.append("New session at \(resets.formatted(date: .omitted, time: .shortened))")
        }
        if segments.isEmpty && !settings.showPieIcon {
            segments.append(String(format: "%.0f%%", estimatedPercent))
        }
        return segments.joined(separator: menuBarSeparator(settings.separatorStyle))
    }

    func persistSettings() { saveSettings(settings) }

    func statusSnapshot() -> [String: Any] {
        var dict: [String: Any] = [
            "percent": estimatedPercent,
            "turnCount": turnCount,
        ]
        if let weekly = syncState.weeklyPercent { dict["weeklyPercent"] = weekly }
        if let turn = lastTurn {
            dict["lastTurnModel"] = turn.model.replacingOccurrences(of: "claude-", with: "")
        }
        if let impact = lastTurnPercentImpact {
            dict["lastTurnImpact"] = impact
        }
        if let last = syncState.lastFetchAt {
            dict["lastScrapeRelative"] = relativeTime(last)
        }
        if let top = insightsAnalyzer.insights.first {
            dict["topInsight"] = top.title
        }
        return dict
    }

    /// Minimum gap between real API calls — this is a single lightweight
    /// JSON request (not a full page render like the old DOM scraper), so
    /// we can afford to call it after every turn with only a short cooldown.
    private let fetchCooldown: TimeInterval = 5
    private var lastFetchTriggerAt: Date = .distantPast

    private var hasStarted = false

    /// Idempotent — safe to call from both the app delegate (guaranteed at
    /// launch) and any leftover view-lifecycle hook without double-starting
    /// timers or the listener.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        scanAndPoll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scanAndPoll()
        }
        // Safety-net background re-check even if no turns happen for a while.
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        if isConnected { refreshNow() }

        localServer.statusProvider = { [weak self] in self?.statusSnapshot() ?? [:] }
        localServer.start()
        insightsAnalyzer.refresh(weeklyPercent: syncState.weeklyPercent, sessionPercent: syncState.sessionPercent, sessionResetsAt: syncState.sessionResetsAt)
    }

    /// Called right after a turn is recorded — fetches real, fresh data
    /// instead of waiting on the fixed timer, throttled by `fetchCooldown`.
    private func fetchAfterTurn() {
        guard isConnected else { return }
        guard Date().timeIntervalSince(lastFetchTriggerAt) >= fetchCooldown else { return }
        lastFetchTriggerAt = Date()
        refreshNow()
    }

    // MARK: Connect flow

    func openConnectWindow() {
        connectController.onDone = { [weak self] in
            self?.statusMessage = "Saving your session…"
            UsageAPI.captureAndPersistCookies { success in
                DispatchQueue.main.async {
                    guard success else {
                        self?.statusMessage = "Didn't see a logged-in session — make sure the page showed you logged in before clicking Done, then try again."
                        return
                    }
                    self?.statusMessage = "Checking for a valid session…"
                    self?.refreshNow()
                }
            }
        }
        connectController.show()
    }

    func openInsights() {
        insightsWindow.show(
            analyzer: insightsAnalyzer, weeklyPercent: syncState.weeklyPercent,
            sessionPercent: syncState.sessionPercent, sessionResetsAt: syncState.sessionResetsAt,
            anchorFrame: anchorFrameProvider?(), side: .left
        )
    }

    func openSettings() {
        settingsWindow.show(monitor: self, anchorFrame: anchorFrameProvider?(), side: .left)
    }

    func openTurnHistory() {
        turnHistoryWindow.show(analyzer: turnHistoryAnalyzer, anchorFrame: anchorFrameProvider?(), side: .left)
    }

    /// Force an immediate real fetch from the actual claude.ai usage API —
    /// no DOM, no selectors, just the same JSON the web app itself reads.
    func refreshNow() {
        isFetching = true
        UsageAPI.fetchRawUsageJSON { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetching = false
                switch result {
                case .failure(let error):
                    self.syncState.lastFetchFailed = true
                    saveSyncState(self.syncState)
                    self.statusMessage = "Auto-sync failed: \(error.localizedDescription)"
                case .success(let json):
                    self.applyUsageJSON(json)
                }
            }
        }
    }

    private func applyUsageJSON(_ json: [String: Any]) {
        var newSessionPercent: Double?
        var newSessionResets: Date?
        var newWeeklyPercent: Double?
        var newWeeklyResets: Date?

        if let fiveHour = json["five_hour"] as? [String: Any] {
            newSessionPercent = (fiveHour["utilization"] as? NSNumber)?.doubleValue
            if let s = fiveHour["resets_at"] as? String { newSessionResets = UsageAPI.parseDate(s) }
        }
        if let sevenDay = json["seven_day"] as? [String: Any] {
            newWeeklyPercent = (sevenDay["utilization"] as? NSNumber)?.doubleValue
            if let s = sevenDay["resets_at"] as? String { newWeeklyResets = UsageAPI.parseDate(s) }
        }

        guard let sessionPercent = newSessionPercent else {
            syncState.lastFetchFailed = true
            saveSyncState(syncState)
            statusMessage = "Connected, but couldn't find usage numbers in the response — Anthropic may have changed the API shape."
            return
        }

        // Three cases for what the API response tells us:
        let delta = turnPercentImpact(
            previousPercent: syncState.sessionPercent,
            previousResetsAt: syncState.sessionResetsAt,
            newPercent: sessionPercent,
            newResetsAt: newSessionResets
        )
        if let d = delta, d > 0 {
            // API percent genuinely ticked up. Update the calibration factor from
            // observed (API delta / accumulated local cost) and record actual delta.
            if syncState.accumulatedWeightedCost > 0 {
                syncState.calibrationFactor = d / syncState.accumulatedWeightedCost
            }
            syncState.accumulatedWeightedCost = 0
            lastTurnPercentImpact = d
        } else if delta == nil {
            // Session window changed or no previous data. Reset accumulator so
            // calibration restarts from zero for the new window.
            syncState.accumulatedWeightedCost = 0
            lastTurnPercentImpact = nil
        }
        // delta == 0.0: same integer percent as before — API hasn't ticked yet.
        // Leave lastTurnPercentImpact at the calibrated estimate set in processLine.

        syncState.sessionPercent = sessionPercent
        syncState.sessionResetsAt = newSessionResets
        syncState.weeklyPercent = newWeeklyPercent
        syncState.weeklyResetsAt = newWeeklyResets
        syncState.lastFetchAt = Date()
        syncState.lastFetchFailed = false
        syncState.hasConnectedOnce = true
        saveSyncState(syncState)
        statusMessage = "Auto-synced from your account."
    }

    private func allTranscriptFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func scanAndPoll() {
        for url in allTranscriptFiles() { tail(url) }
    }

    private func tail(_ url: URL) {
        let path = url.path
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fileHandle.close() }

        let currentOffset = fileOffsets[path] ?? 0
        guard let size = try? fileHandle.seekToEnd(), size > currentOffset else {
            fileOffsets[path] = (try? fileHandle.seekToEnd()) ?? currentOffset
            return
        }
        try? fileHandle.seek(toOffset: currentOffset)
        let newData = fileHandle.readDataToEndOfFile()
        fileOffsets[path] = size

        guard let text = String(data: newData, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            processLine(String(line), sessionPath: path)
        }
    }

    private func processLine(_ line: String, sessionPath: String) {
        guard let turn = parseTurnUsage(fromLine: line, sessionPath: sessionPath) else { return }

        guard !seenMessageIDs.contains(turn.id) else { return }
        seenMessageIDs.insert(turn.id)

        DispatchQueue.main.async {
            self.lastTurn = turn
            self.turnCount += 1
            self.recentTurns.insert(turn, at: 0)
            if self.recentTurns.count > 10 { self.recentTurns.removeLast() }
            self.syncState.accumulatedWeightedCost += turn.weightedCost
            // Show a calibrated per-turn estimate immediately, before the API call
            // returns. If we have a factor from a prior observed API tick, multiply
            // this turn's local cost by it. The API call may later overwrite this
            // with the real delta if the integer percent actually ticked up.
            if let factor = self.syncState.calibrationFactor, factor > 0, turn.weightedCost > 0 {
                self.lastTurnPercentImpact = turn.weightedCost * factor
            }
            self.fetchAfterTurn()
        }
    }
}

// MARK: - Gauge

struct GaugeView: View {
    let percent: Double
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 14)
            Circle()
                .trim(from: 0, to: percent / 100)
                .stroke(
                    AngularGradient(
                        colors: [.accentTeal, .accentViolet, .accentPink],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: percent)
            VStack(spacing: 2) {
                Text(String(format: "%.0f", percent) + "%")
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("USED")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 136, height: 136)
        .shadow(color: gaugeColor(for: percent).opacity(0.5), radius: 16)
    }
}

// MARK: - Connect / status panel

func relativeTime(_ date: Date) -> String {
    let seconds = -date.timeIntervalSinceNow
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    return "\(Int(seconds / 3600))h ago"
}

func durationUntil(_ date: Date) -> String {
    let secs = date.timeIntervalSinceNow
    guard secs > 0 else { return "now" }
    let mins = Int(secs / 60)
    if mins < 60 { return "\(mins) min" }
    let hrs = mins / 60
    let rem = mins % 60
    if rem == 0 { return "\(hrs)h" }
    return "\(hrs)h \(rem)m"
}

struct ConnectPanel: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.isConnected {
                HStack(spacing: 8) {
                    Circle()
                        .fill(monitor.syncState.lastFetchFailed ? Color.accentPink : Color.accentTeal)
                        .frame(width: 8, height: 8)
                    if let last = monitor.syncState.lastFetchAt {
                        Text("Auto-synced \(relativeTime(last))")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        Text("Connected — waiting for first sync")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Button(monitor.isFetching ? "Syncing…" : "Refresh") { monitor.refreshNow() }
                        .font(.system(size: 13, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentTeal)
                        .disabled(monitor.isFetching)
                }
                if monitor.syncState.lastFetchFailed {
                    Button("Reconnect") { monitor.openConnectWindow() }
                        .font(.system(size: 13))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentPink)
                }
            } else {
                Text("No automatic source yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Connect Claude account") { monitor.openConnectWindow() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentViolet)
                    .controlSize(.large)
                if !monitor.statusMessage.isEmpty {
                    Text(monitor.statusMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
}

// MARK: - Phone dashboard panel

/// Opens a URL specifically in Chrome (not whatever the system default is) —
/// falls back to the default browser if Chrome isn't installed.
func openInChrome(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
        NSWorkspace.shared.open(url)
        return
    }
    NSWorkspace.shared.open([url], withApplicationAt: chromeURL, configuration: NSWorkspace.OpenConfiguration())
}

struct PhoneDashboardPanel: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📱 OPEN ON PHONE")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 4)
            HStack(spacing: 14) {
                if let qr = generateQRCode(from: monitor.phoneURL) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 76, height: 76)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        openInChrome(monitor.phoneURL)
                    } label: {
                        Text(monitor.phoneURL)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Open in Chrome")
                    Text("scan with your phone camera —")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("same Wi-Fi network required")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
}

// MARK: - Inline turn row (used in main popover)

private struct RecentTurnRow: View {
    let turn: TurnUsage
    let calibrationFactor: Double?
    let isLatest: Bool
    let latestImpact: Double?

    private var impactText: String? {
        // Use the live lastTurnPercentImpact for the newest entry — it may
        // reflect the real API delta rather than a calibrated estimate.
        let value: Double?
        if isLatest, let live = latestImpact {
            value = live
        } else if let factor = calibrationFactor, factor > 0, turn.weightedCost > 0 {
            value = turn.weightedCost * factor
        } else {
            value = nil
        }
        guard let v = value else { return nil }
        return v < 0.005 ? "<0.01%" : String(format: "+%.2f%%", v)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(relativeTime(turn.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 52, alignment: .leading)
            Text(turn.model.replacingOccurrences(of: "claude-", with: ""))
                .font(.system(size: 13, weight: isLatest ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isLatest ? 0.9 : 0.55))
                .lineLimit(1)
            Spacer()
            if let text = impactText {
                Text(text)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isLatest ? Color.accentTeal : Color.accentTeal.opacity(0.6))
            } else {
                Text("—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
    }
}

// MARK: - Main popover content

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [.bgDeep, .bgMid, .bgDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Usage")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        monitor.openInsights()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentViolet)
                    }
                    .buttonStyle(.plain)
                    .help("Insights & recommendations")
                    Button {
                        monitor.openTurnHistory()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentTeal)
                    }
                    .buttonStyle(.plain)
                    .help("Turn history")
                    Button {
                        monitor.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    Circle()
                        .fill(Color.accentTeal)
                        .frame(width: 9, height: 9)
                        .opacity(pulse ? 1 : 0.3)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                }

                HStack(spacing: 20) {
                    GaugeView(percent: monitor.estimatedPercent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Session usage")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text("real number from your Claude account")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                        if let weekly = monitor.syncState.weeklyPercent {
                            Text(String(format: "Weekly: %.0f%%", weekly))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if let resets = monitor.syncState.sessionResetsAt {
                            Text("New session at \(resets.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.accentTeal)
                        }
                    }
                }

                if !monitor.recentTurns.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("RECENT TURNS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                        ForEach(Array(monitor.recentTurns.prefix(5))) { turn in
                            RecentTurnRow(
                                turn: turn,
                                calibrationFactor: monitor.syncState.calibrationFactor,
                                isLatest: turn.id == monitor.recentTurns.first?.id,
                                latestImpact: monitor.lastTurnPercentImpact
                            )
                        }
                    }
                }

                if let predicted = sessionRunOutEstimate(
                    percent: monitor.syncState.sessionPercent,
                    resetsAt: monitor.syncState.sessionResetsAt
                ) {
                    Divider().background(Color.white.opacity(0.1))
                    HStack(spacing: 7) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Predicted usage burn at \(predicted.formatted(date: .omitted, time: .shortened)), in \(durationUntil(predicted))")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                    }
                }

                Divider().background(Color.white.opacity(0.1))
                ConnectPanel(monitor: monitor)

                Divider().background(Color.white.opacity(0.1))
                PhoneDashboardPanel(monitor: monitor)

                Divider().background(Color.white.opacity(0.1))
                HStack {
                    Text("\(monitor.turnCount) turns tracked locally")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .font(.system(size: 13))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(20)
        }
        .frame(width: 400)
    }
}

/// Single shared instance for the app's whole lifetime.
let sharedMonitor = UsageMonitor()

/// Manages the actual NSStatusItem directly instead of going through
/// SwiftUI's `MenuBarExtra`. `MenuBarExtra`'s label is known to be unreliable
/// about re-rendering on `@Published` changes — toggling a Settings checkbox
/// would update the data but not the visible menu bar text/icon until the
/// app restarted. Setting `button.image`/`button.title` imperatively, driven
/// by a direct Combine subscription, updates instantly and unconditionally.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var changeSubscription: AnyCancellable?
    private var turnCountSubscription: AnyCancellable?
    private var pulseTimer: Timer?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedMonitor.start()

        // Launch automatically at login from now on. Idempotent — registering
        // when already registered is a harmless no-op.
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(toggle)
        }
        statusItem = item

        let hosting = NSHostingController(rootView: MenuContentView(monitor: sharedMonitor))
        hosting.sizingOptions = [.preferredContentSize]
        let pop = NSPopover()
        // .transient closes the popover the instant any other window becomes
        // key — including our own Settings/Insights/Turn History windows.
        // .semitransient only closes on app deactivation or a click truly
        // outside the app, so opening an auxiliary window leaves it open.
        pop.behavior = .semitransient
        pop.contentSize = NSSize(width: 400, height: 700)
        pop.contentViewController = hosting
        pop.appearance = NSAppearance(named: .darkAqua)
        popover = pop

        // .semitransient alone leaves the popover open when clicking other
        // apps/desktop in some configurations, requiring Esc. A global click
        // monitor only fires for clicks outside our own app's windows — so
        // it closes the popover on any outside click while leaving our own
        // Settings/Insights/Turn History windows free to keep it open.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.popover.close()
        }

        sharedMonitor.anchorFrameProvider = { [weak self] in
            guard let self = self else { return nil }
            if self.popover.isShown, let popoverWindow = self.popover.contentViewController?.view.window {
                return popoverWindow.frame
            }
            if let button = self.statusItem.button, let buttonWindow = button.window {
                return buttonWindow.convertToScreen(button.frame)
            }
            return nil
        }

        refresh()

        // objectWillChange fires before the new value is actually stored, so
        // defer the read by one runloop tick to pick up the settled value.
        changeSubscription = sharedMonitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }

        // Pulse the menu bar button whenever a new turn is detected.
        turnCountSubscription = sharedMonitor.$turnCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pulseMenuBar() }
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let showIcon = sharedMonitor.settings.showPieIcon
        button.image = showIcon ? renderPieIconImage(percent: sharedMonitor.estimatedPercent, trailingGap: 1) : nil
        button.title = showIcon
            ? menuBarSeparator(sharedMonitor.settings.separatorStyle) + sharedMonitor.menuBarText
            : sharedMonitor.menuBarText
    }

    private func pulseMenuBar() {
        pulseTimer?.invalidate()
        var elapsed = 0.0
        let interval = 1.0 / 24.0
        let duration = 0.55
        let percent = sharedMonitor.estimatedPercent

        pulseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self, let button = self.statusItem?.button else {
                timer.invalidate(); return
            }
            elapsed += interval
            if elapsed >= duration {
                timer.invalidate(); self.pulseTimer = nil; self.refresh(); return
            }
            // Ease-out: fast spin at start, slows as it completes one revolution
            let t = elapsed / duration
            let eased = 1 - pow(1 - t, 2)
            let rotation = CGFloat(eased * 360)
            button.image = renderPieIconImage(percent: percent, trailingGap: 1, rotationOffset: rotation)
        }
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct ClaudeUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All real UI is driven by AppDelegate's NSStatusItem/NSPopover —
        // SwiftUI still requires at least one Scene to exist.
        Settings { EmptyView() }
    }
}
