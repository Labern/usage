import XCTest
@testable import UsageCore

// MARK: - parseTurnUsage

final class ParseTurnUsageTests: XCTestCase {

    func testWellFormedLine_returnsTurnUsage() {
        let line = """
        {"type":"assistant","timestamp":"2026-06-18T10:00:00Z","message":{"id":"msg_abc","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":0}}}
        """
        let result = parseTurnUsage(fromLine: line, sessionPath: "/some/path.jsonl")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, "msg_abc")
        XCTAssertEqual(result?.model, "claude-sonnet-4-6")
        XCTAssertEqual(result?.inputTokens, 100)
        XCTAssertEqual(result?.outputTokens, 50)
        XCTAssertEqual(result?.cacheRead, 20)
        XCTAssertEqual(result?.cacheWrite5m, 0)
        XCTAssertEqual(result?.sessionPath, "/some/path.jsonl")
    }

    func testNonAssistantType_returnsNil() {
        let line = """
        {"type":"user","message":{"id":"msg_xyz","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0}}}
        """
        XCTAssertNil(parseTurnUsage(fromLine: line))
    }

    func testMalformedJSON_returnsNil() {
        XCTAssertNil(parseTurnUsage(fromLine: "not json at all"))
        XCTAssertNil(parseTurnUsage(fromLine: ""))
        XCTAssertNil(parseTurnUsage(fromLine: "{"))
    }

    func testMissingUsageBlock_returnsNil() {
        let line = """
        {"type":"assistant","message":{"id":"msg_abc","model":"claude-sonnet-4-6"}}
        """
        XCTAssertNil(parseTurnUsage(fromLine: line))
    }

    func testNestedCacheCreationShape() {
        // Newer API shape: cache_creation is a nested dict
        let line = """
        {"type":"assistant","message":{"id":"msg_new","model":"claude-haiku-4-5","usage":{"input_tokens":200,"output_tokens":80,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":500,"ephemeral_1h_input_tokens":300}}}}
        """
        let result = parseTurnUsage(fromLine: line)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cacheWrite5m, 500)
        XCTAssertEqual(result?.cacheWrite1h, 300)
    }

    func testLegacyFlatCacheCreationShape() {
        // Older API shape: cache_creation_input_tokens at top level of usage
        let line = """
        {"type":"assistant","message":{"id":"msg_old","model":"claude-opus-4-8","usage":{"input_tokens":300,"output_tokens":120,"cache_read_input_tokens":0,"cache_creation_input_tokens":400}}}
        """
        let result = parseTurnUsage(fromLine: line)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cacheWrite5m, 400)
        XCTAssertEqual(result?.cacheWrite1h, 0)
    }

    func testMissingTimestamp_fallsBackWithoutCrash() {
        // No "timestamp" key in the line — should still parse, timestamp ~= now
        let before = Date()
        let line = """
        {"type":"assistant","message":{"id":"msg_no_ts","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0}}}
        """
        let result = parseTurnUsage(fromLine: line)
        let after = Date()
        XCTAssertNotNil(result)
        // Timestamp should be between before and after (i.e., Date() fallback)
        XCTAssertGreaterThanOrEqual(result!.timestamp, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(result!.timestamp, after.addingTimeInterval(1))
    }
}

// MARK: - TurnUsage.weightedCost / freshTokens

final class TurnUsageCostTests: XCTestCase {

    private func makeTurn(model: String, input: Int, output: Int,
                          write5m: Int = 0, write1h: Int = 0, cacheRead: Int = 0) -> TurnUsage {
        TurnUsage(id: "x", sessionPath: "", model: model,
                  inputTokens: input, outputTokens: output,
                  cacheWrite5m: write5m, cacheWrite1h: write1h,
                  cacheRead: cacheRead, timestamp: Date())
    }

    func testWeightedCost_sonnet_knownValues() {
        // sonnet-4-6: $3/M input, $15/M output
        let turn = makeTurn(model: "claude-sonnet-4-6", input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(turn.weightedCost, 18.0, accuracy: 0.001)
    }

    func testWeightedCost_unknownModel_isZero() {
        let turn = makeTurn(model: "claude-unknown-99", input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(turn.weightedCost, 0.0)
    }

    func testWeightedCost_cacheReadIsCharged() {
        // cache read is 10% of input price; $3/M * 0.1 = $0.3/M
        let turn = makeTurn(model: "claude-sonnet-4-6", input: 0, output: 0, cacheRead: 1_000_000)
        XCTAssertEqual(turn.weightedCost, 0.3, accuracy: 0.001)
    }

    func testFreshTokens_includesInputAndBothCacheWrites() {
        let turn = makeTurn(model: "claude-sonnet-4-6", input: 100, output: 50,
                            write5m: 200, write1h: 300, cacheRead: 999)
        // freshTokens = input + cacheWrite5m + cacheWrite1h, NOT cacheRead
        XCTAssertEqual(turn.freshTokens, 600)
    }

    func testFreshTokens_excludesCacheRead() {
        let turn = makeTurn(model: "claude-sonnet-4-6", input: 0, output: 0,
                            write5m: 0, write1h: 0, cacheRead: 1000)
        XCTAssertEqual(turn.freshTokens, 0)
    }
}

// MARK: - turnPercentImpact

final class TurnPercentImpactTests: XCTestCase {

    private let baseDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testSameWindow_percentIncreased_returnsDelta() {
        let previous = baseDate
        let newDate = baseDate.addingTimeInterval(2) // within 120s tolerance
        let result = turnPercentImpact(
            previousPercent: 50.0, previousResetsAt: previous,
            newPercent: 51.5, newResetsAt: newDate
        )
        XCTAssertEqual(try XCTUnwrap(result), 1.5, accuracy: 0.0001)
    }

    func testDifferentWindow_largeJump_returnsNil() {
        let previous = baseDate
        let newDate = baseDate.addingTimeInterval(5 * 3600) // 5h jump = real reset
        let result = turnPercentImpact(
            previousPercent: 80.0, previousResetsAt: previous,
            newPercent: 5.0, newResetsAt: newDate
        )
        XCTAssertNil(result)
    }

    func testPercentDecreased_sameWindow_returnsNil() {
        let previous = baseDate
        let newDate = baseDate.addingTimeInterval(1)
        let result = turnPercentImpact(
            previousPercent: 60.0, previousResetsAt: previous,
            newPercent: 59.0, newResetsAt: newDate
        )
        XCTAssertNil(result)
    }

    func testNoPreviousPercent_returnsNil() {
        let result = turnPercentImpact(
            previousPercent: nil, previousResetsAt: baseDate,
            newPercent: 10.0, newResetsAt: baseDate
        )
        XCTAssertNil(result)
    }

    func testBothResetsNil_returnsNil() {
        // Can't establish sameWindow if either date is nil
        let result = turnPercentImpact(
            previousPercent: 20.0, previousResetsAt: nil,
            newPercent: 21.0, newResetsAt: nil
        )
        XCTAssertNil(result)
    }

    func testExactSamePercent_returnsZero() {
        // >= means exactly equal passes (delta = 0)
        let result = turnPercentImpact(
            previousPercent: 30.0, previousResetsAt: baseDate,
            newPercent: 30.0, newResetsAt: baseDate
        )
        XCTAssertEqual(try XCTUnwrap(result), 0.0, accuracy: 0.0001)
    }
}

// MARK: - parseUsageDate

final class ParseUsageDateTests: XCTestCase {

    func testMicrosecondPrecision_parses() {
        // The format Anthropic actually returns
        let result = parseUsageDate("2026-06-18T03:39:59.404516+00:00")
        XCTAssertNotNil(result)
        // Check it lands in the right ballpark: 2026-06-18
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: result!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 18)
    }

    func testStandardISO8601WithFractionalSeconds_parses() {
        let result = parseUsageDate("2026-06-18T12:00:00.000Z")
        XCTAssertNotNil(result)
    }

    func testGarbageString_returnsNil() {
        XCTAssertNil(parseUsageDate("not a date"))
        XCTAssertNil(parseUsageDate(""))
        XCTAssertNil(parseUsageDate("2026-99-99"))
    }
}

// MARK: - sessionRunOutEstimate

final class SessionRunOutEstimateTests: XCTestCase {

    func testNilPercent_returnsNil() {
        XCTAssertNil(sessionRunOutEstimate(percent: nil, resetsAt: Date().addingTimeInterval(3600)))
    }

    func testZeroPercent_returnsNil() {
        XCTAssertNil(sessionRunOutEstimate(percent: 0, resetsAt: Date().addingTimeInterval(3600)))
    }

    func testNilResetsAt_returnsNil() {
        XCTAssertNil(sessionRunOutEstimate(percent: 50, resetsAt: nil))
    }

    func testPaceOutlastsReset_returnsNil() {
        // Session started 4h ago (so 1h remains). Used only 1% over 4h → rate = 0.25%/h.
        // At that rate, 99% remaining → ~396h to run out. Comfortably after the reset → nil.
        let resetsAt = Date().addingTimeInterval(3600) // 1h from now
        let result = sessionRunOutEstimate(percent: 1.0, resetsAt: resetsAt)
        XCTAssertNil(result)
    }

    func testPaceRunsOutBeforeReset_returnsDateBeforeReset() {
        // Session started 4h ago (resetsAt = now + 1h). Used 95% in 4h → rate ~23.75%/h.
        // 5% remaining → ~12.6 minutes. Well before the 1h-away reset.
        let resetsAt = Date().addingTimeInterval(3600)
        let result = sessionRunOutEstimate(percent: 95.0, resetsAt: resetsAt)
        XCTAssertNotNil(result)
        XCTAssertLessThan(result!, resetsAt)
        XCTAssertGreaterThan(result!, Date())
    }
}

// MARK: - generateInsights

final class GenerateInsightsTests: XCTestCase {

    private func makeSession(label: String, turnCount: Int, cost: Double,
                             freshTokens: Int, cacheReadTokens: Int,
                             daysAgo: Double = 0) -> SessionSummary {
        let last = Date().addingTimeInterval(-daysAgo * 86400)
        let first = last.addingTimeInterval(-3600)
        return SessionSummary(
            id: label, label: label, turnCount: turnCount,
            totalWeightedCost: cost, freshTokens: freshTokens,
            cacheReadTokens: cacheReadTokens, firstTimestamp: first, lastTimestamp: last
        )
    }

    func testNothingUnusual_returnsGoodFallback() {
        // Uniform sessions with no rule triggers
        let sessions = (0..<5).map { i in
            makeSession(label: "proj\(i)", turnCount: 5, cost: 0.01,
                        freshTokens: 1000, cacheReadTokens: 3000, daysAgo: Double(i))
        }
        let insights = generateInsights(sessions: sessions, weeklyPercent: nil)
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights[0].tone, .good)
    }

    func testBusiestConversation_firesWhenOneSessionDominatesTurnCount() {
        let heavy = makeSession(label: "heavy", turnCount: 50, cost: 0.05,
                                freshTokens: 5000, cacheReadTokens: 1000)
        let others = (0..<9).map { i in
            makeSession(label: "light\(i)", turnCount: 5, cost: 0.01,
                        freshTokens: 500, cacheReadTokens: 500, daysAgo: Double(i + 1))
        }
        let insights = generateInsights(sessions: [heavy] + others, weeklyPercent: nil)
        XCTAssert(insights.contains { $0.icon == "💬" }, "Expected busiest-conversation insight")
    }

    func testCostConcentration_firesWhenOneDominatesCost() {
        let expensive = makeSession(label: "expensive", turnCount: 5, cost: 1.0,
                                    freshTokens: 1000, cacheReadTokens: 1000)
        let cheap = makeSession(label: "cheap", turnCount: 5, cost: 0.01,
                                freshTokens: 100, cacheReadTokens: 100, daysAgo: 1)
        let insights = generateInsights(sessions: [expensive, cheap], weeklyPercent: nil)
        XCTAssert(insights.contains { $0.icon == "📊" }, "Expected cost-concentration insight")
    }

    func testLowCacheReuse_firesWhenRatioBelow25Percent() {
        // freshTokens >> cacheReadTokens → very low cache ratio
        let session = makeSession(label: "proj", turnCount: 10, cost: 0.1,
                                  freshTokens: 10000, cacheReadTokens: 100)
        let insights = generateInsights(sessions: [session], weeklyPercent: nil)
        XCTAssert(insights.contains { $0.icon == "♻️" }, "Expected low-cache-reuse insight")
    }

    func testRisingCostPerTurn_firesWhenRecentIsUp30Percent() {
        // 6 sessions: first 3 (recent) have high cost/turn, next 3 (prior) are cheap
        let recent = (0..<3).map { i in
            makeSession(label: "r\(i)", turnCount: 5, cost: 1.0,
                        freshTokens: 1000, cacheReadTokens: 1000, daysAgo: Double(i))
        }
        let prior = (0..<3).map { i in
            makeSession(label: "p\(i)", turnCount: 5, cost: 0.1,
                        freshTokens: 100, cacheReadTokens: 100, daysAgo: Double(i + 3))
        }
        let insights = generateInsights(sessions: recent + prior, weeklyPercent: nil)
        XCTAssert(insights.contains { $0.icon == "⚠️" }, "Expected rising-cost-per-turn insight")
    }

    func testWeeklyPercent_appearsAsInfoInsight() {
        let sessions = [makeSession(label: "proj", turnCount: 5, cost: 0.01,
                                    freshTokens: 1000, cacheReadTokens: 3000)]
        let insights = generateInsights(sessions: sessions, weeklyPercent: 42.0)
        XCTAssert(insights.contains { $0.icon == "📈" }, "Expected weekly-percent insight")
    }

    func testWeeklyPercent_isWarningAbove75() {
        let sessions = [makeSession(label: "proj", turnCount: 5, cost: 0.01,
                                    freshTokens: 1000, cacheReadTokens: 3000)]
        let insights = generateInsights(sessions: sessions, weeklyPercent: 80.0)
        let weekly = insights.first { $0.icon == "📈" }
        XCTAssertEqual(weekly?.tone, .warning)
    }
}

// MARK: - humanizeProjectLabel

final class HumanizeProjectLabelTests: XCTestCase {

    func testHomeDirectory_collapsesToTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Build the directory-name form: replace "/" with "-" and strip leading "/"
        let dirName = home.replacingOccurrences(of: "/", with: "-")
        let result = humanizeProjectLabel(fromDirectoryName: dirName + "-Desktop-Clean")
        XCTAssert(result.hasPrefix("~/"), "Expected tilde-collapsed path, got: \(result)")
        XCTAssert(result.contains("Desktop/Clean"), "Expected Desktop/Clean in path, got: \(result)")
    }

    func testNonHomePath_expandsToSlash() {
        let result = humanizeProjectLabel(fromDirectoryName: "-tmp-myproject")
        XCTAssertEqual(result, "/tmp/myproject")
    }
}

// MARK: - targetWindowX (window positioning geometry)

final class TargetWindowXTests: XCTestCase {

    private let anchor = NSRect(x: 1200, y: 800, width: 400, height: 600)
    private let screen = NSRect(x: 0, y: 0, width: 1800, height: 1200)

    func testLeftSide_placesWindowToLeftOfAnchor() {
        let x = targetWindowX(windowWidth: 300, anchorFrame: anchor, side: .left, screenVisibleFrame: screen)
        // Expected: anchor.minX - windowWidth - 14 = 1200 - 300 - 14 = 886
        XCTAssertEqual(x, 886, accuracy: 0.5)
    }

    func testRightSide_placesWindowToRightOfAnchor() {
        // Use a wider screen so the 300pt window fits at 1614 without clamping
        let wideScreen = NSRect(x: 0, y: 0, width: 3000, height: 1200)
        let x = targetWindowX(windowWidth: 300, anchorFrame: anchor, side: .right, screenVisibleFrame: wideScreen)
        // Expected: anchor.maxX + 14 = 1600 + 14 = 1614 (fits, no clamp)
        XCTAssertEqual(x, 1614, accuracy: 0.5)
    }

    func testClampsToScreenRight_whenWindowWouldOverflow() {
        // A very wide window on the right would go off-screen
        let x = targetWindowX(windowWidth: 500, anchorFrame: anchor, side: .right, screenVisibleFrame: screen)
        // anchor.maxX + 14 = 1614; window end = 1614 + 500 = 2114 > screen.maxX 1800
        // So clamped: maxX - windowWidth = 1800 - 500 = 1300
        XCTAssertEqual(x, 1300, accuracy: 0.5)
    }

    func testClampsToScreenLeft_whenWindowWouldGoOffLeft() {
        // Anchor very close to left edge, trying to open left
        let leftAnchor = NSRect(x: 50, y: 800, width: 100, height: 200)
        let x = targetWindowX(windowWidth: 300, anchorFrame: leftAnchor, side: .left, screenVisibleFrame: screen)
        // anchor.minX - 300 - 14 = 50 - 314 = -264; clamped to screen.minX = 0
        XCTAssertEqual(x, 0, accuracy: 0.5)
    }
}
