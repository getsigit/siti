//
//  ContentView.swift
//  Siti AI visionOS
//

import SwiftUI
import Ed

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Root view
// ─────────────────────────────────────────────────────────────────────────────

struct ContentView: View {

    @StateObject private var viewModel = ChatViewModel()
    @State private var showingSettings = false

    @AppStorage("ai.siti.vision.systemPrompt")
    private var systemPrompt: String = SitiDefaults.systemPrompt

    @AppStorage("ai.siti.vision.samplingPreset")
    private var samplingPresetRawValue: String = SamplingPreset.balanced.rawValue

    private var samplingPreset: SamplingPreset {
        SamplingPreset(rawValue: samplingPresetRawValue) ?? .balanced
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderView(
                    info: viewModel.engineInfo,
                    isLoading: viewModel.isModelLoading,
                    isSending: viewModel.isSending
                )

                Divider()

                ZStack {
                    if viewModel.messages.isEmpty {
                        EmptyStateView(
                            isModelReady: viewModel.isModelReady,
                            isModelLoading: viewModel.isModelLoading,
                            loadingProgress: viewModel.loadingProgress,
                            promptSuggestions: SitiDefaults.promptSuggestions,
                            onPromptTap: { suggestion in
                                viewModel.sendSuggestion(suggestion)
                            },
                            onRetry: {
                                Task {
                                    await viewModel.retryLoadingModel(
                                        systemPrompt: systemPrompt,
                                        samplingPreset: samplingPreset
                                    )
                                }
                            }
                        )
                    } else {
                        MessageListView(messages: viewModel.messages)
                    }

                    if viewModel.isModelLoading {
                        LoadingOverlayView(progress: viewModel.loadingProgress)
                    }
                }

                Divider()

                InputBarView(
                    isSending: viewModel.isSending,
                    isModelReady: viewModel.isModelReady,
                    placeholder: viewModel.isModelReady
                        ? "Message Siti…"
                        : "Waiting for model to load…",
                    onSend: { text in viewModel.send(text: text) },
                    onCancel: { viewModel.cancelStreaming() }
                )
            }
            .navigationTitle("Siti AI")
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    if viewModel.hasMessages {
                        Button(role: .destructive) {
                            Task {
                                await viewModel.clearConversation()
                            }
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .disabled(viewModel.isBusy)
                    }
                }

                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        Task {
                            await viewModel.reloadModel(
                                systemPrompt: systemPrompt,
                                samplingPreset: samplingPreset
                            )
                        }
                    } label: {
                        Label("Reload model", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isBusy)

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Model settings", systemImage: "slider.horizontal.3")
                    }
                    .disabled(viewModel.isBusy)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            await viewModel.loadModelIfNeeded(
                systemPrompt: systemPrompt,
                samplingPreset: samplingPreset
            )
        }
        .sheet(isPresented: $showingSettings) {
            ModelSettingsSheet(
                systemPrompt: systemPrompt,
                samplingPreset: samplingPreset
            ) { updatedPrompt, updatedPreset in
                systemPrompt = updatedPrompt
                samplingPresetRawValue = updatedPreset.rawValue
                Task {
                    await viewModel.applySettings(
                        systemPrompt: updatedPrompt,
                        samplingPreset: updatedPreset
                    )
                }
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { viewModel.alertError != nil },
                set: { if !$0 { viewModel.alertError = nil } }
            ),
            presenting: viewModel.alertError
        ) { _ in
            Button("OK", role: .cancel) { viewModel.alertError = nil }
        } message: { error in
            Text(error.message)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Header
// ─────────────────────────────────────────────────────────────────────────────

private struct HeaderView: View {
    let info: EdEngineInfo
    let isLoading: Bool
    let isSending: Bool

    private var statusText: String {
        if isLoading { return "Loading" }
        if isSending { return "Generating" }

        switch info.status {
        case .ready: return "Ready"
        case .generating: return "Generating"
        case .loading: return "Loading"
        case .error: return "Error"
        case .unloaded: return "Unloaded"
        }
    }

    private var statusColor: Color {
        if isLoading { return .orange }
        if isSending { return .blue }

        switch info.status {
        case .ready: return .green
        case .generating: return .blue
        case .loading: return .orange
        case .error: return .red
        case .unloaded: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Siti AI")
                    .font(.headline)

                Text(info.modelName ?? "on-device · private")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(info.approximateMemory ?? "—", systemImage: "memorychip")
            Label("\(info.historyLength) turns", systemImage: "text.bubble")

            Text(statusText)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(statusColor.opacity(0.14), in: Capsule())
                .foregroundStyle(statusColor)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Loading overlay
// ─────────────────────────────────────────────────────────────────────────────

private struct LoadingOverlayView: View {
    let progress: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)

            Text(progress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 24)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Empty state
// ─────────────────────────────────────────────────────────────────────────────

private struct EmptyStateView: View {
    let isModelReady: Bool
    let isModelLoading: Bool
    let loadingProgress: String
    let promptSuggestions: [PromptSuggestion]
    let onPromptTap: (PromptSuggestion) -> Void
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isModelReady ? "How can I help?" : "Preparing the on-device model")
                        .font(.title2.weight(.semibold))

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isModelReady {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Try one of these prompts")
                            .font(.headline)

                        ForEach(promptSuggestions) { suggestion in
                            Button {
                                onPromptTap(suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(suggestion.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(suggestion.prompt)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.secondary.opacity(0.10))
                                )
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(loadingProgress, systemImage: isModelLoading ? "arrow.down.circle" : "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !isModelLoading {
                            Button(action: onRetry) {
                                Label("Retry loading model", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(28)
        }
    }

    private var subtitle: String {
        if isModelReady {
            return "Your personal assistant, running entirely on this device. Nothing you say ever leaves it."
        }

        return "The first launch may take a while because the model has to be downloaded and loaded into memory before the chat becomes interactive."
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Message list
// ─────────────────────────────────────────────────────────────────────────────

private struct MessageListView: View {
    let messages: [Message]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(20)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: messages.last?.text) { _, _ in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Message bubble
// ─────────────────────────────────────────────────────────────────────────────

private struct MessageBubble: View {
    let message: Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(isUser ? "You" : "Siti")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                HStack(alignment: .bottom, spacing: 6) {
                    Text(message.text.isEmpty ? " " : message.text)
                        .font(.body)
                        .foregroundStyle(isUser ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isUser ? Color.accentColor : Color.secondary.opacity(0.15))
                        )

                    if message.isStreaming {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.bottom, 8)
                    }
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Input bar
// ─────────────────────────────────────────────────────────────────────────────

private struct InputBarView: View {
    let isSending: Bool
    let isModelReady: Bool
    let placeholder: String
    let onSend: (String) -> Void
    let onCancel: () -> Void

    @State private var draftText: String = ""
    @FocusState private var fieldFocused: Bool

    private var canSend: Bool {
        isModelReady && !isSending && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $draftText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
                .focused($fieldFocused)
                .disabled(!isModelReady || isSending)
                .onSubmit {
                    submitIfReady()
                }

            Group {
                if isSending {
                    Button(action: onCancel) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop generating")
                } else {
                    Button(action: submitIfReady) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(canSend ? Color.accentColor : .secondary)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
                }
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isSending)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func submitIfReady() {
        guard canSend else { return }
        let text = draftText
        draftText = ""
        onSend(text)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Model settings sheet
// ─────────────────────────────────────────────────────────────────────────────

private struct ModelSettingsSheet: View {
    let initialSystemPrompt: String
    let initialSamplingPreset: SamplingPreset
    let onSave: (String, SamplingPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var systemPrompt: String
    @State private var samplingPreset: SamplingPreset

    init(
        systemPrompt: String,
        samplingPreset: SamplingPreset,
        onSave: @escaping (String, SamplingPreset) -> Void
    ) {
        self.initialSystemPrompt = systemPrompt
        self.initialSamplingPreset = samplingPreset
        self.onSave = onSave
        _systemPrompt = State(initialValue: systemPrompt)
        _samplingPreset = State(initialValue: samplingPreset)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 140)
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("This prompt applies to future generations. Leave it blank to clear the runtime system prompt.")
                }

                Section("Response Style") {
                    Picker("Sampling Preset", selection: $samplingPreset) {
                        ForEach(SamplingPreset.allCases) { preset in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                Text(preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(preset)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Model Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(systemPrompt, samplingPreset)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    ContentView()
}
