import AVFoundation
import OSLog

/// Speaks a reply and returns only when it has finished, so the caller can resume the mic safely.
@MainActor
final class Speaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var drained: CheckedContinuation<Void, Never>?
    private var queued = 0
    private var inputFinished = false
    private var cancelled = false

    /// True when only a compact voice is installed — the robotic, "voicemail" sound.
    /// Premium voices are a one-time user download in Settings; the app can't install them.
    var usingBasicVoice: Bool { (voice?.quality ?? .default) == .default }

    private lazy var voice: AVSpeechSynthesisVoice? = {
        let chosen = Self.bestVoice()
        Log.speech.notice("voice: \(chosen?.name ?? "system default") (quality \(chosen?.quality.rawValue ?? 0))")
        return chosen
    }()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Picks the best-sounding installed voice: premium > enhanced > compact, preferring the local region.
    /// Novelty and legacy voices (Bells, Zarvox, Eloquence…) are excluded.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier

        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language)
                && !$0.identifier.contains("com.apple.speech.synthesis.voice")
                && !$0.identifier.contains("com.apple.eloquence")
        }
        return candidates.max {
            ($0.quality.rawValue, $0.language.hasSuffix(region ?? "") ? 1 : 0)
                < ($1.quality.rawValue, $1.language.hasSuffix(region ?? "") ? 1 : 0)
        }
    }

    /// Queues a sentence. Utterances play back to back, so the reply can start speaking
    /// before the rest of it has arrived.
    func enqueue(_ text: String) {
        guard !cancelled else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        #endif

        queued += 1
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95  // a touch slower reads as less clipped
        synthesizer.speak(utterance)
    }

    /// Waits for everything queued so far to finish. Call once the reply has fully arrived.
    func finish() async {
        inputFinished = true
        guard queued > 0, !cancelled else { return }
        await withCheckedContinuation { drained = $0 }
    }

    /// Cuts the reply off mid-sentence and discards whatever is still queued.
    func stop() {
        guard !cancelled else { return }
        cancelled = true
        Log.speech.notice("interrupted by user")
        synthesizer.stopSpeaking(at: .immediate)
        drained?.resume()
        drained = nil
    }

    /// Readies the speaker for the next reply.
    func reset() {
        cancelled = false
        inputFinished = false
        queued = 0
    }

    fileprivate func complete() {
        queued -= 1
        guard queued == 0, inputFinished else { return }
        drained?.resume()
        drained = nil
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in complete() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in complete() }
    }
}
