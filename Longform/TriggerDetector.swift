import Foundation

/// Decides when a spoken turn is over: the normalized text must END with the normalized trigger.
enum TriggerDetector {
    /// A phrase longer than this isn't a trigger, and bounds the work done on every update.
    private static let maximumTriggerWords = 12

    /// Lowercase, drop punctuation, collapse whitespace.
    ///
    /// Apostrophes are deleted rather than treated as separators, so "that's" becomes "thats" and
    /// the phrase can be typed either way. Everything else splits words, so "send-it" matches "send it".
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The message with the trigger stripped, or nil when `text` doesn't end with it.
    ///
    /// Matching is done on normalized forms, so the phrase in the text field can be typed with any
    /// capitalization or punctuation — "Send it!", "send it", "SEND IT." all behave the same.
    /// Trailing words are removed from the ORIGINAL text, so its own punctuation and casing survive.
    static func match(_ text: String, trigger: String) -> String? {
        let trigger = normalize(trigger)
        guard !trigger.isEmpty else { return nil }

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return nil }

        // Grow the candidate suffix a word at a time and compare normalized forms. Counting words
        // on the normalized trigger instead would over-strip, since normalizing can split a word
        // ("that's" becomes "that s") and the counts stop lining up.
        for count in 1...min(words.count, maximumTriggerWords) where normalize(words.suffix(count).joined(separator: " ")) == trigger {
            return words.dropLast(count).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
