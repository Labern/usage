# Usage

> A menu bar app that shows your Claude plan usage as a live, color-changing circle.

## Install

```bash
brew tap Labern/tap
brew trust --cask Labern/tap/claude-usage
brew install --cask Labern/tap/claude-usage
```

Then `Cmd+Space` → "Usage" → Return. Click the menu bar icon → **Connect Claude account**.

![Menu bar popover](https://raw.githubusercontent.com/Labern/usage/master/screenshots/1_menu_popover_crop.png)

---

## Screenshots

| Main | Insights | Turn History | Settings |
|------|----------|--------------|----------|
| ![Main popover](https://raw.githubusercontent.com/Labern/usage/master/screenshots/1_menu_popover_crop.png) | ![Insights](https://raw.githubusercontent.com/Labern/usage/master/screenshots/2_insights_crop.png) | ![Turn History](https://raw.githubusercontent.com/Labern/usage/master/screenshots/3_turn_history_crop.png) | ![Settings](https://raw.githubusercontent.com/Labern/usage/master/screenshots/4_settings_crop.png) |

![Menu bar](https://raw.githubusercontent.com/Labern/usage/master/screenshots/5_menubar_crop.png)

---

## Features

- **Circle** — your current 5-hour session usage. Fills clockwise, color shifts teal → orange → red.
- **Weekly %** and **next reset time** — shown under the circle.
- **⚙️ Settings** — pick what shows in the menu bar, and the separator style.
- **🕐 Turn History** — recent activity timeline, so you can see when/where a usage spike happened.
- **✨ Insights** — auto-generated notes on your usage patterns.
- **QR code** — scan with your phone (same Wi-Fi) for a live view there too.

---

## Notes

- Numbers come straight from Claude's own usage API — not estimated.
- Needs an internet connection to sync.
- Uses an undocumented Anthropic endpoint — may break if they change it.

---

## Build from source

```bash
xcode-select --install
git clone https://github.com/Labern/usage.git
cd usage
./build_app.sh
```

`./build_app.sh` builds the Swift package, wraps it in `Usage.app`, and installs to `/Applications` **in place** (not delete + recreate — WKWebView's cookie persistence is sensitive to the bundle's on-disk identity).

### Source map

| File | Responsibility |
|---|---|
| `App.swift` | State layer, dropdown views, `NSStatusItem`-based menu bar |
| `UsageAPI.swift` | Calls the real usage endpoint with cookies captured at login |
| `WebScraping.swift` | One-time login window (`WKWebView`) |
| `LocalServer.swift` | Phone dashboard's embedded HTTP server |
| `Insights.swift` | Local per-session analysis and recommendations |
| `TurnHistory.swift` | Per-turn timeline over local session transcripts |
| `Settings.swift` | Persisted settings, pie icon renderer, Settings window |

Limitations: undocumented API, no Developer ID signing (Gatekeeper may warn on another Mac).
