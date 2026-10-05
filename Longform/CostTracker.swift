import Foundation
import Observation

/// Token counts returned by the API for one reply.
struct Usage: Sendable {
    var inputTokens = 0
    var outputTokens = 0
}

/// Running spend for this session. Nothing is persisted, so it resets when the app does.
@MainActor @Observable
final class CostTracker {
    // claude-sonnet-5-5, USD per million tokens.
    private static let inputRate = 2.0
    private static let outputRate = 10.0

    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var turns = 0

    var sessionCost: Double { cost(input: inputTokens, output: outputTokens) }

    var summary: String {
        sessionCost < 0.01
            ? String(format: "%.2f¢", sessionCost * 100)
            : String(format: "$%.3f", sessionCost)
    }

    func record(_ usage: Usage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        turns += 1

        let turnCost = cost(input: usage.inputTokens, output: usage.outputTokens)
        Log.cost.notice(
            "turn \(usage.inputTokens) in + \(usage.outputTokens) out = \(cents(turnCost)) | "
            + "session \(turns) turns, \(inputTokens) in + \(outputTokens) out = \(summary)"
        )
    }

    private func cost(input: Int, output: Int) -> Double {
        Double(input) / 1_000_000 * Self.inputRate + Double(output) / 1_000_000 * Self.outputRate
    }

    private func cents(_ amount: Double) -> String {
        String(format: "%.3f¢", amount * 100)
    }
}
