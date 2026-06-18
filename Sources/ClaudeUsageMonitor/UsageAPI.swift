import WebKit
import Foundation

/// Calls the real (undocumented) Anthropic usage endpoint directly using
/// cookies captured at login time and persisted in our own file.
///
/// WKWebView's WKWebsiteDataStore.default() persistent cookie store does NOT
/// reliably survive a process relaunch for an ad-hoc-signed app with no real
/// Developer ID — confirmed empirically: even a plain quit+reopen with zero
/// rebuild wiped it. So WebKit's storage is only used transiently, during the
/// login window itself. The moment login succeeds we copy the cookies out
/// into our own JSON file, and every fetch after that reads from there —
/// plain file I/O has none of WebKit's cross-launch storage problems.
enum UsageAPI {
    struct SavedCookie: Codable {
        let name: String
        let value: String
        let domain: String
    }

    private static let cookieJarURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsageMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cookies.json")
    }()

    static func loadCookieJar() -> [SavedCookie] {
        guard let data = try? Data(contentsOf: cookieJarURL),
              let decoded = try? JSONDecoder().decode([SavedCookie].self, from: data)
        else { return [] }
        return decoded
    }

    private static func saveCookieJar(_ cookies: [SavedCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        try? data.write(to: cookieJarURL)
    }

    /// Call this once, right when the user finishes logging in (still while
    /// the WKWebView's cookies are live in memory) — copies them into our
    /// own durable storage.
    static func captureAndPersistCookies(completion: @escaping (Bool) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let claudeCookies = cookies.filter { $0.domain.contains("claude.ai") }
            guard !claudeCookies.isEmpty else {
                completion(false)
                return
            }
            let jar = claudeCookies.map { SavedCookie(name: $0.name, value: $0.value, domain: $0.domain) }
            saveCookieJar(jar)
            completion(true)
        }
    }

    static func fetchRawUsageJSON(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let jar = loadCookieJar()
        guard !jar.isEmpty else {
            completion(.failure(NSError(domain: "UsageAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "No saved session — connect your account first."])))
            return
        }
        guard let orgCookie = jar.first(where: { $0.name == "lastActiveOrg" }) else {
            let names = jar.map(\.name).joined(separator: ", ")
            completion(.failure(NSError(domain: "UsageAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "No lastActiveOrg cookie saved. Cookies present: \(names)"])))
            return
        }
        let orgId = orgCookie.value
        let cookieHeader = jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else {
            completion(.failure(NSError(domain: "UsageAPI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])))
            return
        }
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "UsageAPI", code: 4, userInfo: [NSLocalizedDescriptionKey: "No data"])))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
                completion(.failure(NSError(domain: "UsageAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(bodyStr.prefix(400))"])))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                completion(.failure(NSError(domain: "UsageAPI", code: 5, userInfo: [NSLocalizedDescriptionKey: "Non-JSON response: \(raw.prefix(400))"])))
                return
            }
            completion(.success(json))
        }.resume()
    }

    /// The API returns timestamps like "2026-06-18T03:39:59.404516+00:00" —
    /// microsecond precision, which `ISO8601DateFormatter` alone won't parse.
    static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        if let date = formatter.date(from: string) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: string)
    }
}
