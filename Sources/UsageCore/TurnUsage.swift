import Foundation

// MARK: - Per-model pricing (per million tokens)

public struct ModelPricing {
    public let input: Double
    public let output: Double
    public init(input: Double, output: Double) { self.input = input; self.output = output }
}

public let pricingTable: [String: ModelPricing] = [
    "claude-sonnet-4-6": ModelPricing(input: 3.00, output: 15.00),
    "claude-opus-4-8":   ModelPricing(input: 5.00, output: 25.00),
    "claude-haiku-4-5":  ModelPricing(input: 1.00, output: 5.00),
    "claude-fable-5":    ModelPricing(input: 10.00, output: 50.00),
]
public let cacheWrite5mMultiplier = 1.25
public let cacheWrite1hMultiplier = 2.0
public let cacheReadMultiplier = 0.1

/// Fallback pricing by model family, for versions not yet in `pricingTable`
/// (e.g. a brand-new "claude-opus-4-9"). Without this, an unlisted model
/// prices at zero and its turns silently vanish from calibration, insights,
/// and turn-history shares. Models with no recognizable family (including
/// "<synthetic>") still price at zero.
public let familyPricingTable: [String: ModelPricing] = [
    "opus":   ModelPricing(input: 5.00, output: 25.00),
    "sonnet": ModelPricing(input: 3.00, output: 15.00),
    "haiku":  ModelPricing(input: 1.00, output: 5.00),
    "fable":  ModelPricing(input: 10.00, output: 50.00),
]

public struct TurnUsage: Identifiable {
    public let id: String
    public let sessionPath: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int
    public let cacheRead: Int
    public let timestamp: Date

    public init(id: String, sessionPath: String, model: String, inputTokens: Int,
                outputTokens: Int, cacheWrite5m: Int, cacheWrite1h: Int,
                cacheRead: Int, timestamp: Date) {
        self.id = id; self.sessionPath = sessionPath; self.model = model
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead; self.timestamp = timestamp
    }

    public var pricing: ModelPricing {
        if let exact = pricingTable[model] { return exact }
        let lower = model.lowercased()
        for (family, price) in familyPricingTable where lower.contains(family) {
            return price
        }
        return ModelPricing(input: 0, output: 0)
    }

    public var weightedCost: Double {
        let i = Double(inputTokens) * pricing.input
        let o = Double(outputTokens) * pricing.output
        let w5 = Double(cacheWrite5m) * pricing.input * cacheWrite5mMultiplier
        let w1 = Double(cacheWrite1h) * pricing.input * cacheWrite1hMultiplier
        let r = Double(cacheRead) * pricing.input * cacheReadMultiplier
        return (i + o + w5 + w1 + r) / 1_000_000
    }

    public var freshTokens: Int { inputTokens + cacheWrite5m + cacheWrite1h }
}

/// Parses one JSONL transcript line into a TurnUsage, if it's an assistant
/// message carrying a `usage` block. Shared by live tailing and full-history
/// analysis (Insights) so both read usage data identically.
public func parseTurnUsage(fromLine line: String, sessionPath: String = "") -> TurnUsage? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (obj["type"] as? String) == "assistant",
          let message = obj["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any],
          let id = message["id"] as? String,
          let model = message["model"] as? String
    else { return nil }

    let inputTokens = usage["input_tokens"] as? Int ?? 0
    let outputTokens = usage["output_tokens"] as? Int ?? 0
    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    if let creation = usage["cache_creation"] as? [String: Any] {
        cacheWrite5m = creation["ephemeral_5m_input_tokens"] as? Int ?? 0
        cacheWrite1h = creation["ephemeral_1h_input_tokens"] as? Int ?? 0
    } else {
        cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
    }

    var timestamp = Date()
    if let tsString = obj["timestamp"] as? String,
       let parsed = parseUsageDate(tsString) {
        timestamp = parsed
    }

    return TurnUsage(
        id: id, sessionPath: sessionPath, model: model,
        inputTokens: inputTokens, outputTokens: outputTokens,
        cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h, cacheRead: cacheRead,
        timestamp: timestamp
    )
}

/// Returns the % delta between two consecutive usage fetches, but only if:
/// (a) both fetches are for the same 5-hour session window (resets_at within
///     120s of each other — the API drifts ~1s per call, a real reset jumps 5h),
/// (b) percent actually increased (a decrease means the session reset mid-flight).
/// Returns nil in any other case.
public func turnPercentImpact(
    previousPercent: Double?,
    previousResetsAt: Date?,
    newPercent: Double,
    newResetsAt: Date?
) -> Double? {
    var sameWindow = false
    if let oldResets = previousResetsAt, let newResets = newResetsAt {
        sameWindow = abs(oldResets.timeIntervalSince(newResets)) < 120
    }
    guard let previous = previousPercent, sameWindow, newPercent >= previous else { return nil }
    return newPercent - previous
}
