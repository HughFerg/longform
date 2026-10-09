import SwiftUI

/// Ink and amber: a calm near-navy at rest, warm gold when live.
/// Each state differs in hue as well as brightness so they're never confusable.
enum Palette {
    /// Resting control and chrome.
    static let rest = Color(red: 0.22, green: 0.25, blue: 0.33)
    static let restDeep = Color(red: 0.13, green: 0.16, blue: 0.23)

    /// Listening: warm gold, unmistakably "on".
    static let live = Color(red: 0.95, green: 0.65, blue: 0.20)
    static let liveDeep = Color(red: 0.85, green: 0.49, blue: 0.11)
    /// Gold on cream is unreadable as text, so labels use this instead of `live`.
    static let liveText = Color(red: 0.68, green: 0.40, blue: 0.05)

    /// Speaking: cool slate, distinct from both of the above.
    static let speak = Color(red: 0.33, green: 0.47, blue: 0.62)
    static let speakDeep = Color(red: 0.21, green: 0.33, blue: 0.46)

    /// Surfaces and type.
    static let surface = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let ink = Color(red: 0.20, green: 0.23, blue: 0.29)

    static var backdrop: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.99, green: 0.97, blue: 0.93), Color(red: 0.97, green: 0.97, blue: 0.96)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var resting: LinearGradient {
        LinearGradient(colors: [rest, restDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var listening: LinearGradient {
        LinearGradient(colors: [live, liveDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var speaking: LinearGradient {
        LinearGradient(colors: [speak, speakDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var thinking: LinearGradient {
        LinearGradient(colors: [rest.opacity(0.5), rest.opacity(0.35)], startPoint: .top, endPoint: .bottom)
    }
}
