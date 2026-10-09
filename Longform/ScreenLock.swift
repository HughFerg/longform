#if os(iOS)
import UIKit

/// Keeps the screen awake while a turn is in flight. Thinking out loud for two minutes without
/// touching the phone is the normal case here, and the default lock would cut it short.
enum ScreenLock {
    static func keepAwake(_ awake: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != awake else { return }
        UIApplication.shared.isIdleTimerDisabled = awake
        Log.speech.notice("screen keep-awake \(awake ? "on" : "off")")
    }
}
#else
enum ScreenLock {
    static func keepAwake(_ awake: Bool) {}
}
#endif
