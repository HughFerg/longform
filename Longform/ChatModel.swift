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
    case idle, listening, thinking, searching, speaking
    case error(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .searching: "Searching"
        case .speaking: "Speaking"
        case .error(let message): "Error: \(message)"
        }
    }

    /// A turn is in flight: the mic must stay shut and the trigger must not re-fire.
    var isBusy: Bool {
        switch self {
        case .thinking, .searching, .speaking: true
        default: false
        }
    }

    /// Anything that should outlast the screen's idle timer.
    var isActive: Bool { self != .idle && !isError }

    var isError: Bool { if case .error = self { true } else { false } }
}

@MainActor @Observable
final class ChatModel {
    var triggerPhrase = Preferences.triggerPhrase {
        didSet { Preferences.triggerPhrase = triggerPhrase }
    }
    var transcript = ""
    var messages: [Message] = []
    var status: Status = .idle
    var speechAvailable = true

    let transcriber = Transcriber()
    private let claude = ClaudeClient()
    private let speaker = Speaker()
    let neural = KokoroSpeaker(voice: Preferences.neuralVoice)

    /// Text carried over from earlier listening sessions. The live transcript is appended to it,
    /// so stopping to think — or being cut off entirely — never costs you what you already said.
    private var retained = ""

    /// Multiplier on the engine's natural pace, applied to whichever engine is speaking.
    var speakingRate = Preferences.speakingRate {
        didSet { Preferences.speakingRate = speakingRate }
    }

    /// Which engine speaks replies. Falls back to the system voice until the model is ready.
    var engine: VoiceEngine = Preferences.engine {
        didSet {
            Preferences.engine = engine
            guard engine == .neural else { return }
            Task { await neural.prepare() }
        }
    }

    /// Bindable passthrough so the picker can write to the engine's own property.
    var neuralVoice: String {
        get { neural.voice }
        set {
            neural.voice = newValue
            Preferences.neuralVoice = newValue
        }
    }

    private var voice: any VoiceOutput {
        engine == .neural && neural.isReady ? neural : speaker
    }
    let cost = CostTracker()
    let store = ConversationStore()

    /// Set when a turn ends, read when speech starts — the silence the user actually sits through.
    private var turnEnded: ContinuousClock.Instant?

    var isListening: Bool { status == .listening }
    var canSend: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init() {
        retained = Preferences.draft
        transcript = retained
        transcriber.onUpdate = { [weak self] text in self?.transcriptChanged(text) }
        #if os(iOS)
        AudioSession.observeRouteChanges()
        #endif
    }

    /// Warms the neural voice in the background. Nothing here gates the microphone: probing
    /// model availability at launch could hang, and `start()` already reports its own failures.
    func warmUp() {
        Log.speech.notice("launched")
        guard engine == .neural else { return }
        Task { await neural.prepare() }
    }

    /// Single entry point for transcript changes. The live text is appended to whatever was
    /// retained from a previous session, so one turn can span several stretches of listening.
    func transcriptChanged(_ live: String) {
        let combined = [retained, live].filter { !$0.isEmpty }.joined(separator: " ")
        transcript = combined
        Preferences.draft = combined

        guard !status.isBusy,
              let message = TriggerDetector.match(combined, trigger: triggerPhrase),
              !message.isEmpty
        else { return }

        let phrase = triggerPhrase
        Log.trigger.notice("matched \(phrase) in: \(combined)")
        status = .thinking  // set synchronously so later updates can't re-fire
        turnEnded = ContinuousClock().now
        Task { await send(message) }
    }

    /// Cuts off the spoken reply. `send` then falls through to resuming the mic as if it had finished.
    /// Reopens a past conversation. The whole history is sent on the next turn, so Claude
    /// picks up with the same context it had.
    func resume(_ conversation: StoredConversation) {
        messages = store.resume(conversation)
        discardDraft()
        status = .idle
        Log.api.notice("resumed \(self.messages.count) messages")
    }

    func startNewConversation() {
        store.startNew()
        messages = []
        discardDraft()
        status = .idle
    }

    /// Throws away the part-finished turn. The only way to clear it without sending it.
    func discardDraft() {
        retained = ""
        transcript = ""
        Preferences.draft = ""
    }

    func stopSpeaking() {
        voice.stop()
    }

    /// Serialises the mic transitions. Tapping the button faster than start/stop can complete
    /// otherwise overlaps them, which crashes the audio engine.
    private var isSwitching = false

    func toggleListening() async {
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }

        if isListening { await stopListening() } else { await startListening() }
    }

    func startListening() async {
        guard !isListening, !status.isBusy else { return }
        retained = transcript  // the new session's words land after what's already there
        status = .listening
        do {
            try await transcriber.start()
        } catch {
            Log.speech.error("start failed: \(error.localizedDescription)")
            if case TranscriberError.noModels = error { speechAvailable = false }
            status = .error(error.localizedDescription)
        }
    }

    func stopListening() async {
        await transcriber.stop()
        retained = transcript
        status = .idle
    }

    /// `override` carries the trigger-stripped message; otherwise the transcript is sent as-is.
    func send(_ override: String? = nil) async {
        await transcriber.stop()
        let text = (override ?? transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        discardDraft()
        messages.append(Message(role: .user, text: text))
        store.save(messages)
        status = .thinking

        var splitter = SentenceSplitter()
        var reply = ""
        let voice = self.voice
        voice.rate = speakingRate
        voice.reset()

        do {
            var usage = Usage()
            for try await event in claude.stream(messages) {
                guard case .text(let delta) = event else {
                    switch event {
                    case .usage(let tokens):
                        usage.inputTokens += tokens.inputTokens
                        usage.outputTokens += tokens.outputTokens
                        usage.searches += tokens.searches
                    case .searching:
                        if status == .thinking { status = .searching }
                    case .text: break
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
                    voice.enqueue(sentence)
                }
            }
            if let rest = splitter.flush() {
                if status != .speaking { status = .speaking }
                voice.enqueue(rest)
            }

            guard !reply.isEmpty else { throw ClaudeError.emptyReply }
            messages.append(Message(role: .assistant, text: reply))
            store.save(messages)
            Log.api.notice("reply \(reply.count) chars (you \(text.count))")
            cost.record(usage)

            await voice.finish()
            status = .idle
            await startListening()
        } catch {
            Log.api.error("\(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }
}
