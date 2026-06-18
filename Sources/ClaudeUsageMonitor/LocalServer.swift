import Network
import Foundation
import CoreImage
import AppKit
import WebKit

/// Minimal HTTP server (no third-party deps) so a phone on the same Wi-Fi
/// can load a live-updating dashboard. Read-only, LAN-only by nature (no
/// port forwarding set up), no auth — this mirrors what you'd already see
/// in the menu bar, just rendered for a browser.
final class LocalUsageServer {
    let port: UInt16 = 8731
    var statusProvider: (() -> [String: Any])?

    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort)
        else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var newBuffer = buffer
            if let data = data { newBuffer.append(data) }

            if let headerEnd = newBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = newBuffer[..<headerEnd.lowerBound]
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let firstLine = headerString.split(separator: "\r\n").first.map(String.init) ?? ""
                self.respond(to: firstLine, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: newBuffer)
        }
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"

        // Debug-only: lets us inspect the real claude.ai usage API schema
        // live, instead of guessing field names.
        if path == "/api/debug-usage-raw" {
            UsageAPI.fetchRawUsageJSON { result in
                let body: Data
                switch result {
                case .success(let json):
                    body = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])) ?? Data("{}".utf8)
                case .failure(let error):
                    body = Data("{\"error\": \(self.jsonStringLiteral(error.localizedDescription))}".utf8)
                }
                self.send(status: "200 OK", contentType: "application/json", body: body, on: connection)
            }
            return
        }

        // Debug-only: dump every cookie currently in the WKWebView's
        // persistent store (domain + name only, never values) so we can see
        // whether login is reaching our app's store at all, and if so, for
        // which domain.
        if path == "/api/debug-cookies" {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let list = cookies.map { ["domain": $0.domain, "name": $0.name, "expires": $0.expiresDate?.description ?? "session"] }
                let body = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])) ?? Data("[]".utf8)
                self.send(status: "200 OK", contentType: "application/json", body: body, on: connection)
            }
            return
        }

        var status = "200 OK"
        var contentType = "text/html; charset=utf-8"
        var body: Data

        switch path {
        case "/api/status":
            contentType = "application/json"
            let dict = statusProvider?() ?? [:]
            body = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        case "/":
            body = Data(dashboardHTML.utf8)
        default:
            status = "404 Not Found"
            body = Data("Not found".utf8)
        }

        send(status: status, contentType: contentType, body: body, on: connection)
    }

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(body)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func jsonStringLiteral(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let json = String(data: data, encoding: .utf8)!
        return String(json.dropFirst().dropLast())
    }
}

// MARK: - LAN IP discovery

func getLocalIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: interface.ifa_name)
        guard name == "en0" || name == "en1" else { continue }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
        address = String(cString: hostname)
        if name == "en0" { break }
    }
    return address
}

// MARK: - QR code (CoreImage, no dependency)

func generateQRCode(from string: String) -> NSImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

// MARK: - Dashboard page served to the phone

let dashboardHTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Usage</title>
<style>
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, 'SF Mono', monospace;
    background: linear-gradient(135deg, #0f0c29, #302b63, #0f0c29);
    background-size: 200% 200%;
    animation: drift 16s ease infinite;
    color: white;
  }
  @keyframes drift { 0%,100% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } }
  .card {
    width: min(440px, 90vw); padding: 36px; border-radius: 26px;
    background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08);
    backdrop-filter: blur(10px);
  }
  h1 { font-size: 18px; font-weight: 800; margin: 0 0 26px; display: flex; justify-content: space-between; align-items: center; }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: #5eead4; animation: pulse 1.4s infinite; }
  @keyframes pulse { 50% { opacity: .25; } }
  .gaugeWrap { position: relative; width: 210px; height: 210px; margin: 0 auto 26px; }
  svg { transform: rotate(-90deg); }
  #arc { transition: stroke-dashoffset 0.6s ease, stroke 0.6s ease; }
  .pct { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; }
  .pct .num { font-size: 46px; font-weight: 800; font-family: monospace; }
  .pct .label { font-size: 13px; opacity: .5; letter-spacing: .06em; margin-top: 3px; }
  .row { display: flex; justify-content: space-between; font-size: 14px; opacity: .7; margin-top: 11px; }
  .impact { font-weight: 700; font-family: monospace; color: #5eead4; }
  .insight {
    margin-top: 22px; padding: 14px; border-radius: 12px;
    background: rgba(255,255,255,0.05); border: 1px solid rgba(167,139,250,0.35);
    font-size: 13px; line-height: 1.45; display: none;
  }
</style>
</head>
<body>
<div class="card">
  <h1>Claude Usage <span class="dot"></span></h1>
  <div class="gaugeWrap">
    <svg width="210" height="210">
      <circle cx="105" cy="105" r="91" stroke="rgba(255,255,255,0.08)" stroke-width="15" fill="none"/>
      <circle id="arc" cx="105" cy="105" r="91" stroke="#5eead4" stroke-width="15" fill="none"
        stroke-linecap="round" stroke-dasharray="572" stroke-dashoffset="572"/>
    </svg>
    <div class="pct"><div class="num" id="pct">--%</div><div class="label">USED</div></div>
  </div>
  <div class="row"><span id="lastTurn">no turns yet</span><span class="impact" id="impact"></span></div>
  <div class="row"><span id="synced">not synced</span><span id="turns"></span></div>
  <div class="insight" id="insight"></div>
</div>
<script>
const circumference = 2 * Math.PI * 91;
function colorFor(p) {
  if (p < 50) return '#5eead4';
  if (p < 80) return '#fac158';
  return '#f55a66';
}
async function poll() {
  try {
    const r = await fetch('/api/status', { cache: 'no-store' });
    const d = await r.json();
    const p = Math.max(0, Math.min(100, d.percent || 0));
    document.getElementById('pct').textContent = Math.round(p) + '%';
    const arc = document.getElementById('arc');
    arc.setAttribute('stroke-dashoffset', circumference * (1 - p / 100));
    arc.setAttribute('stroke', colorFor(p));
    document.getElementById('lastTurn').textContent = d.lastTurnModel || 'no turns yet';
    document.getElementById('impact').textContent = (d.lastTurnImpact != null) ? ('+' + d.lastTurnImpact.toFixed(2) + '%') : '';
    document.getElementById('synced').textContent = d.lastScrapeRelative ? ('synced ' + d.lastScrapeRelative) : 'not synced';
    document.getElementById('turns').textContent = (d.turnCount || 0) + ' turns';
    const insightEl = document.getElementById('insight');
    if (d.topInsight) {
      insightEl.style.display = 'block';
      insightEl.textContent = d.topInsight;
    } else {
      insightEl.style.display = 'none';
    }
  } catch (e) {}
}
poll();
setInterval(poll, 1000);
</script>
</body>
</html>
"""
