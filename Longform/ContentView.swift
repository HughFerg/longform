import SwiftUI

struct ContentView: View {
    @State private var model = ChatModel()
    @State private var showingConversation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            voiceControl
            Spacer(minLength: 12)
            conversation
            footer
        }
        .background(.background)
        .task { await model.checkSpeechAvailability() }
        .sheet(isPresented: $showingConversation) {
            ConversationSheet(messages: model.messages)
        }
    }

    private var header: some View {
        HStack {
            StatusPill(status: model.status, progress: model.transcriber.downloadProgress)
            Spacer()
            if model.cost.turns > 0 {
                Text(model.cost.summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    /// Kept visible but secondary — you glance at it, you don't read it.
    @ViewBuilder private var conversation: some View {
        if !model.messages.isEmpty {
            VStack(spacing: 6) {
                HStack {
                    Text("Conversation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") {
                        showingConversation = true
                    }
                    .font(.caption)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.messages) { message in
                                MessageBubble(message: message, compact: true).id(message.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    }
                    .onChange(of: model.messages.count) {
                        guard let last = model.messages.last else { return }
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .frame(height: 210)
        }
    }

    /// The whole point of the screen: one big control whose meaning follows the status.
    private var voiceControl: some View {
        VStack(spacing: 28) {
            Button(action: primaryAction) {
                ZStack {
                    Circle()
                        .fill(primaryColor.gradient)
                        .frame(width: 168, height: 168)
                        .shadow(color: primaryColor.opacity(0.35), radius: 24, y: 8)
                    Image(systemName: primaryIcon)
                        .font(.system(size: 62, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.status == .thinking || !model.speechAvailable)
            .animation(.snappy, value: model.status)

            Text(primaryHint)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            liveTranscript
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder private var liveTranscript: some View {
        if !model.transcript.isEmpty {
            Text(model.transcript)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if !model.speechAvailable {
                Label(
                    "The Simulator has no speech models. Type below and end with your trigger phrase.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                TextField("trigger phrase", text: $model.triggerPhrase)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06), in: .capsule)

                if !model.speechAvailable {
                    TextField("message", text: Binding(
                        get: { model.transcript },
                        set: { model.transcriptChanged($0) }
                    ))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06), in: .capsule)

                    Button {
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderless)
                    .background(model.canSend ? Color.accentColor : .gray.opacity(0.3), in: .circle)
                    .foregroundStyle(.white)
                    .disabled(!model.canSend)
                }
            }
        }
        .padding()
    }

    private func primaryAction() {
        switch model.status {
        case .speaking: model.stopSpeaking()
        default: Task { await model.toggleListening() }
        }
    }

    private var primaryIcon: String {
        switch model.status {
        case .listening: "waveform"
        case .speaking: "stop.fill"
        case .thinking: "ellipsis"
        default: "mic.fill"
        }
    }

    private var primaryColor: Color {
        switch model.status {
        case .listening: .red
        case .speaking: .orange
        case .thinking: .gray
        default: .accentColor
        }
    }

    private var primaryHint: String {
        switch model.status {
        case .idle: "Tap to start"
        case .listening: "Say “\(model.triggerPhrase)” when you're done"
        case .thinking: "Thinking…"
        case .speaking: "Tap to stop"
        case .error(let message): message
        }
    }
}

private struct ConversationSheet: View {
    let messages: [Message]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { MessageBubble(message: $0) }
                }
                .padding()
            }
            .navigationTitle("Conversation")
        }
    }
}

private struct StatusPill: View {
    let status: Status
    let progress: Double?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(progress.map { "Downloading \(Int($0 * 100))%" } ?? status.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: .capsule)
        .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .idle: .secondary
        case .listening: .red
        case .thinking: .orange
        case .speaking: .orange
        case .error: .red
        }
    }
}

private struct MessageBubble: View {
    let message: Message
    var compact = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text)
                .font(compact ? .footnote : .body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser ? Color.accentColor : Color.primary.opacity(0.07),
                    in: .rect(cornerRadius: 18)
                )
                .foregroundStyle(isUser ? .white : .primary)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

private extension View {
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
