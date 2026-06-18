import WebKit
import AppKit

/// Visible window where the user logs into claude.ai once. We don't need
/// them to navigate anywhere specific or click anything on the page — once
/// login cookies exist in this persistent WKWebsiteDataStore, UsageAPI can
/// call the real usage endpoint directly. No element picking required.
final class ConnectWindowController: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    var onDone: (() -> Void)?

    func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let totalHeight: CGFloat = 700
        let totalWidth: CGFloat = 900
        let barHeight: CGFloat = 44

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight - barHeight), configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        self.webView = webView

        let bar = NSView(frame: NSRect(x: 0, y: totalHeight - barHeight, width: totalWidth, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.16, alpha: 1).cgColor

        let doneButton = NSButton(title: "Done — I'm logged in", target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.frame = NSRect(x: 12, y: 8, width: 160, height: 28)

        let label = NSTextField(labelWithString: "Log into your Claude account, then click Done. No need to navigate anywhere else.")
        label.frame = NSRect(x: 182, y: 0, width: totalWidth - 194, height: barHeight)
        label.textColor = .white
        label.font = .systemFont(ofSize: 11)
        label.autoresizingMask = [.width]
        self.statusLabel = label

        bar.addSubview(doneButton)
        bar.addSubview(label)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        container.addSubview(webView)
        container.addSubview(bar)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Connect Claude Account"
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    @objc private func doneTapped() {
        window?.close()
        onDone?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel?.stringValue = "Log into your Claude account, then click Done. No need to navigate anywhere else."
    }
}
