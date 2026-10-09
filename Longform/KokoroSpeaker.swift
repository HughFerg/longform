import AVFoundation
import FluidAudio
import Foundation
import Observation
import OSLog

/// On-device neural speech via Kokoro, running on the Neural Engine.
///
/// The model is ~100MB and downloads on first use, so `prepare()` runs in the background and
/// `isReady` stays false until it lands. The caller falls back to the system voice until then.
@MainActor @Observable
final class KokoroSpeaker: NSObject, VoiceOutput {
    var rate = 1.0
    private(set) var isReady = false
    private(set) var isPreparing = false

    var voice: String {
        didSet { Log.speech.notice("neural voice set to \(self.voice)") }
    }

    private var manager: KokoroAneManager?
    private var player: AVAudioPlayer?
    private var pending: [String] = []
    private var playback: Task<Void, Never>?
    private var finished: CheckedContinuation<Void, Never>?
    private var playedOut: CheckedContinuation<Void, Never>?
    private var cancelled = false

    static let voices = KokoroAneConstants.englishVoices.map(NeuralVoice.init)

    init(voice: String? = nil) {
        self.voice = voice ?? KokoroAneConstants.defaultVoice
        super.init()
    }

    /// Downloads and loads the model. Safe to call repeatedly; only the first call does work.
    func prepare() async {
        guard manager == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        let started = ContinuousClock().now
        Log.speech.notice("preparing neural voice (first run downloads the model)")
        let manager = KokoroAneManager(variant: .english, defaultVoice: voice)
        do {
            try await manager.initialize()
            self.manager = manager
            isReady = true
            Log.speech.notice("neural voice ready in \(ContinuousClock().now - started)")
        } catch {
            Log.speech.error("neural voice unavailable: \(error.localizedDescription)")
        }
    }

    func enqueue(_ text: String) {
        guard !cancelled, isReady else { return }
        pending.append(text)
        startPlaybackIfNeeded()
    }

    func finish() async {
        guard !cancelled, playback != nil || !pending.isEmpty else { return }
        await withCheckedContinuation { finished = $0 }
    }

    func stop() {
        guard !cancelled else { return }
        cancelled = true
        Log.speech.notice("interrupted by user")
        pending.removeAll()
        player?.stop()
        player = nil
        // stop() doesn't fire the delegate, so release the sentence that speak() is awaiting.
        playbackEnded()
        playback?.cancel()
        playback = nil
        resumeWaiter()
    }

    func reset() {
        #if os(iOS)
        try? AudioSession.activate()
        #endif
        cancelled = false
        pending.removeAll()
    }

    private func startPlaybackIfNeeded() {
        guard playback == nil else { return }
        playback = Task { [weak self] in
            while let self, !self.cancelled, !self.pending.isEmpty {
                let text = self.pending.removeFirst()
                await self.speak(text)
            }
            self?.playback = nil
            self?.resumeWaiter()
        }
    }

    private func speak(_ text: String) async {
        guard let manager, !cancelled else { return }
        do {
            let wav = try await manager.synthesize(
                text: text,
                voice: voice,
                speed: KokoroAneConstants.defaultSpeed * Float(rate)
            )
            guard !cancelled else { return }

            let player = try AVAudioPlayer(data: wav)
            self.player = player
            player.delegate = self
            player.play()
            await withCheckedContinuation { playedOut = $0 }
            self.player = nil
        } catch {
            Log.speech.error("neural synthesis failed: \(error.localizedDescription)")
        }
    }

    fileprivate func playbackEnded() {
        playedOut?.resume()
        playedOut = nil
    }

    private func resumeWaiter() {
        finished?.resume()
        finished = nil
    }
}

extension KokoroSpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in playbackEnded() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in playbackEnded() }
    }
}
