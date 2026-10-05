import Foundation
import OSLog
import Observation

enum Role: String {
    case user, assistant
}

struct Message: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
}

enum Status: Equatable {
    case idle, listening, thinking, speaking
    case error(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .error(let message): "Error: \(message)"
        }
    }
}

@MainActor @Observable
final class ChatModel {
    var triggerPhrase = "send it"
    var transcript = ""
    var messages: [Message] = []
    var status: Status = .idle
    var speechAvailable = true

    let transcriber = Transcriber()
    private let claude = ClaudeClient()
    private let speaker = Speaker()
    let cost = CostTracker()

    /// Surfaced in the UI so a compact voice doesn't silently sound terrible.
    var usingBasicVoice: Bool { speaker.usingBasicVoice }

    /// Set when a turn ends, read when speech starts — the silence the user actually sits through.
    private var turnEnded: ContinuousClock.Instant?

    var isListening: Bool { status == .listening }
    var canSend: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init() {
        transcriber.onUpdate = { [weak self] text in self?.transcriptChanged(text) }
    }

    func checkSpeechAvailability() async {
        speechAvailable = await Transcriber.isSupported
    }

    /// Single entry point for transcript changes, from the mic or from typing.
    /// Typing counts too, so the trigger works in the Simulator, which has no speech models.
    func transcriptChanged(_ text: String) {
        transcript = text
        guard status != .thinking, status != .speaking,
              let message = TriggerDetector.match(text, trigger: triggerPhrase),
              !message.isEmpty
        else { return }

        let phrase = triggerPhrase
        Log.trigger.notice("matched \(phrase) in: \(text)")
        status = .thinking  // set synchronously so later updates can't re-fire
        turnEnded = ContinuousClock().now
        Task { await send(message) }
    }

    /// Cuts off the spoken reply. `send` then falls through to resuming the mic as if it had finished.
    func stopSpeaking() {
        speaker.stop()
    }

    func toggleListening() async {
        if isListening { await stopListening() } else { await startListening() }
    }

    func startListening() async {
        guard speechAvailable, !isListening else { return }
        transcript = ""
        status = .listening
        do {
            try await transcriber.start()
        } catch {
            Log.speech.error("start failed: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    func stopListening() async {
        await transcriber.stop()
        status = .idle
    }

    /// `override` carries the trigger-stripped message; otherwise the transcript is sent as-is.
    func send(_ override: String? = nil) async {
        await transcriber.stop()
        let text = (override ?? transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        transcript = ""
        messages.append(Message(role: .user, text: text))
        status = .thinking

        var splitter = SentenceSplitter()
        var reply = ""
        speaker.reset()

        do {
            var usage = Usage()
            for try await event in claude.stream(messages) {
                guard case .text(let delta) = event else {
                    if case .usage(let tokens) = event {
                        usage.inputTokens += tokens.inputTokens
                        usage.outputTokens += tokens.outputTokens
                    }
                    continue
                }
                reply += delta
                for sentence in splitter.append(delta) {
                    if status != .speaking {
                        status = .speaking
                        if let turnEnded {
                            Log.api.notice("dead air \(ContinuousClock().now - turnEnded) to first audio")
                            self.turnEnded = nil
                        }
                    }
                    speaker.enqueue(sentence)
                }
            }
            if let rest = splitter.flush() {
                if status != .speaking { status = .speaking }
                speaker.enqueue(rest)
            }

            guard !reply.isEmpty else { throw ClaudeError.emptyReply }
            messages.append(Message(role: .assistant, text: reply))
            Log.api.notice("reply \(reply.count) chars (you \(text.count))")
            cost.record(usage)

            await speaker.finish()
            status = .idle
            await startListening()
        } catch {
            Log.api.error("\(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }
}
