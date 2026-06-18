import SwiftUI
import AppKit
import Foundation
import UsageCore

// MARK: - Persisted settings

enum SeparatorStyle: String, Codable, CaseIterable {
    case chevron, dot, bar, diamond

    var glyph: String {
        switch self {
        case .chevron: return "›"
        case .dot: return "∙"
        case .bar: return "│"
        case .diamond: return "⋄"
        }
    }

    var label: String {
        switch self {
        case .chevron: return "Chevron"
        case .dot: return "Dot"
        case .bar: return "Bar"
        case .diamond: return "Diamond"
        }
    }
}

struct AppSettings: Codable {
    var showPercent: Bool = true
    var showLastTurn: Bool = false
    var showNextSession: Bool = true
    var showPieIcon: Bool = true
    var separatorStyle: SeparatorStyle = .chevron

    static let defaultSettings = AppSettings()
}

let settingsFileURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeUsageMonitor")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("settings.json")
}()

func loadSettings() -> AppSettings {
    guard let data = try? Data(contentsOf: settingsFileURL),
          let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    else { return .defaultSettings }
    return decoded
}

func saveSettings(_ settings: AppSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    try? data.write(to: settingsFileURL)
}

// MARK: - Pie icon — fills clockwise from 12 o'clock as percent rises

struct PieSlice: Shape {
    var percent: Double // 0–100

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard percent > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        if percent >= 100 {
            path.addEllipse(in: rect)
            return path
        }
        path.move(to: center)
        let startAngle = Angle(degrees: -90)
        let endAngle = Angle(degrees: -90 + 360 * (percent / 100))
        // clockwise: false here actually sweeps visually clockwise, because
        // SwiftUI's view coordinate space has y pointing down.
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Renders the pie icon as a real bitmap rather than a live SwiftUI Shape.
/// MenuBarExtra's label area is small and finicky about custom Shape views
/// mixed with Text in an HStack — sizing collapses unpredictably. A fixed-size
/// NSImage has an unambiguous intrinsic size and renders reliably there.
func renderPieIconImage(percent: Double, diameter: CGFloat = 16, trailingGap: CGFloat = 6) -> NSImage {
    // Canvas is wider than the circle itself — the extra trailing space is
    // baked into the bitmap so there's reliable breathing room before the
    // title text, regardless of how NSStatusBarButton spaces image vs title.
    let canvasWidth = diameter + trailingGap
    let image = NSImage(size: NSSize(width: canvasWidth, height: diameter))
    image.lockFocus()

    let inset: CGFloat = 1.2
    let ovalRect = NSRect(x: inset, y: inset, width: diameter - inset * 2, height: diameter - inset * 2)
    // NSColor.labelColor resolves against whatever appearance is active in
    // this drawing context (typically light/black by default), not the menu
    // bar's actual dark appearance — at 0.35 alpha it was essentially
    // invisible there. A fixed light gray at higher opacity reads reliably
    // against the menu bar.
    NSColor(calibratedWhite: 0.88, alpha: 0.85).setStroke()
    let ring = NSBezierPath(ovalIn: ovalRect)
    ring.lineWidth = 1.4
    ring.stroke()

    let clamped = min(max(percent, 0), 100)
    if clamped > 0 {
        let center = NSPoint(x: diameter / 2, y: diameter / 2)
        let radius = (diameter - inset * 2) / 2
        let sweep = CGFloat(clamped / 100) * 360
        let pie = NSBezierPath()
        pie.move(to: center)
        // y-up coordinate space here (NSImage lockFocus, not flipped):
        // 90° is already 12 o'clock, and clockwise:true sweeps downward
        // from there — exactly the "fills clockwise from the top" behavior.
        pie.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        pie.close()
        nsGaugeColor(for: clamped).setFill()
        pie.fill()
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

func nsGaugeColor(for percent: Double) -> NSColor {
    switch percent {
    case ..<50: return NSColor(red: 0.369, green: 0.918, blue: 0.831, alpha: 1)
    case 50..<80: return NSColor(red: 0.98, green: 0.75, blue: 0.35, alpha: 1)
    default: return NSColor(red: 0.96, green: 0.35, blue: 0.4, alpha: 1)
    }
}

struct MenuBarPieIcon: View {
    let percent: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1.3)
            PieSlice(percent: percent)
                .fill(gaugeColor(for: percent))
        }
        .frame(width: 15, height: 15)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { monitor.settings[keyPath: keyPath] },
            set: { newValue in
                monitor.settings[keyPath: keyPath] = newValue
                monitor.persistSettings()
            }
        )
    }

    private func applyPreset(percent: Bool, lastTurn: Bool, nextSession: Bool) {
        monitor.settings.showPercent = percent
        monitor.settings.showLastTurn = lastTurn
        monitor.settings.showNextSession = nextSession
        monitor.persistSettings()
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.bgDeep, .bgMid, .bgDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 12) {
                    Text("MENU BAR TEXT — QUICK PRESETS")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 8) {
                        Button("Just %") { applyPreset(percent: true, lastTurn: false, nextSession: false) }
                        Button("% + last turn") { applyPreset(percent: true, lastTurn: true, nextSession: false) }
                        Button("% + next session") { applyPreset(percent: true, lastTurn: false, nextSession: true) }
                        Button("Everything") { applyPreset(percent: true, lastTurn: true, nextSession: true) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentViolet)
                    .font(.system(size: 14))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("FINE CONTROL").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    Toggle("Show percentage", isOn: binding(\.showPercent))
                    Toggle("Show last turn's impact (+X%)", isOn: binding(\.showLastTurn))
                    Toggle("Show next session reset time", isOn: binding(\.showNextSession))
                }
                .font(.system(size: 15))
                .toggleStyle(.checkbox)
                .foregroundStyle(.white.opacity(0.9))

                VStack(alignment: .leading, spacing: 8) {
                    Text("SEPARATOR").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    Picker("", selection: binding(\.separatorStyle)) {
                        ForEach(SeparatorStyle.allCases, id: \.self) { style in
                            Text("\(style.glyph)  \(style.label)").tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Divider().background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 12) {
                    Text("ICON").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    Toggle("Pie icon — fills clockwise as usage rises", isOn: binding(\.showPieIcon))
                        .font(.system(size: 15))
                        .toggleStyle(.checkbox)
                        .foregroundStyle(.white.opacity(0.9))
                    HStack(spacing: 14) {
                        ForEach([10.0, 35.0, 64.0, 92.0], id: \.self) { p in
                            VStack(spacing: 5) {
                                MenuBarPieIcon(percent: p).frame(width: 24, height: 24)
                                Text("\(Int(p))%").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                Spacer()
                Text("Preview: \(monitor.menuBarText.isEmpty ? "(icon only)" : monitor.menuBarText)")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(28)
        }
        .frame(width: 460, height: 560)
    }
}

final class SettingsWindowController {
    private var window: NSWindow?

    func show(monitor: UsageMonitor, anchorFrame: NSRect?, side: WindowSide) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(monitor: monitor))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Usage Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        applyDarkAppearance(window)
        // NSWindow(contentViewController:) can pick up a stale/default frame
        // before SwiftUI's `.frame()` modifier has actually laid out — fixing
        // the content size here guarantees positionWindow's width math (which
        // subtracts width for the .left side) sees the real size.
        window.setContentSize(hosting.view.fittingSize)
        window.makeKeyAndOrderFront(nil)
        positionWindow(window, relativeTo: anchorFrame, side: side)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
