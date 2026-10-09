import Foundation

/// What the user has configured, plus the turn they are part-way through saying.
///
/// The draft matters more than it looks: a turn here can take minutes, and losing it to a phone
/// call, a crash or a backgrounded app would lose real thinking. It is written on every
/// transcript update and cleared only when the turn is actually sent.
enum Preferences {
    private static let store = UserDefaults.standard

    static var triggerPhrase: String {
        get { store.string(forKey: "triggerPhrase") ?? "send it" }
        set { store.set(newValue, forKey: "triggerPhrase") }
    }

    static var engine: VoiceEngine {
        get { store.string(forKey: "engine").flatMap(VoiceEngine.init) ?? .system }
        set { store.set(newValue.rawValue, forKey: "engine") }
    }

    static var neuralVoice: String? {
        get { store.string(forKey: "neuralVoice") }
        set { store.set(newValue, forKey: "neuralVoice") }
    }

    /// Multiplier on each engine's natural pace. 1.0 is the engine default.
    static var speakingRate: Double {
        get { store.object(forKey: "speakingRate") as? Double ?? 1.0 }
        set { store.set(newValue, forKey: "speakingRate") }
    }

    static let rateRange = 0.7...1.4

    static var draft: String {
        get { store.string(forKey: "draft") ?? "" }
        set { store.set(newValue, forKey: "draft") }
    }
}
