import SwiftUI
import Foundation
import AppKit
import Combine
import ServiceManagement

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

// MARK: - Internal cost weighting (used only to compute % drift between syncs)

struct ModelPricing { let input: Double; let output: Double }

let pricingTable: [String: ModelPricing] = [
    "claude-sonnet-4-6": ModelPricing(input: 3.00, output: 15.00),
    "claude-opus-4-8":   ModelPricing(input: 5.00, output: 25.00),
    "claude-haiku-4-5":  ModelPricing(input: 1.00, output: 5.00),
    "claude-fable-5":    ModelPricing(input: 10.00, output: 50.00),
]
let cacheWrite5mMultiplier = 1.25
let cacheWrite1hMultiplier = 2.0
let cacheReadMultiplier = 0.1

struct TurnUsage: Identifiable {
    let id: String
    let sessionPath: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int
    let cacheRead: Int
    let timestamp: Date

    var pricing: ModelPricing { pricingTable[model] ?? ModelPricing(input: 0, output: 0) }

    /// "Weighted cost" — an internal $-equivalent unit used only to interpolate
    /// plan-quota percentage between manual syncs. Not shown as the headline metric.
    var weightedCost: Double {
        let i = Double(inputTokens) * pricing.input
        let o = Double(outputTokens) * pricing.output
        let w5 = Double(cacheWrite5m) * pricing.input * cacheWrite5mMultiplier
        let w1 = Double(cacheWrite1h) * pricing.input * cacheWrite1hMultiplier
        let r = Double(cacheRead) * pricing.input * cacheReadMultiplier
        return (i + o + w5 + w1 + r) / 1_000_000
    }

    /// Tokens that weren't served from cache — a proxy for "fresh context cost".
    var freshTokens: Int { inputTokens + cacheWrite5m + cacheWrite1h }
}

/// Parses one JSONL transcript line into a TurnUsage, if it's an assistant
/// message carrying a `usage` block. Shared by live tailing and full-history
/// analysis (Insights) so both read usage data identically.
func parseTurnUsage(fromLine line: String, sessionPath: String = "") -> TurnUsage? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (obj["type"] as? String) == "assistant",
          let message = obj["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any],
          let id = message["id"] as? String,
          let model = message["model"] as? String
    else { return nil }

    let inputTokens = usage["input_tokens"] as? Int ?? 0
    let outputTokens = usage["output_tokens"] as? Int ?? 0
    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    if let creation = usage["cache_creation"] as? [String: Any] {
        cacheWrite5m = creation["ephemeral_5m_input_tokens"] as? Int ?? 0
        cacheWrite1h = creation["ephemeral_1h_input_tokens"] as? Int ?? 0
    } else {
        cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
    }

    // Best-effort timestamp from the transcript line itself; falls back to now.
    var timestamp = Date()
    if let tsString = obj["timestamp"] as? String, let parsed = ISO8601DateFormatter().date(from: tsString) {
        timestamp = parsed
    }

    return TurnUsage(
        id: id, sessionPath: sessionPath, model: model,
        inputTokens: inputTokens, outputTokens: outputTokens,
        cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h, cacheRead: cacheRead,
        timestamp: timestamp
    )
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

final class UsageMonitor: ObservableObject {
    @Published var lastTurn: TurnUsage?
    @Published var lastTurnPercentImpact: Double?
    @Published var cumulativeCost: Double = 0      // lifetime, all local sessions — feeds Insights only
    @Published var turnCount: Int = 0
    @Published var syncState: SyncState = loadSyncState()
    @Published var settings: AppSettings = loadSettings()

    private var fileOffsets: [String: UInt64] = [:]
    private var seenMessageIDs = Set<String>()
    private var timer: Timer?
    private var fetchTimer: Timer?

    private let connectController = ConnectWindowController()
    let insightsAnalyzer = InsightsAnalyzer()
    private let insightsWindow = InsightsWindowController()
    private let settingsWindow = SettingsWindowController()
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
            segments.append(String(format: "+%.1f%% last turn", impact))
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
        insightsAnalyzer.refresh(weeklyPercent: syncState.weeklyPercent)
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
        insightsWindow.show(analyzer: insightsAnalyzer, weeklyPercent: syncState.weeklyPercent)
    }

    func openSettings() {
        settingsWindow.show(monitor: self)
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

        // Real measured delta for "last turn impact" — valid only if the
        // session window itself didn't just reset between fetches. The API
        // recomputes resets_at fresh on every call with a little jitter
        // (observed ~1s drift between consecutive calls), so exact Date
        // equality almost never holds — use a tolerance instead. An actual
        // reset jumps resets_at by up to 5 hours, far outside this window.
        var sameWindow = false
        if let oldResets = syncState.sessionResetsAt, let newResets = newSessionResets {
            sameWindow = abs(oldResets.timeIntervalSince(newResets)) < 120
        }
        if let previous = syncState.sessionPercent, sameWindow, sessionPercent >= previous {
            lastTurnPercentImpact = sessionPercent - previous
        } else {
            lastTurnPercentImpact = nil
        }

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
            self.cumulativeCost += turn.weightedCost
            self.turnCount += 1
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

struct PhoneDashboardPanel: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📱 OPEN ON PHONE")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 14) {
                if let qr = generateQRCode(from: monitor.phoneURL) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 76, height: 76)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.phoneURL)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
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
                        monitor.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    Button {
                        monitor.openInsights()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentViolet)
                    }
                    .buttonStyle(.plain)
                    .help("Insights & recommendations")
                    Circle().fill(Color.accentTeal).frame(width: 9, height: 9)
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

                if let turn = monitor.lastTurn {
                    Divider().background(Color.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LAST TURN").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                        HStack {
                            Text(turn.model.replacingOccurrences(of: "claude-", with: ""))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            if let impact = monitor.lastTurnPercentImpact {
                                Text(String(format: "+%.2f%% of quota", impact))
                                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                                    .foregroundStyle(gaugeColor(for: monitor.estimatedPercent))
                            } else {
                                Text("measuring on next sync")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
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
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 400, height: 700)
        pop.contentViewController = hosting
        popover = pop

        refresh()

        // objectWillChange fires before the new value is actually stored, so
        // defer the read by one runloop tick to pick up the settled value.
        changeSubscription = sharedMonitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let showIcon = sharedMonitor.settings.showPieIcon
        button.image = showIcon ? renderPieIconImage(percent: sharedMonitor.estimatedPercent, trailingGap: 1) : nil
        button.title = showIcon
            ? menuBarSeparator(sharedMonitor.settings.separatorStyle) + sharedMonitor.menuBarText
            : sharedMonitor.menuBarText
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
