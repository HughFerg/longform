#if os(iOS)
import AVFoundation
import OSLog

/// One place that owns the audio session, so recording and playback agree on the route.
enum AudioSession {
    /// Configures for voice chat and honours whatever the user has connected.
    ///
    /// `.defaultToSpeaker` is deliberately absent: it pins output to the built-in speaker even when
    /// headphones, AirPods or CarPlay are connected. Instead the speaker is selected only when the
    /// route is the earpiece, which is the one case where the default is wrong.
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
        )
        try session.setActive(true)
        preferSpeakerOverEarpiece()
        logRoute()
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// With nothing connected, `.playAndRecord` plays through the quiet earpiece. Override to the
    /// speaker in that case only, so a real output device is never hijacked.
    static func preferSpeakerOverEarpiece() {
        let session = AVAudioSession.sharedInstance()
        let onEarpiece = session.currentRoute.outputs.allSatisfy { $0.portType == .builtInReceiver }
        try? session.overrideOutputAudioPort(onEarpiece ? .speaker : .none)
    }

    /// Re-applies the earpiece override when the user plugs in or unplugs mid-conversation.
    /// Without this, connecting headphones while already listening leaves audio on the speaker.
    static func observeRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            preferSpeakerOverEarpiece()
            logRoute()
        }
    }

    static func logRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let described = outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        Log.speech.notice("output route: \(described.isEmpty ? "none" : described)")
    }
}
#endif
