# KNOWLEDGE — ClaudeUsageMonitor & Claude Code environment

Durable, hard-won notes so the work can be picked up cold. Newest section on top.

---

## 2026-06-25 — Global hotkey toggle + custom Claude Code status line

### What was built
1. A **system-wide hotkey (⌘E)** that toggles the menu-bar app's popover open/closed
   from any app, with no Accessibility permission.
2. A **custom Claude Code status line** rendering
   `[MODEL]/effort  ✝ ● ヨ: EVA-01 |神児|  <session-name>` with per-segment colours.
3. Two environment tweaks: Remote Control auto-start, and notes on token-usage commands.

### Global hotkey — how it works (`Sources/ClaudeUsageMonitor/App.swift`)
- Use **Carbon's `RegisterEventHotKey`** (`import Carbon.HIToolbox`). This is the right
  API for a global hotkey: it registers a proper system hotkey and, unlike a
  `CGEventTap`, needs **no Accessibility (TCC) permission**.
- The handler is a `@convention(c)` C callback, so it **cannot capture `self`**. Pass the
  delegate through `userData`:
  - install with `Unmanaged.passUnretained(self).toOpaque()` as the `userData` arg;
  - inside the callback recover it with
    `Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()`.
- **Gotcha:** the method the callback calls (`toggle()`) must **not be `private`** — the
  C closure is lexically outside the class, so a `private` method is unreachable from it.
  It was `@objc private func toggle()`; dropping `private` (kept `@objc`) fixed the build.
- Marshal work back onto the main thread inside the callback:
  `DispatchQueue.main.async { delegate.toggle() }`.
- **One `InstallEventHandler` serves all hotkeys.** To add a second chord you do NOT
  install another handler — you just call `RegisterEventHotKey` again with its **own
  `EventHotKeyRef`** and a **distinct `EventHotKeyID.id`** (e.g. id 1 and id 2, same
  signature `'CUMO'`). Both fire the same handler → same `toggle()`.
- Key constants: `kVK_ANSI_E` (virtual keycode), `cmdKey` (modifier),
  `kEventClassKeyboard` / `kEventHotKeyPressed` (event spec).
- **Trade-off:** a global hotkey overrides that chord in *every* app while the monitor
  runs (⌘E, ⌘U, etc. are common — view-source, underline…). Scope to app-frontmost only
  if that bites. History this session: added ⌘U, then added ⌘E alongside, then removed
  ⌘U leaving only ⌘E — the "add-second-then-drop-first" order let us confirm ⌘E worked
  before deleting the known-good ⌘U.

Reference shape (final, ⌘E only):
```swift
import Carbon.HIToolbox
// in AppDelegate:
private var hotKeyRefE: EventHotKeyRef?
private var hotKeyHandlerRef: EventHandlerRef?

private func registerToggleHotKey() {
    var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(),
        { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let d = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { d.toggle() }
            return noErr
        }, 1, &eventSpec,
        Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandlerRef)
    RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(cmdKey),
        EventHotKeyID(signature: 0x43554D4F /* 'CUMO' */, id: 1),
        GetApplicationEventTarget(), 0, &hotKeyRefE)
}
```
Called once from `applicationDidFinishLaunching`. `toggle()` reuses the existing
popover show/close (`NSApp.activate(ignoringOtherApps: true)` on show).

### Claude Code status line — how it works
- Configured in **`~/.claude/settings.json`**:
  `"statusLine": { "type": "command", "command": "bash /Users/labern/.claude/statusline-command.sh" }`.
- The script gets a **JSON blob on stdin** each render; it `printf`s one line to stdout.
- **Discovering the available fields (the key technique):** don't guess the schema —
  temporarily replace the script with one that tees stdin to a file
  (`printf '%s' "$input" > /tmp/cc-statusline-capture.json`) while still rendering, then
  read that file from a **background poll** (`run_in_background`). The user's *live*
  session invokes the status-line script continuously, so the capture lands within
  seconds even though this (background) session can't trigger a render itself.
- **Real fields on this install (Claude Code v2.1.190)** — more than the public docs list:
  `session_id`, `transcript_path`, `cwd`, `effort.level` ("xhigh"), `session_name`
  ("Creating Usage App"), `model.{id,display_name}`,
  `workspace.{current_dir,project_dir,added_dirs,repo.{host,owner,name}}`, `version`,
  `output_style.name`, `cost.{total_cost_usd,total_duration_ms,...}`,
  `context_window.{used_percentage,remaining_percentage,current_usage,...}`,
  `exceeds_200k_tokens`, `fast_mode`, `thinking.enabled`,
  `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`.
  → `effort` and `session_name` ARE available; no need to read them from disk.
- **ANSI colour gotcha:** "bright"/high-intensity colours are codes **90–97**, not 30–37.
  Bright yellow = `\033[1;93m` (normal yellow `1;33m` looked dull → user asked for
  brighter → switched to `1;93m`). Use `printf "%b"` so `\033[` escapes are interpreted.
- Model short tag via `grep -oiE 'opus|sonnet|haiku|fable'` then uppercase for `[OPUS]`.
- Segment colours used: model white `1;37`, effort cyan `0;36`, EVA cross red `0;31`,
  katakana purple `1;35` (was blue `0;34` — user called it "the purple katakana"),
  session name bright yellow `1;93`.

### Environment tweaks learned
- **Remote Control on by default:** add `"remoteControlAtStartup": true` to
  `~/.claude/settings.json` (schema key; "Start Remote Control bridge automatically each
  session"). Takes effect next session start, not the running one. **No token cost** —
  the bridge is just a relay; tokens are spent only on actual turns, same whether driven
  from terminal or phone. Related keys: `isolatePeerMachines`, `autoUploadSessions`.
- **Keeping token usage down:** `/clear` is the bigger lever (wipes context; every turn
  re-sends history as input tokens) — use between unrelated tasks. `/compact` summarises
  and keeps going — use mid-task when the session gets long. Prompt caching already
  absorbs much of the repeated-context cost, so no need to compact constantly.

### Build / iterate workflow (unchanged, but re-confirmed)
- `cd ClaudeUsageMonitor && swift build` to check compilation, then **`./build_app.sh`**
  (installs the bundle to `/Applications/Usage.app`).
- **Must relaunch to pick up changes:** `pkill -f "Usage.app"; sleep 1; open /Applications/Usage.app`.
- Run as the **`.app` bundle**, never the raw binary (WKWebView cookie storage is keyed
  to the bundle id).
