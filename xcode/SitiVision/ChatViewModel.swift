//
//  ChatViewModel.swift
//  Siti AI visionOS
//

import Ed
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Message model
// ─────────────────────────────────────────────────────────────────────────────

struct Message: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    /// True while the assistant is still streaming tokens for this message.
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

private extension Message {
    var asChatMessage: EdChatMessage {
        switch role {
        case .user:
            return EdChatMessage(role: .user, content: text)
        case .assistant:
            return EdChatMessage(role: .assistant, content: text)
        }
    }
}

private extension EdEngineInfo {
    static let unloaded = EdEngineInfo(status: .unloaded)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ViewModel
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class ChatViewModel: ObservableObject {

    // ── Published state ───────────────────────────────────────────────────────

    @Published private(set) var messages: [Message]
    @Published private(set) var isModelLoading: Bool = false
    @Published private(set) var isModelReady: Bool = false
    @Published private(set) var isSending: Bool = false
    @Published private(set) var loadingProgress: String = "Preparing model…"
    @Published private(set) var engineInfo: EdEngineInfo = .unloaded

    @Published var alertError: IdentifiableError? = nil

    // ── Private state ─────────────────────────────────────────────────────────

    // Lazy so the Rust/UniFFI runtime isn't initialized during
    // @StateObject construction on the UIKit event-fetch thread.
    private var engine: EdAgent?
    private var streamingTask: Task<Void, Never>?
    private var didHydrateEngineHistory = false

    private static let persistedMessagesKey = "ai.siti.vision.messages"

    init() {
        self.messages = Self.loadPersistedMessages()
    }

    private func getOrCreateEngine() -> EdAgent {
        if let existing = engine { return existing }
        let new = EdAgent(appID: nil)
        engine = new
        return new
    }

    var hasMessages: Bool {
        !messages.isEmpty
    }

    var isBusy: Bool {
        isModelLoading || isSending
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Model lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    func loadModelIfNeeded(systemPrompt: String, samplingPreset: SamplingPreset) async {
        if isModelReady {
            await applySettings(systemPrompt: systemPrompt, samplingPreset: samplingPreset)
            return
        }

        await loadModel(
            systemPrompt: systemPrompt,
            samplingPreset: samplingPreset,
            forceReload: false
        )
    }

    func retryLoadingModel(systemPrompt: String, samplingPreset: SamplingPreset) async {
        await loadModel(
            systemPrompt: systemPrompt,
            samplingPreset: samplingPreset,
            forceReload: false
        )
    }

    func reloadModel(systemPrompt: String, samplingPreset: SamplingPreset) async {
        await loadModel(
            systemPrompt: systemPrompt,
            samplingPreset: samplingPreset,
            forceReload: true
        )
    }

    func applySettings(systemPrompt: String, samplingPreset: SamplingPreset) async {
        guard isModelReady else { return }

        let engine = getOrCreateEngine()
        let normalizedPrompt = normalizedSystemPrompt(systemPrompt)

        if let normalizedPrompt {
            await engine.setSystemPrompt(normalizedPrompt)
        } else {
            await engine.clearSystemPrompt()
        }

        await engine.setSampling(samplingPreset.samplingConfig)
        await refreshEngineInfo()
    }

    func clearConversation() async {
        cancelStreaming()
        messages.removeAll()
        persistMessages()

        if let engine {
            _ = await engine.clearHistory()
            await refreshEngineInfo()
        } else {
            engineInfo = .unloaded
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Sending messages
    // ─────────────────────────────────────────────────────────────────────────

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending, isModelReady else { return }

        alertError = nil
        messages.append(Message(role: .user, text: trimmed))
        persistMessages()

        streamingTask = Task {
            await streamResponse(for: trimmed)
        }
    }

    func sendSuggestion(_ suggestion: PromptSuggestion) {
        send(text: suggestion.prompt)
    }

    func cancelStreaming() {
        // Cancelling the task ends the `for try await` in `streamResponse`,
        // which stops generation on the Rust side.
        streamingTask?.cancel()
        streamingTask = nil

        if let idx = messages.indices.last, messages[idx].isStreaming {
            if messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.remove(at: idx)
            } else {
                messages[idx].isStreaming = false
            }
            persistMessages()
        }

        isSending = false
        if engineInfo.status == .generating {
            engineInfo = EdEngineInfo(
                status: .ready,
                modelName: engineInfo.modelName,
                approximateMemory: engineInfo.approximateMemory,
                historyLength: engineInfo.historyLength
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func loadModel(
        systemPrompt: String,
        samplingPreset: SamplingPreset,
        forceReload: Bool
    ) async {
        guard !isModelLoading else { return }

        if forceReload {
            cancelStreaming()
            didHydrateEngineHistory = false
        }

        isModelLoading = true
        isModelReady = false
        alertError = nil
        loadingProgress = forceReload ? "Reloading model…" : "Loading model…"

        defer {
            isModelLoading = false
        }

        do {
            let elapsed = try await getOrCreateEngine().load(
                gguf: SitiDefaults.defaultModel,
                systemPrompt: normalizedSystemPrompt(systemPrompt),
                sampling: samplingPreset.samplingConfig
            )

            loadingProgress = String(format: "Model ready in %.1f s", elapsed)
            isModelReady = true
            didHydrateEngineHistory = false
            await restorePersistedConversationIfNeeded()
            await refreshEngineInfo()
        } catch {
            isModelReady = false
            await refreshEngineInfo()
            alertError = IdentifiableError(error)
            loadingProgress = "Unable to load model"
        }
    }

    private func streamResponse(for userText: String) async {
        isSending = true
        engineInfo = EdEngineInfo(
            status: .generating,
            modelName: engineInfo.modelName,
            approximateMemory: engineInfo.approximateMemory,
            historyLength: engineInfo.historyLength
        )

        let assistantIndex = messages.count
        messages.append(Message(role: .assistant, text: "", isStreaming: true))

        do {
            for try await delta in getOrCreateEngine().stream(userText) {
                if assistantIndex < messages.count {
                    messages[assistantIndex].text += delta
                }
            }
        } catch {
            if !Task.isCancelled {
                alertError = IdentifiableError(error)
            }
        }

        let assistantHasText = assistantIndex < messages.count &&
            !messages[assistantIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if assistantIndex < messages.count {
            if assistantHasText {
                messages[assistantIndex].isStreaming = false
            } else {
                messages.remove(at: assistantIndex)
            }
        }

        persistMessages()
        streamingTask = nil
        isSending = false
        await refreshEngineInfo()
    }

    private func restorePersistedConversationIfNeeded() async {
        guard !didHydrateEngineHistory else { return }
        guard !messages.isEmpty else {
            didHydrateEngineHistory = true
            return
        }

        loadingProgress = "Restoring conversation…"
        await getOrCreateEngine().restoreHistory(messages.map(\.asChatMessage))

        didHydrateEngineHistory = true
    }

    private func refreshEngineInfo() async {
        guard let engine else {
            engineInfo = .unloaded
            return
        }

        let info = await engine.info()
        engineInfo = info
        isModelReady = info.status == .ready || info.status == .generating
    }

    private func normalizedSystemPrompt(_ prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistMessages() {
        do {
            let data = try JSONEncoder().encode(messages)
            UserDefaults.standard.set(data, forKey: Self.persistedMessagesKey)
        } catch {
            logPersistenceFailure(error)
        }
    }

    private static func loadPersistedMessages() -> [Message] {
        guard let data = UserDefaults.standard.data(forKey: persistedMessagesKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([Message].self, from: data).map {
                Message(id: $0.id, role: $0.role, text: $0.text, isStreaming: false)
            }
        } catch {
            return []
        }
    }

    private func logPersistenceFailure(_ error: Error) {
        NSLog("SitiVision: failed to persist messages: %@", String(describing: error))
    }
}
