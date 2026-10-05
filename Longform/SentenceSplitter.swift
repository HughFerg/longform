import Foundation

/// Carves complete sentences out of a growing stream of text so each can be spoken
/// as soon as it lands, instead of waiting for the whole reply.
struct SentenceSplitter {
    /// Short fragments are held back — speaking "Sure." on its own sounds clipped.
    private let minimumLength = 12
    private var buffer = ""

    mutating func append(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let sentence = takeSentence() { sentences.append(sentence) }
        return sentences
    }

    /// Whatever is left once the stream ends.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private mutating func takeSentence() -> String? {
        var index = buffer.startIndex
        while let end = buffer[index...].firstIndex(where: { ".!?\n".contains($0) }) {
            let after = buffer.index(after: end)
            // Whitespace must follow, which rules out "3.5".
            guard after < buffer.endIndex else { return nil }
            guard buffer[after].isWhitespace else {
                index = after
                continue
            }
            // And the next sentence must actually start, which rules out "e.g. five dollars".
            // If nothing follows yet, wait for more of the stream rather than guessing.
            var next = after
            while next < buffer.endIndex, buffer[next].isWhitespace {
                next = buffer.index(after: next)
            }
            guard next < buffer.endIndex else { return nil }
            guard buffer[next].isUppercase || buffer[next].isNumber else {
                index = after
                continue
            }
            let sentence = String(buffer[..<after]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count >= minimumLength else {
                index = after
                continue
            }
            buffer = String(buffer[after...])
            return sentence
        }
        return nil
    }
}
