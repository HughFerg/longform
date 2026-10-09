import Foundation

/// A queue of sentences that plays back to back. Both engines behave the same way, so the
/// conversation loop doesn't care which one is selected.
@MainActor
protocol VoiceOutput: AnyObject {
    /// Multiplier on the engine's natural pace, 1.0 being its default.
    var rate: Double { get set }

    /// Queues a sentence. Speech starts before the rest of the reply has arrived.
    func enqueue(_ text: String)
    /// Waits for everything queued so far. Called once the reply has fully arrived.
    func finish() async
    /// Cuts playback off and discards the queue.
    func stop()
    /// Readies the engine for the next reply.
    func reset()
}

/// The two speech engines, as shown in the picker.
enum VoiceEngine: String, CaseIterable, Identifiable {
    case system
    case neural

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .neural: "Natural"
        }
    }

    /// FluidAudio reports no safe Core ML route for Kokoro on the iOS/iPadOS 27 line: the default
    /// route has hit a SIGSEGV in libBNNS and the Metal route aborts in MPSGraph, both uncatchable.
    /// See https://github.com/FluidInference/FluidAudio/issues/889
    var isRisky: Bool {
        guard self == .neural else { return false }
        #if os(iOS)
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #else
        return false
        #endif
    }
}

/// A selectable Kokoro voice. Ids encode accent and gender: `af_heart` is American female.
struct NeuralVoice: Identifiable, Hashable {
    /// The handful offered up front. Everything else sits behind the expander.
    static let featured = ["af_heart", "af_bella", "am_michael"]

    let id: String

    var name: String { id.split(separator: "_").dropFirst().joined().capitalized }

    var accent: String {
        switch id.prefix(1) {
        case "a": "American"
        case "b": "British"
        case "e": "Spanish"
        case "f": "French"
        case "h": "Hindi"
        case "i": "Italian"
        case "j": "Japanese"
        case "p": "Portuguese"
        case "z": "Mandarin"
        default: "Other"
        }
    }

    var gender: String { id.dropFirst().prefix(1) == "f" ? "Female" : "Male" }

    var summary: String { "\(accent) · \(gender)" }
}
