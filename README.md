# Usage

A macOS menu bar app that shows your real Claude plan usage — not an estimate,
not a guess. A live pie icon, the actual session/weekly percentages straight
from claude.ai, automatic syncing, and a phone-accessible dashboard.

## What it does

- **Live pie icon in the menu bar** — fills clockwise from 12 o'clock as your
  session usage rises, color-shifting teal → amber → red.
- **Real numbers, not scraped or estimated.** Calls the actual (undocumented)
  `claude.ai/api/organizations/{id}/usage` endpoint directly — session %,
  weekly %, and exact reset times, the same data the web app itself reads.
- **Zero manual entry after one-time login.** Log into your Claude account
  once in an embedded window; the app captures the session cookies itself
  (its own file, not relying on WebKit's cross-launch storage, which turned
  out to be unreliable for ad-hoc-signed apps) and re-syncs automatically
  after every turn.
- **Insights window** — scans every local Claude Code session on your Mac and
  surfaces real patterns: a conversation running unusually long, poor cache
  reuse, rising cost-per-turn.
- **Phone dashboard** — the app runs its own tiny local HTTP server; scan the
  QR code in the dropdown to see the same live gauge on your phone over Wi-Fi,
  no install, no login required on the phone.
- **Settings** — toggle which segments show in the menu bar (percentage, last
  turn's impact, next session reset time), pick a separator glyph, and toggle
  the pie icon on/off.
- Launches automatically at login.

## Building

Requires Xcode command line tools (Swift 5.9+, macOS 13+ SDK).

```sh
./build_app.sh
```

This builds the Swift package, wraps it into `Usage.app` with the bundled
icon, and installs it into `/Applications` (falling back to `~/Applications`
if that's not writable). The script updates the app **in place** rather than
deleting and recreating the bundle — that distinction matters, since
WKWebView's cookie persistence is sensitive to the bundle's on-disk identity.

## Architecture notes

- `App.swift` — `UsageMonitor` (the data/state layer), the SwiftUI views for
  the dropdown, and an `NSStatusItem`-based menu bar (not SwiftUI's
  `MenuBarExtra`, which doesn't reliably re-render custom label content on
  data changes — confirmed firsthand).
- `UsageAPI.swift` — calls the real usage endpoint using cookies persisted to
  our own JSON file, captured once at login time.
- `WebScraping.swift` — the one-time login window (`WKWebView`).
- `LocalServer.swift` — the embedded HTTP server for the phone dashboard,
  built on `Network.framework` with no third-party dependencies.
- `Insights.swift` — local session analysis and rule-based recommendations.
- `Settings.swift` — persisted settings, the pie icon renderer, and the
  Settings window.

## Known limitations

- Depends on an undocumented Anthropic API — could break without notice if
  Anthropic changes the response shape.
- Not signed with a real Developer ID, so macOS Gatekeeper may warn on first
  launch on another machine.
