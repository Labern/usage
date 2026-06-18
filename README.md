# Usage

A little menu bar app for your Mac that shows how much of your Claude plan
you've used — a live, color-changing circle, right next to your clock.

## Installing it on your Mac

You don't need to know how to code to do this. Just follow the steps in order.

1. **Install the free Apple developer tools.** Open the **Terminal** app
   (press `Cmd + Space`, type "Terminal", press Return), paste in this line,
   and press Return:
   ```
   xcode-select --install
   ```
   A small window will pop up — click **Install** and wait for it to finish.
   (If it says these are already installed, that's fine — just move on.)

2. **Download this project.** On this GitHub page, click the green **Code**
   button near the top, then **Download ZIP**. Find the downloaded file in
   your Downloads folder and double-click it to unzip it.

3. **Open Terminal again** and move into the unzipped folder. If you
   downloaded it normally, this command will do it:
   ```
   cd ~/Downloads/usage-main
   ```

4. **Run the install script.** Paste this in and press Return:
   ```
   ./build_app.sh
   ```
   This will take a minute or two the first time. When it's done, it prints
   "Installed to /Applications/Usage.app".

5. **Open the app.** Press `Cmd + Space`, type "Usage", and press Return.
   You'll see a small percentage appear in your menu bar at the top right of
   your screen.

6. **Connect your Claude account.** Click that new menu bar item, then click
   **Connect Claude account**. A window opens — log into Claude exactly like
   you would on the website, then click **Done** once you can see you're
   logged in. That's the only login you'll need to do.

That's it — the app will now keep itself up to date automatically and will
also start by itself every time you turn on your Mac.

## Using it

Click the icon in your menu bar at any time to open it. Here's what you'll see:

- **The big circle** — how much of your current 5-hour session you've used.
  It fills up like a clock face and changes color as it gets fuller (teal →
  orange → red).
- **Weekly usage** — shown underneath the circle.
- **"New session at..."** — the time your usage will reset back down.

At the top of that window are a few small icons:

- **⚙️ Gear** — Settings. Choose what shows next to the icon in your menu
  bar (just the percentage, or also things like "how much my last message
  used" and "when my next session starts"), and pick what little symbol
  separates them.
- **🕐 Clock** — Turn History. A scrollable list of your recent activity, so
  if your usage suddenly jumps, you can see roughly when and in which project
  it happened.
- **✨ Sparkles** — Insights. Friendly notes about your usage patterns, like
  "this conversation is running long" or "your costs are creeping up."

Further down, there's a **QR code** — point your phone's camera at it (while
your phone is on the same Wi-Fi as your Mac) to see the same live circle on
your phone, no extra setup needed.

## Good to know

- This reads your usage from Claude's own website, the same numbers you'd
  see if you checked it yourself — nothing is estimated or made up.
- It only works while your Mac is connected to the internet.
- Anthropic doesn't officially publish this information for other apps to
  use, so if they change something on their end, this app may need an update
  to keep working.

---

## For developers

`./build_app.sh` builds the Swift package, wraps it in `Usage.app` with the
bundled icon, and installs it into `/Applications` (or `~/Applications` if
that's not writable) — **in place**, not via delete-and-recreate, since
WKWebView's cookie persistence is sensitive to the bundle's on-disk identity.

| File | Responsibility |
|---|---|
| `App.swift` | `UsageMonitor` (state/data layer), the dropdown's SwiftUI views, and an `NSStatusItem`-based menu bar (not SwiftUI's `MenuBarExtra`, which doesn't reliably re-render custom label content on data changes) |
| `UsageAPI.swift` | Calls the real `claude.ai/api/organizations/{id}/usage` endpoint using cookies captured at login and persisted to our own file |
| `WebScraping.swift` | The one-time login window (`WKWebView`) |
| `LocalServer.swift` | The phone dashboard's embedded HTTP server (`Network.framework`, no third-party deps) |
| `Insights.swift` | Local per-session analysis and rule-based recommendations |
| `TurnHistory.swift` | Per-turn timeline over local session transcripts |
| `Settings.swift` | Persisted settings, the pie icon renderer, and the Settings window |

Known limitations: depends on an undocumented Anthropic endpoint that could
change without notice; not signed with a real Developer ID, so Gatekeeper may
warn on first launch on another Mac.
