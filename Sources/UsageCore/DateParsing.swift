import Foundation

/// Parses the timestamp strings that Anthropic's usage API returns — they use
/// microsecond precision ("2026-06-18T03:39:59.404516+00:00") which
/// ISO8601DateFormatter alone won't handle, so a DateFormatter with the right
/// format string is tried first, with ISO8601DateFormatter as fallback.
public func parseUsageDate(_ string: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
    if let date = formatter.date(from: string) { return date }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: string)
}
