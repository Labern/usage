# Learning Swift From This App

This file is a guided tour of `ClaudeUsageMonitor` — a real, working macOS
menu bar app — written so you can use it to actually learn Swift, SwiftUI,
and AppKit instead of reading a generic tutorial. Every concept below is
tied to a specific line in this repo. Open the referenced file alongside
this doc and read them side by side.

The intended way to use this: read a section, then go find the code it's
talking about and look at it in context (not just the snippet quoted here).
Then move to the next section. By the end you'll have toured every file in
the project and picked up the Swift/SwiftUI/AppKit features that make it
work.

---

## 1. What this app actually does

`Usage` is a macOS menu bar app that shows you, as a small live gauge, how
much of your Claude plan you've used — both in the current 5-hour session
and over the rolling 7-day window. Concretely:

- It sits in the menu bar as a small pie-slice icon plus optional text
  (`12%`, or `12% · +1.5% last turn · New session at 4:00 PM`, depending on
  what you've enabled in Settings).
- Click it and a popover drops down showing a big circular gauge, a
  "connect your account" flow, a phone-dashboard QR code, and shortcuts to
  three auxiliary windows: **Settings**, **Turn History**, and **Insights**.
- The real percentages come straight from Anthropic's own (undocumented)
  usage API — the app logs in once via an embedded browser, captures the
  session cookies, and then calls `https://claude.ai/api/organizations/<org>/usage`
  directly with those cookies on every turn and every 60 seconds as a
  safety net.
- Independently, it tails every `~/.claude/projects/**/*.jsonl` Claude Code
  transcript file on your Mac, second by second, to know the instant a new
  "turn" (one assistant reply with a token-usage block) happens — that's
  what triggers the "fetch fresh numbers now" call, and what powers the
  Turn History and Insights windows (which are 100% local statistics, no
  network call involved).
- It also runs a tiny embedded HTTP server on your LAN so you can scan a QR
  code and see the same live gauge on your phone.

None of this needs a database, a build tool, or a single third-party
dependency — `Package.swift` declares zero dependencies, and everything
above is built from Apple's own frameworks (`SwiftUI`, `AppKit`, `WebKit`,
`Network`, `Foundation`, `CoreImage`, `ServiceManagement`, `Combine`).

---

## 2. File structure — what lives where

```
ClaudeUsageMonitor/
├── Package.swift                       Swift Package Manager manifest
├── build_app.sh                        Wraps `swift build` into a real .app bundle
├── icon/generate_icon.swift            One-off script that drew the app's Dock/Finder icon
└── Sources/ClaudeUsageMonitor/
    ├── App.swift          The hub: app state, the menu bar item, the popover UI,
    │                      window positioning helpers, theme colors, token pricing
    ├── UsageAPI.swift      Talks to the real claude.ai usage endpoint using saved cookies
    ├── WebScraping.swift   The one-time login window (a plain WKWebView)
    ├── LocalServer.swift   The phone dashboard's raw TCP/HTTP server + QR code generator
    ├── Settings.swift      Persisted settings model, the pie-icon renderer, Settings window
    ├── TurnHistory.swift   Per-turn timeline window — scans local transcripts
    └── Insights.swift      Per-session analyzer — rule-based usage insights window
```

A few things worth noticing about this structure before you read any code:

- **No `main.swift`.** Swift treats a file literally named `main.swift` as
  *implicit top-level executable code* — every top-level statement in it
  just runs, in order, no `@main` needed. This project instead uses the
  `@main` attribute (see `ClaudeUsageMonitorApp` at the bottom of
  `App.swift`) to mark the entry point explicitly, which is why the file
  with `@main` in it is named `App.swift`, not `main.swift`. The two
  approaches are mutually exclusive — having both is a compile error.
- **One target, one folder.** `Package.swift` declares a single
  `executableTarget` pointed at `Sources/ClaudeUsageMonitor`. There's no
  separate library target, no test target (yet) — everything compiles into
  one binary.
- **Files are split by *feature*, not by *layer*.** `Settings.swift`
  contains its data model (`AppSettings`), its rendering logic (the pie
  icon renderer), *and* its window/view code, all together. This is a
  reasonable pattern for an app this size: you only ever need to open one
  file to understand or change one feature, instead of jumping between a
  `Models/`, `Views/`, and `Controllers/` folder for every change.

---

## 3. Swift language features, in the order you'll meet them

### 3.1 `enum` with associated behavior — `Sources/ClaudeUsageMonitor/Settings.swift:7-27`

```swift
enum SeparatorStyle: String, Codable, CaseIterable {
    case chevron, dot, bar, diamond

    var glyph: String {
        switch self {
        case .chevron: return "›"
        ...
        }
    }
}
```

Swift enums aren't just a set of named constants like in C — they can carry
**computed properties** (`glyph`, `label` here) and conform to protocols.
`: String` means each case has a raw string value (`"chevron"` etc.) for
free, which is what makes it `Codable` — you get JSON persistence with zero
extra code. `CaseIterable` auto-generates `SeparatorStyle.allCases`, used in
the Settings UI's segmented picker (`Settings.swift:205`) to build the list
of options without hand-maintaining an array.

### 3.2 `struct` + `Codable` for free JSON persistence — `Settings.swift:29-56`

```swift
struct AppSettings: Codable {
    var showPercent: Bool = true
    ...
    static let defaultSettings = AppSettings()
}

func loadSettings() -> AppSettings {
    guard let data = try? Data(contentsOf: settingsFileURL),
          let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    else { return .defaultSettings }
    return decoded
}
```

This pattern repeats three times in the app (`AppSettings` here,
`SyncState` in `App.swift:110-120`, `SavedCookie` in `UsageAPI.swift:15-19`)
— it's the idiomatic "tiny local database" in Swift: a plain `struct`
conforming to `Codable`, encoded/decoded straight to a JSON file with
`JSONEncoder`/`JSONDecoder`. No SQLite, no Core Data, no third-party
persistence library needed for settings-sized data.

Notice `try?` instead of `try`/`catch` — it converts a throwing call into
an `Optional` (`nil` on failure instead of propagating the error). Chaining
multiple `try?`s in one `guard let ... , let ... else` is a common Swift
idiom for "attempt several optional steps, bail to a sane default if any
of them fails" — exactly what you want for "load preferences, or fall back
to defaults if the file's missing or corrupt."

### 3.3 Protocol-oriented `Shape` and custom drawing — `Settings.swift:60-81`

```swift
struct PieSlice: Shape {
    var percent: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard percent > 0 else { return path }
        ...
        path.addArc(center: center, radius: radius, startAngle: startAngle,
                    endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}
```

`Shape` is a SwiftUI protocol with exactly one requirement: turn a
`CGRect` into a `Path`. Conform to it and you get a real SwiftUI `View`
for free (`Shape` extends `View`) — you can `.fill()` it, `.stroke()` it,
animate its parameters, etc. This is how the app draws "a pie slice that's
X% of a circle" as a reusable, declarative SwiftUI shape rather than
dropping into manual `Core Graphics` drawing — that manual approach
*does* show up separately, in `renderPieIconImage` (see §3.4), because the
two have different jobs.

Read the comment right above the angle-sweep line — it explains a subtle
gotcha that's *the* most important thing to internalize about drawing
circles in Apple frameworks: SwiftUI's `View` coordinate space has **y
pointing down**, so "visually clockwise" and "mathematically clockwise"
(`clockwise: true`) are opposite. Compare this to `renderPieIconImage`
below, which draws into an `NSImage` (a **y-up**, "flipped" coordinate
space) — there, `clockwise: true` really is visually clockwise. Same pie
slice, two coordinate systems, two different `clockwise` values to get the
same visual result. This is a real bug class in Apple UI code; the
comments in both places exist because it bit the person who wrote this.

### 3.4 `NSImage.lockFocus()` — manual bitmap drawing (AppKit) — `Settings.swift:87-126`

```swift
func renderPieIconImage(percent: Double, diameter: CGFloat = 16, trailingGap: CGFloat = 6) -> NSImage {
    let image = NSImage(size: NSSize(width: canvasWidth, height: diameter))
    image.lockFocus()
    // ... NSBezierPath drawing calls here ...
    image.unlockFocus()
    image.isTemplate = false
    return image
}
```

This is **AppKit**, not SwiftUI — `lockFocus()`/`unlockFocus()` bracket a
block of imperative drawing calls (`NSBezierPath`, `.setStroke()`,
`.setFill()`) into a fixed-size bitmap. Why not just use the `PieSlice`
SwiftUI `Shape` from §3.3 here too? The comment directly above the function
explains it: `MenuBarExtra`'s label area collapses unpredictably when you
mix a live SwiftUI `Shape` with `Text` — so the menu bar icon specifically
needs an unambiguous, pre-rendered bitmap with a fixed intrinsic size.
**Same visual result, two different tools, chosen because one tool failed
in one specific host context.** That's a realistic, not theoretical,
reason to reach for AppKit instead of staying in pure SwiftUI.

### 3.5 Closures as stored properties — `App.swift:205`, `App.swift:752-761`

```swift
var anchorFrameProvider: (() -> NSRect?)?
```

This declares a property whose *type* is "a function that takes no
arguments and returns an optional `NSRect`" — a closure stored as data,
not called immediately. It's set once, in `AppDelegate`:

```swift
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
```

This is a real-world case for a common pattern: `UsageMonitor` (in
`App.swift`) needs to know "where is the popover on screen right now?" to
position auxiliary windows beside it, but `UsageMonitor` has no reference
to `AppDelegate`'s `NSStatusItem`/`NSPopover` (and shouldn't — that would
create a dependency in the wrong direction, view-state on app-plumbing).
Instead, `AppDelegate` *hands `UsageMonitor` a closure* that knows how to
answer the question, and `UsageMonitor` just calls it
(`anchorFrameProvider?()` in `openSettings()` etc., `App.swift:336-346`)
without knowing or caring how the answer is computed. This is dependency
injection without a framework — just a stored closure.

`[weak self]` in the closure's capture list is worth understanding on its
own: without it, the closure would hold a *strong* reference to
`AppDelegate`, and since `AppDelegate` holds the closure as a property,
you'd have a **reference cycle** — neither object can ever be deallocated.
`[weak self]` makes the captured `self` an `Optional` that becomes `nil` if
the real object is freed elsewhere, which is why the closure immediately
does `guard let self = self else { return nil }`.

### 3.6 `final class ... : ObservableObject` + `@Published` — `App.swift:195-217`

```swift
final class UsageMonitor: ObservableObject {
    @Published var lastTurn: TurnUsage?
    @Published var cumulativeCost: Double = 0
    @Published var settings: AppSettings = loadSettings()
    ...
}
```

This is the backbone of how SwiftUI views in this app stay in sync with
real-time state. `ObservableObject` + `@Published` is Combine's (Apple's
reactive framework) integration point with SwiftUI: any view that holds
this object as `@ObservedObject var monitor: UsageMonitor` (see
`ConnectPanel`, `SettingsView`, `MenuContentView`, etc.) automatically
re-renders whenever *any* `@Published` property on it changes — you never
manually call something like `setNeedsDisplay()`. `final` on the class is
a small but meaningful detail: it tells the compiler no subclass will ever
override anything here, which both documents intent and lets the compiler
skip dynamic-dispatch overhead for its methods.

Contrast this with the comment at `App.swift:711-716`, which explains a
real limitation the author hit: SwiftUI's own `MenuBarExtra` API doesn't
reliably re-render its label when `@Published` properties change — so the
actual menu bar button (`NSStatusItem`) is driven *imperatively* instead
(`button.image = ...`, `button.title = ...` in `AppDelegate.refresh()`,
triggered by manually subscribing to `objectWillChange`). This is a good
lesson in itself: SwiftUI's declarative model is the default, but when a
specific Apple API doesn't hold up its end of the contract, dropping to
imperative AppKit calls driven by your own subscription is a legitimate
fallback — not a sign you're "doing SwiftUI wrong."

### 3.7 `Binding` with a generic key path — `Settings.swift:153-161`

```swift
private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { monitor.settings[keyPath: keyPath] },
        set: { newValue in
            monitor.settings[keyPath: keyPath] = newValue
            monitor.persistSettings()
        }
    )
}
```

This is a small piece of generic, reusable plumbing worth slowing down on.
`WritableKeyPath<AppSettings, T>` is a *first-class reference to a
property* — `\.showPercent` is a `WritableKeyPath<AppSettings, Bool>`,
`\.separatorStyle` is a `WritableKeyPath<AppSettings, SeparatorStyle>`, and
so on. Instead of writing six nearly-identical `Binding(get:set:)` blocks
for six toggles/pickers, this one generic function works for *all* of
them — call `binding(\.showPercent)` and get back a `Binding<Bool>` that
reads/writes that one field and calls `persistSettings()` after every
write. `T` is inferred automatically from whichever key path you pass in.
This is the kind of abstraction Swift's type system makes nearly free —
no runtime cost, full type safety, and it deletes real duplication. (Compare
this to the project's own CLAUDE.md guidance to avoid premature
abstraction — this one earns its keep because it's used six times in the
same file, not because it might be useful someday.)

### 3.8 Error handling with custom `NSError` — `UsageAPI.swift:56-103`

```swift
guard !jar.isEmpty else {
    completion(.failure(NSError(domain: "UsageAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "No saved session — connect your account first."])))
    return
}
```

`Result<[String: Any], Error>` plus a completion-handler closure is the
classic pre-`async`/`await` pattern for asynchronous APIs in Swift —
you'll see it throughout `UsageAPI.swift` and `Insights.swift`. Each
distinct failure mode gets its own `code` (1 through 5 here) and a
human-readable `NSLocalizedDescriptionKey` message — when something goes
wrong, the message that eventually reaches `statusMessage` in
`UsageMonitor` (`App.swift:360`) is exactly this string, which is why
errors in this app tend to be specific ("No `lastActiveOrg` cookie saved.
Cookies present: ...") instead of a generic "something went wrong."

### 3.9 `DispatchQueue` and explicit threading — `Insights.swift:68-79`, `TurnHistory.swift:26-37`

```swift
func refresh(weeklyPercent: Double?) {
    isLoading = true
    DispatchQueue.global(qos: .userInitiated).async {
        let summaries = self.scanAllSessions()
        let generated = Self.generateInsights(sessions: summaries, weeklyPercent: weeklyPercent)
        DispatchQueue.main.async {
            self.sessions = summaries
            self.insights = generated
            self.isLoading = false
        }
    }
}
```

This pattern — *do slow work on a background queue, then hop back to
`.main` to touch `@Published` UI state* — appears identically in both
`InsightsAnalyzer` and `TurnHistoryAnalyzer`, because both classes do the
same kind of work: walk every `.jsonl` file under `~/.claude/projects`,
which can be slow if you have a lot of session history. `@Published`
properties are only safe to mutate on the main thread (SwiftUI's
rendering is tied to it), so the inner `DispatchQueue.main.async` block at
the end is not optional ceremony — skipping it is a real, if often silently
tolerated, threading bug.

### 3.10 `NWListener` — a raw TCP server, no frameworks — `LocalServer.swift:11-128`

`LocalUsageServer` is a real (tiny) HTTP/1.1 server built entirely on
Apple's `Network` framework — no Vapor, no third-party socket library.
Worth tracing through once:

- `NWListener` (`LocalServer.swift:22`) opens a TCP listening socket on a
  fixed port.
- Every new connection gets handed to `handle(_:)`, which calls
  `receive(on:buffer:)` — a small **recursive function** that keeps
  appending incoming bytes to a buffer until it finds the `\r\n\r\n` that
  marks the end of an HTTP header block, then dispatches based on the
  request line (`respond(to:on:)`).
- Responses are hand-assembled HTTP: a literal `"HTTP/1.1 \(status)\r\n..."`
  string concatenated with a `Content-Length` computed from the body's
  byte count (`LocalServer.swift:114-121`).

This is a good example of "you don't need a framework to do networking in
Swift" — and also a good example of where *not* to reach for this style in
a real production server: there's no concurrency limit, no timeout
handling beyond `isComplete`, and no HTTP parsing beyond the first line.
It's appropriately scoped for "a read-only, LAN-only, single-user phone
dashboard," which is exactly the comment at the top of the file
(`LocalServer.swift:7-10`) tells you it's for.

### 3.11 `NWPathMonitor`-adjacent: low-level C interop for LAN IP — `LocalServer.swift:132-151`

```swift
func getLocalIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        ...
    }
}
```

This function calls straight into BSD/POSIX C APIs (`getifaddrs`,
`getnameinfo`) — the same calls you'd use in C — because there's no
higher-level Apple API for "what's my LAN IP." `UnsafeMutablePointer` is
Swift's typed wrapper around a raw C pointer; `defer { freeifaddrs(ifaddr) }`
guarantees the C-allocated linked list gets freed exactly once, no matter
which `return` inside the function actually executes (`defer` blocks always
run when the enclosing scope exits, in reverse order if there are several).
`sequence(first:next:)` is a neat Swift standard library trick for turning
a C-style linked list (where each node has a `.pointee.ifa_next` pointer to
the next one) into something you can iterate with a plain `for` loop.

### 3.12 `NSApplicationDelegateAdaptor` and the smallest possible `App` — `App.swift:792-801`

```swift
@main
struct ClaudeUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

Every SwiftUI app needs a type conforming to the `App` protocol marked
`@main`, with a `body` that returns at least one `Scene`. This app barely
uses SwiftUI's own app lifecycle at all — `@NSApplicationDelegateAdaptor`
bridges in a classic AppKit `NSApplicationDelegate`
(`applicationDidFinishLaunching`, full AppKit control over the status item
and popover), and the `Scene` is a throwaway `Settings { EmptyView() }`
purely to satisfy the protocol requirement. The comment right above it is
honest about this: "All real UI is driven by AppDelegate's
NSStatusItem/NSPopover — SwiftUI still requires at least one Scene to
exist." This is a useful pattern to recognize: SwiftUI's `App`/`Scene`
machinery is mainly built around document- and window-based apps; a menu
bar utility like this one uses just enough of it to boot, then does
everything else in AppKit.

### 3.13 `enum` for a closed two-value choice instead of a `Bool` — `App.swift:155`

```swift
enum WindowSide { case left, right }
```

It would be possible to write `func positionWindow(..., onLeft: Bool)`
instead. The enum is more self-documenting at every call site —
`side: .left` reads unambiguously, whereas `onLeft: true` requires you to
remember which way `true` goes. This is a cheap, idiomatic Swift habit:
reach for a small `enum` instead of a `Bool` whenever the two states have
names that mean something (`.left`/`.right`, not `true`/`false`).

### 3.14 Multi-line string literals for embedded HTML — `LocalServer.swift:171-261`

```swift
let dashboardHTML = """
<!DOCTYPE html>
<html>
...
</html>
"""
```

Triple-quoted strings (`"""`) let you embed a large, multi-line block of
literal text — here, a whole HTML/CSS/JS page — directly in a Swift source
file with no escaping of quotes or newlines required. This is how the
phone dashboard ships without a separate `.html` asset file or build step:
it's just a Swift `String` constant, served byte-for-byte by
`LocalUsageServer.respond(to:on:)`.

---

## 4. SwiftUI-specific patterns worth knowing

- **`ZStack` + `LinearGradient` + `.ignoresSafeArea()`** is the recurring
  background pattern across every window (`SettingsView`, `InsightsView`,
  `TurnHistoryView`, `MenuContentView`) — a gradient sits behind the
  content in a `ZStack`, ignoring the safe area so it fills the whole
  window edge-to-edge rather than stopping at the title bar inset.
- **`@ObservedObject` vs. owning the object.** Every auxiliary view takes
  its model as `@ObservedObject var monitor: UsageMonitor` (or `analyzer:`)
  — meaning the view *observes* an object it doesn't own and didn't
  create. The object's actual lifetime is owned by `UsageMonitor` itself
  (`insightsAnalyzer`, `turnHistoryAnalyzer` as `let` properties,
  `App.swift:213-216`) or by `sharedMonitor` (`App.swift:709`), a single
  global instance shared for the app's whole lifetime — a deliberate
  choice given there's exactly one menu bar item and exactly one set of
  app-wide state.
- **`.fixedSize(horizontal: false, vertical: true)`** (e.g.
  `TurnHistory.swift:119`, `Insights.swift:253`) — tells a multi-line
  `Text` to take exactly the height its content needs rather than
  truncating or wrapping unpredictably inside a fixed-size parent. Worth
  remembering any time body text inside a `VStack` looks clipped.
- **`GeometryReader` for proportional widths** — `TurnHistoryRow`
  (`TurnHistory.swift:153-157`) uses `GeometryReader` to read the
  available width of its parent and draw a background rectangle scaled to
  `share` (a 0–1 fraction) — a simple, dependency-free progress-bar effect.

---

## 5. AppKit-specific patterns worth knowing

- **`NSPopover` with `.semitransient`** (`App.swift:741-750`) — the main
  dropdown isn't a window, it's a popover anchored to the status item.
  `.semitransient` behavior (vs. `.transient`) is what allows the
  Settings/Insights/Turn History windows to open *without* the main
  popover snapping shut the instant they take focus.
- **A global event monitor for click-away dismissal**
  (`App.swift`, `outsideClickMonitor` in `AppDelegate`) —
  `NSEvent.addGlobalMonitorForEvents` only fires for clicks *outside your
  own app's windows*, which is exactly the tool needed to close the
  popover on an outside click while leaving clicks on your own auxiliary
  windows alone.
- **`NSHostingController`** — the bridge that lets a SwiftUI `View` be
  hosted inside a plain AppKit `NSWindow`. Every auxiliary window
  controller (`SettingsWindowController`, `InsightsWindowController`,
  `TurnHistoryWindowController`) follows the same shape: build a SwiftUI
  view, wrap it in `NSHostingController(rootView:)`, hand that to
  `NSWindow(contentViewController:)`.
- **Window leveling and positioning** — `positionWindow(_:relativeTo:side:)`
  (`App.swift:161-193`) is a good worked example of real AppKit screen-space
  math: computing an x-coordinate relative to an anchor frame, clamping it
  to the screen's visible frame so it can never run off-screen, and setting
  `window.level = .floating` so it renders above the popover's own
  popover-level window layer instead of getting visually buried under it.

---

## 6. A few real bugs fixed in this codebase, and what they teach

Reading old bugs (and their fixes) in a real project is often more
instructive than reading correct code, because it shows you the kind of
mistake the language/framework actually invites.

1. **Window width read before layout.** `positionWindow` computes
   `x = anchorFrame.minX - window.frame.width - gap` for the `.left` side.
   But `window.frame.width`, read immediately after
   `NSWindow(contentViewController:)`, can still reflect a stale/default
   size — SwiftUI's `.frame(width:height:)` modifier on the root view
   doesn't necessarily take effect synchronously. The `.right` side
   (`x = anchorFrame.maxX + gap`) never used `width` at all, so it
   "accidentally" worked while `.left` silently didn't. The fix:
   `window.setContentSize(hosting.view.fittingSize)` before measuring or
   positioning, forcing AppKit to settle on the real size first. Lesson:
   **a bug that only shows up on one of two structurally identical code
   paths is often hiding an implicit dependency** — here, a dependency on
   timing/layout-completion that one path's math happened not to need.
2. **Coordinate-space sign flips.** Covered in §3.3 — the same
   "clockwise" boolean means visually opposite things in SwiftUI's `Path`
   (y-down) versus AppKit's `NSBezierPath` inside `lockFocus()` (y-up,
   unflipped). Any time you port the same drawing logic between SwiftUI
   and AppKit, re-derive the angle math instead of assuming it transfers.
3. **A framework component's reactivity contract not holding.** Covered in
   §3.6 — `MenuBarExtra`'s label not reliably updating from `@Published`
   state. Lesson: declarative bindings are *usually* reliable, but verify
   it for the specific component you're using before building an entire
   feature on the assumption.

---

## 7. Where to go next

- Open `Sources/ClaudeUsageMonitor/App.swift` top to bottom once, slowly —
  it's the largest file and ties every other file together.
- Try adding a fourth `SeparatorStyle` case and watch the Settings UI pick
  it up automatically (because of `CaseIterable` — §3.1) with no other
  code changes.
- Try changing `WindowSide` to add a `.center` case and wiring it through
  `positionWindow` — a small, contained way to practice extending an
  `enum` and a `switch` statement that's required to be exhaustive (Swift
  won't compile a `switch` over an enum that's missing a case, which is
  itself worth experiencing once).
