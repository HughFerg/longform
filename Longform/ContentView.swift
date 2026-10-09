import SwiftUI

struct ContentView: View {
    @State private var model = ChatModel()
    @State private var showingSettings = false
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            voiceControl
            Spacer(minLength: 12)
            conversation
        }
        .background {
            Palette.backdrop.ignoresSafeArea()
        }
        .onAppear { model.warmUp() }
        .onChange(of: model.status) { ScreenLock.keepAwake(model.status.isActive) }
        .onDisappear { ScreenLock.keepAwake(false) }
        .sheet(isPresented: $showingSettings) { SettingsSheet(model: model) }
        .sheet(isPresented: $showingHistory) { HistorySheet(model: model) }
    }

    private var header: some View {
        HStack {
            if model.status != .idle || model.transcriber.downloadProgress != nil {
                StatusPill(status: model.status, progress: model.transcriber.downloadProgress)
                    .transition(.opacity)
            }
            Spacer()
            HStack(spacing: 10) {
            Button { showingHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Palette.rest.opacity(0.9), in: .circle)
                    .shadow(color: Palette.restDeep.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)

            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Palette.rest.opacity(0.9), in: .circle)
                    .shadow(color: Palette.restDeep.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: model.status)
    }

    /// One control whose meaning follows the status.
    private var voiceControl: some View {
        VStack(spacing: 26) {
            Button(action: primaryAction) {
                ZStack {
                    // A ring appears only while listening, so the live state reads at a glance.
                    Circle()
                        .strokeBorder(Palette.live.opacity(model.isListening ? 0.45 : 0), lineWidth: 3)
                        .frame(width: 212, height: 212)
                    Circle()
                        .fill(glow.opacity(0.22))
                        .frame(width: 196, height: 196)
                        .blur(radius: 18)
                    Circle()
                        .fill(controlFill)
                        .frame(width: 168, height: 168)
                        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                        .shadow(color: glow.opacity(0.38), radius: 20, y: 8)
                    Image(systemName: primaryIcon)
                        .font(.system(size: 58, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.status == .thinking || model.status == .searching)
            .animation(.snappy, value: model.status)

            Text(primaryHint)
                .font(.title3.weight(.medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !model.transcript.isEmpty {
                liveTranscript.transition(.opacity)
            }
        }
    }

    /// A turn can run for minutes, so the transcript scrolls rather than truncating, and stays
    /// pinned to the newest words — what was just said matters more than how the turn opened.
    private var liveTranscript: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ScrollView {
                Text(model.transcript)
                    .font(.callout)
                    .foregroundStyle(Palette.ink.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: 150)
            .mask(
                LinearGradient(
                    colors: [.clear, .black, .black],
                    startPoint: .top,
                    endPoint: .init(x: 0.5, y: 0.22)
                )
            )

            Button("Clear") { model.discardDraft() }
                .font(.caption)
                .foregroundStyle(Palette.ink.opacity(0.45))
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder private var conversation: some View {
        if !model.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .onChange(of: model.messages.count) {
                    guard let last = model.messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(height: 180)
            .background(.background.opacity(0.5))
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.restDeep.opacity(0.15)).frame(height: 1)
            }
        }
    }

    private func primaryAction() {
        switch model.status {
        case .speaking: model.stopSpeaking()
        default: Task { await model.toggleListening() }
        }
    }

    private var controlFill: LinearGradient {
        switch model.status {
        case .listening: Palette.listening
        case .speaking: Palette.speaking
        case .thinking, .searching: Palette.thinking
        default: Palette.resting
        }
    }

    private var glow: Color {
        switch model.status {
        case .listening: Palette.live
        case .speaking: Palette.speak
        default: Palette.rest
        }
    }

    private var primaryIcon: String {
        switch model.status {
        case .listening: "waveform"
        case .speaking: "stop.fill"
        case .thinking: "ellipsis"
        case .searching: "magnifyingglass"
        default: "mic.fill"
        }
    }

    private var primaryHint: String {
        switch model.status {
        case .idle: model.transcript.isEmpty ? "Tap to start" : "Tap to carry on where you left off"
        case .listening: "Say “\(model.triggerPhrase)” when you're done"
        case .thinking: "Thinking…"
        case .searching: "Looking it up…"
        case .speaking: "Tap to stop"
        case .error(let message): message
        }
    }
}

private struct HistorySheet: View {
    @Bindable var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [StoredConversation] = []

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No past conversations",
                        systemImage: "clock",
                        description: Text("Finished conversations show up here and can be picked back up.")
                    )
                } else {
                    List {
                        ForEach(conversations) { conversation in
                            Button {
                                model.resume(conversation)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("\(conversation.entries.count) messages · \(conversation.updated.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets.map { conversations[$0] }.forEach(model.store.delete)
                            conversations = model.store.history()
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                Button("New") {
                    model.startNewConversation()
                    dismiss()
                }
            }
            .onAppear { conversations = model.store.history() }
        }
    }
}

private struct SettingsSheet: View {
    @Bindable var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAllVoices = false

    private var featured: [NeuralVoice] {
        NeuralVoice.featured.map(NeuralVoice.init)
    }

    private var others: [NeuralVoice] {
        KokoroSpeaker.voices.filter { !NeuralVoice.featured.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("End of turn") {
                    TextField("send it", text: $model.triggerPhrase)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    Text("Say this to finish your turn. Pauses never end it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Voice") {
                    Picker("Voice", selection: $model.engine) {
                        ForEach(VoiceEngine.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if model.engine.isRisky {
                        Label(
                            "The natural voice can crash the app on this version of iOS. Use it to try it out, not to rely on it.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(String(format: "%.2f×", model.speakingRate))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.speakingRate, in: Preferences.rateRange, step: 0.05) {
                            Text("Speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "hare")
                        }
                        .font(.caption)
                        .tint(Palette.speak)
                    }

                    if model.engine == .neural && model.neural.isPreparing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Getting the voice ready…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if model.engine == .neural {
                    Section {
                        ForEach(featured) { voice in
                            VoiceRow(voice: voice, selected: model.neuralVoice == voice.id) {
                                model.neuralVoice = voice.id
                            }
                        }
                    }

                    Section {
                        DisclosureGroup("More voices", isExpanded: $showingAllVoices) {
                            ForEach(others) { voice in
                                VoiceRow(voice: voice, selected: model.neuralVoice == voice.id) {
                                    model.neuralVoice = voice.id
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct VoiceRow: View {
    let voice: NeuralVoice
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name).foregroundStyle(.primary)
                    Text(voice.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Palette.restDeep)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPill: View {
    let status: Status
    let progress: Double?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(progress.map { "Downloading \(Int($0 * 100))%" } ?? status.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(colour.opacity(0.12), in: .capsule)
        .overlay(Capsule().strokeBorder(colour.opacity(0.2), lineWidth: 1))
        .foregroundStyle(colour)
    }

    private var colour: Color {
        switch status {
        case .idle: Palette.ink.opacity(0.75)
        case .listening: Palette.liveText
        case .thinking: Palette.restDeep
        case .searching, .speaking: Palette.speakDeep
        case .error: .red
        }
    }
}

private struct MessageBubble: View {
    let message: Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text)
                .font(.footnote)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    isUser ? AnyShapeStyle(Palette.restDeep) : AnyShapeStyle(Palette.surface.opacity(0.45)),
                    in: .rect(cornerRadius: 16)
                )
                .foregroundStyle(isUser ? .white : .primary)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

extension View {
    func noAutocapitalization() -> some View {
        #if os(iOS) || os(visionOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

#Preview {
    ContentView()
}
