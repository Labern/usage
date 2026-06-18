# Usage

A menu bar app that shows your Claude plan usage as a live, color-changing circle.

## Install

1. Open **Terminal** (`Cmd + Space` → type "Terminal" → Return)
2. Paste and run:
   ```
   xcode-select --install
   ```
3. Click **Install** in the popup, wait for it to finish
4. On this page, click **Code → Download ZIP**, then unzip it
5. In Terminal, run:
   ```
   cd ~/Downloads/usage-main
   ./build_app.sh
   ```
6. Wait for "Installed to /Applications/Usage.app"
7. `Cmd + Space` → type "Usage" → Return
8. Click the new menu bar icon → **Connect Claude account**
9. Log in, then click **Done**

Done. It auto-starts at login from here on.

## Usage & features

- **Circle** — your current 5-hour session usage. Fills clockwise, color
  shifts teal → orange → red.
- **Weekly %** and **next reset time** — shown under the circle.
- **⚙️ Settings** — pick what shows in the menu bar, and the separator style.
- **🕐 Turn History** — recent activity timeline, so you can see when/where a
  usage spike happened.
- **✨ Insights** — auto-generated notes on your usage patterns.
- **QR code** — scan with your phone (same Wi-Fi) for a live view there too.

## Notes

- Numbers come straight from Claude's own usage API — not estimated.
- Needs an internet connection to sync.
- Uses an undocumented Anthropic endpoint — may break if they change it.

---

## For developers

`./build_app.sh` builds the Swift package, wraps it in `Usage.app`, and
installs to `/Applications` **in place** (not delete + recreate — WKWebView's
cookie persistence is sensitive to the bundle's on-disk identity).

| File | Responsibility |
|---|---|
| `App.swift` | State layer, dropdown views, `NSStatusItem`-based menu bar |
| `UsageAPI.swift` | Calls the real usage endpoint with cookies captured at login |
| `WebScraping.swift` | One-time login window (`WKWebView`) |
| `LocalServer.swift` | Phone dashboard's embedded HTTP server |
| `Insights.swift` | Local per-session analysis and recommendations |
| `TurnHistory.swift` | Per-turn timeline over local session transcripts |
| `Settings.swift` | Persisted settings, pie icon renderer, Settings window |

Limitations: undocumented API, no Developer ID signing (Gatekeeper may warn
on another Mac).
