import AVFoundation
import OSLog
import Observation
import Speech

enum TranscriberError: LocalizedError {
    case micDenied
    case speechDenied
    case noModels
    case audioSetupFailed

    var errorDescription: String? {
        switch self {
        case .micDenied: "Microphone access denied. Enable it in Settings."
        case .speechDenied: "Speech recognition denied. Enable it in Settings."
        case .noModels: "No speech models available. The Simulator has none — run on a device or your Mac."
        case .audioSetupFailed: "Couldn't set up audio input."
        }
    }
}

/// Long-form on-device transcription. Nothing finalizes the stream but an explicit `stop()`,
/// so silence never ends a turn however long it lasts.
@MainActor @Observable
final class Transcriber {
    /// Called on every update with the full text so far (finalized + in-progress).
    var onUpdate: (String) -> Void = { _ in }
    var downloadProgress: Double?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputStream: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var reservedLocale: Locale?
    private var finalized = ""
    private var pending = ""

    /// False where no transcription models exist at all, e.g. the Simulator.
    static var isSupported: Bool {
        get async { await !SpeechTranscriber.supportedLocales.isEmpty }
    }

    /// True between the first await in `start()` and the engine actually running. Rapid taps can
    /// otherwise call start twice and install a second tap on the same bus, which traps.
    private var isStarting = false

    func start() async throws {
        guard analyzer == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard await AVAudioApplication.requestRecordPermission() else { throw TranscriberError.micDenied }
        guard await requestSpeechAuthorization() else { throw TranscriberError.speechDenied }

        let locale = try await resolveLocale()
        (finalized, pending) = ("", "")

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence]
        )
        try await installModelIfNeeded(for: transcriber)
        try await reserve(locale)

        #if os(iOS)
        try AudioSession.activate()
        #endif

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputStream = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            await tearDown()
            throw error
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.apply(result) }
            } catch {
                Log.speech.error("results ended: \(error.localizedDescription)")
            }
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        else {
            await tearDown()
            throw TranscriberError.audioSetupFailed
        }

        nonisolated(unsafe) let tapConverter = converter
        // The iOS 27 throwing replacement for installTap has no Swift overlay yet; this call still works.
        engine.inputNode.removeTap(onBus: 0)  // a failed previous start can leave one installed
        engine.inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: tapConverter, to: analyzerFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            await tearDown()
            throw error
        }

        Log.speech.notice("listening in \(locale.identifier) at \(Int(analyzerFormat.sampleRate))Hz")
    }

    func stop() async {
        guard analyzer != nil, !isStarting else { return }
        await tearDown()
        Log.speech.notice("stopped after \(self.finalized.count) finalized chars")
    }

    /// Returns the transcriber to a startable state. State is cleared *before* any await, so a
    /// hang in `finalizeAndFinishThroughEndOfInput` can't leave `analyzer` set and wedge every
    /// future `start()` behind its guard.
    private func tearDown() async {
        let analyzer = self.analyzer
        let locale = reservedLocale
        self.analyzer = nil
        self.reservedLocale = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputStream?.finish()
        inputStream = nil
        resultsTask?.cancel()
        resultsTask = nil

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        if let locale {
            await AssetInventory.release(reservedLocale: locale)
        }
        #if os(iOS)
        AudioSession.deactivate()
        #endif
    }

    /// Final text below this is dropped as room noise.
    ///
    /// Deliberately low. On-device testing showed hesitant real speech — "Um, we should… Uh, I don't know."
    /// — scoring 0.55 and being silently deleted, and that kind of thinking-out-loud is exactly what this
    /// app exists to capture. Clear speech scores 0.98-0.99 and background audio 0.45-0.84, so the ranges
    /// overlap badly: filtering hard enough to catch a TV also eats your own hesitation.
    /// Only near-garbage is dropped now; everything dropped is logged with its score.
    static var minimumConfidence = 0.3

    /// Length-weighted mean confidence, or nil when the result carries no confidence attributes.
    private static func confidence(of text: AttributedString) -> Double? {
        var total = 0.0
        var characters = 0.0
        for run in text.runs {
            guard let value = run.transcriptionConfidence else { continue }
            let length = Double(text[run.range].characters.count)
            total += value * length
            characters += length
        }
        return characters > 0 ? total / characters : nil
    }

    private func apply(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            if let confidence = Self.confidence(of: result.text), confidence < Self.minimumConfidence {
                Log.speech.notice("dropped \(String(format: "%.2f", confidence)) confidence: \(text)")
                pending = ""
                return
            }
            finalized += finalized.isEmpty ? text : " \(text)"
            pending = ""
        } else {
            pending = text
        }
        onUpdate(pending.isEmpty ? finalized : "\(finalized) \(pending)".trimmingCharacters(in: .whitespaces))
    }

    /// Resamples a mic buffer into the format the analyzer expects. Runs on the audio thread.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { Log.speech.error("convert failed: \(error.localizedDescription)") }
        return output.frameLength > 0 ? output : nil
    }

    private func installModelIfNeeded(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        Log.speech.notice("downloading transcription model")

        let poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.downloadProgress = request.progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { poll.cancel(); downloadProgress = nil }
        try await request.downloadAndInstall()
    }

    /// Exact locale, else any model for the same language, else English.
    private func resolveLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else {
            Log.speech.error("no supported locales (isAvailable=\(SpeechTranscriber.isAvailable))")
            throw TranscriberError.noModels
        }
        if let exact = await SpeechTranscriber.supportedLocale(equivalentTo: .current) { return exact }

        func firstMatch(_ code: String?) -> Locale? {
            code.flatMap { code in supported.first { $0.language.languageCode?.identifier == code } }
        }
        guard let fallback = firstMatch(Locale.current.language.languageCode?.identifier) ?? firstMatch("en") else {
            throw TranscriberError.noModels
        }
        Log.speech.notice("no model for \(Locale.current.identifier), using \(fallback.identifier)")
        return fallback
    }

    /// Without a reservation the analyzer logs "unallocated locales", which Apple says becomes an error.
    private func reserve(_ locale: Locale) async throws {
        guard await !AssetInventory.reservedLocales.contains(locale) else { return }
        if try await AssetInventory.reserve(locale: locale) {
            reservedLocale = locale
        } else {
            Log.speech.error("could not reserve \(locale.identifier)")
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}
