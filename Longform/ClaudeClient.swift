import Foundation
import OSLog

enum ClaudeError: LocalizedError {
    case missingKey
    case api(String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your API key to Secrets.swift."
        case .api(let message): message
        case .emptyReply: "Claude returned no text."
        }
    }
}

private let systemPrompt = """
You are in a spoken conversation. They hear you; they never read you.

Two or three sentences. Keep sentences under twenty words. Ask one question or none. Go longer only when they ask you to.

Never validate. No "great question", no "that makes sense", no "you're right to think about that", no telling them an idea is interesting or smart. Start with the substance.

Say the useful thing and stop. Give one recommendation, not a menu. Don't restate their question, don't preface, don't summarise yourself, don't offer to expand.

Plain words. No metaphors, no "dive into", "unpack", "landscape", "journey", "at the end of the day". No markdown, no lists, no headings; none of it survives being spoken.

You can search the web. Use it when the answer turns on something current, specific or checkable. Say "let me look" once at the start and then nothing until you have the answer; no running commentary between searches. Name sources the way you'd say them aloud — "the Verge", "their docs" — never read a URL out.

They think out loud, trail off, and change direction. If there's no question in what they said, don't invent one to answer. A short acknowledgement is a complete turn.

Sounds like:
"Probably the design. Same two files every time means the seams are wrong."
"Yeah, that'd work."
"What was the other thing you mentioned?"
"""

/// Anthropic runs this one server-side: the model issues the query, the results never touch
/// the app. Dated name is the tool version, not an expiry.
private struct WebSearchTool: Encodable {
    let type = "web_search_20260209"
    let name = "web_search"
    let maxUses = 3

    enum CodingKeys: String, CodingKey {
        case type, name
        case maxUses = "max_uses"
    }
}

private struct RequestBody: Encodable {
    struct Turn: Encodable {
        let role: String
        let content: String
    }

    let model = "claude-sonnet-5-5"
    let maxTokens = 1024
    let system = systemPrompt
    let messages: [Turn]
    let stream = true
    let tools = [WebSearchTool()]
    /// Thinking before the first word is pure dead air in a voice loop. `between_tools` keeps it
    /// for the one place it earns its keep: deciding what to do with search results.
    let thinking = ["type": "between_tools"]

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream, thinking, tools
        case maxTokens = "max_tokens"
    }
}

/// What the stream hands back: spoken text, the token counts that arrive with it, and a nudge
/// when the model goes off to search so the UI can say so.
enum ReplyEvent: Sendable {
    case text(String)
    case usage(Usage)
    case searching
}

/// Server-sent event. `text_delta` carries spoken content; token counts arrive on
/// `message_start` (input) and `message_delta` (output).
private struct StreamEvent: Decodable {
    struct Delta: Decodable {
        let text: String?
    }

    struct Failure: Decodable {
        let message: String
    }

    struct Tokens: Decodable {
        struct ServerTools: Decodable {
            let webSearchRequests: Int?

            enum CodingKeys: String, CodingKey {
                case webSearchRequests = "web_search_requests"
            }
        }

        let inputTokens: Int?
        let outputTokens: Int?
        let serverToolUse: ServerTools?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case serverToolUse = "server_tool_use"
        }
    }

    struct Envelope: Decodable {
        let usage: Tokens?
    }

    struct Block: Decodable {
        let type: String
    }

    let type: String
    let delta: Delta?
    let error: Failure?
    let usage: Tokens?
    let message: Envelope?
    let contentBlock: Block?

    enum CodingKeys: String, CodingKey {
        case type, delta, error, usage, message
        case contentBlock = "content_block"
    }
}

private struct ErrorBody: Decodable {
    struct Detail: Decodable {
        let message: String
    }

    let error: Detail
}

struct ClaudeClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Streams the reply as it is generated, so speech can start on the first sentence
    /// instead of waiting for the whole response. Sends the full conversation each turn.
    func stream(_ history: [Message]) -> AsyncThrowingStream<ReplyEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !Secrets.anthropicKey.isEmpty else { throw ClaudeError.missingKey }

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue(Secrets.anthropicKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let turns = history.map { RequestBody.Turn(role: $0.role.rawValue, content: $0.text) }
                    request.httpBody = try JSONEncoder().encode(RequestBody(messages: turns))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClaudeError.api("No response from server.")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        let detail = try? JSONDecoder().decode(ErrorBody.self, from: Data(body.utf8))
                        throw ClaudeError.api(detail?.error.message ?? "HTTP \(http.statusCode)")
                    }

                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        let payload = Data(line.dropFirst(6).utf8)
                        guard let event = try? JSONDecoder().decode(StreamEvent.self, from: payload) else { continue }
                        if let message = event.error?.message { throw ClaudeError.api(message) }
                        if let text = event.delta?.text, !text.isEmpty { continuation.yield(.text(text)) }
                        if event.contentBlock?.type == "server_tool_use" { continuation.yield(.searching) }
                        if let tokens = event.message?.usage ?? event.usage {
                            continuation.yield(.usage(Usage(
                                inputTokens: tokens.inputTokens ?? 0,
                                outputTokens: tokens.outputTokens ?? 0,
                                searches: tokens.serverToolUse?.webSearchRequests ?? 0
                            )))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
