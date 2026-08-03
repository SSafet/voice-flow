import Cocoa
import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Settings Window — native macOS preferences
//  (toolbar tabs + System Settings-style grouped forms)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class SettingsStore: ObservableObject {
    var onHotkeyChanged: ((HotkeySpec) -> Void)?
    var onHandsFreeHotkeyChanged: ((HotkeySpec) -> Void)?
    var onTTSHotkeyChanged: ((HotkeySpec) -> Void)?
    var onContinuousCaptureHotkeyChanged: ((HotkeySpec) -> Void)?
    var onSnapshotHotkeyChanged: ((HotkeySpec) -> Void)?
    var onAnnotateHotkeyChanged: ((HotkeySpec) -> Void)?
    var onSettingsChanged: (() -> Void)?

    @Published var provider: DictationProvider { didSet { commit() } }
    @Published var micDeviceUID: String { didSet { commit() } }
    @Published var micDeviceName: String { didSet { commit() } }
    @Published var soundsEnabled: Bool { didSet { commit() } }
    @Published var llmCleanupEnabled: Bool { didSet { commit() } }
    @Published var vocabularyText: String { didSet { commit() } }
    @Published var doubleTapMs: Double { didSet { commit() } }
    @Published var ttsVoice: String { didSet { commit() } }
    @Published var ttsSpeed: Double { didSet { commit() } }
    @Published var agentModel: String { didSet { commit() } }
    @Published var agentBaseURL: String { didSet { commit() } }
    @Published var agentDailyBudgetUSD: Double { didSet { commit() } }
    @Published var agentBackend: String { didSet { commit() } }
    @Published var assistantWakeEnabled: Bool { didSet { commit() } }
    @Published var assistantWakeWord: String { didSet { commit() } }
    @Published var doubleSelectSpeak: Bool { didSet { commit() } }
    @Published var queueEnabled: Bool { didSet { commit() } }
    @Published var assistantComputerUse: Bool { didSet { commit() } }
    @Published var workflowWatcherEnabled: Bool { didSet { commit() } }
    @Published var watcherInterval: Double { didSet { commit() } }
    @Published var watcherIdlePause: Double { didSet { commit() } }
    @Published var watcherKeepDays: Double { didSet { commit() } }
    @Published var watcherActionsEnabled: Bool { didSet { commit() } }
    @Published var watcherCameraId: String { didSet { commit() } }

    // Keychain state
    @Published var hasOpenAIKey: Bool
    @Published var hasAgentKey: Bool
    @Published var openAIKeyDraft = ""
    @Published var agentKeyDraft = ""
    @Published var openAIKeyMessage: String?
    @Published var agentKeyMessage: String?

    // Hotkeys (display state; commits happen via setHotkey)
    @Published var hotkey: HotkeySpec
    @Published var handsFreeHotkey: HotkeySpec
    @Published var ttsHotkey: HotkeySpec
    @Published var continuousCaptureHotkey: HotkeySpec
    @Published var snapshotHotkey: HotkeySpec
    @Published var annotateHotkey: HotkeySpec

    private var loaded = false

    init() {
        let s = UserSettings.shared
        provider = s.dictationProvider
        micDeviceUID = s.micDeviceUID
        micDeviceName = s.micDeviceName
        soundsEnabled = s.soundsEnabled
        llmCleanupEnabled = s.llmCleanupEnabled
        vocabularyText = s.customVocabulary.joined(separator: ", ")
        doubleTapMs = Double(s.doubleTapMs)
        ttsVoice = s.ttsVoice
        ttsSpeed = s.ttsSpeed
        agentModel = s.agentModel
        agentBaseURL = s.agentBaseURL
        agentDailyBudgetUSD = s.agentDailyBudgetUSD
        agentBackend = s.agentBackend
        assistantWakeEnabled = s.assistantWakeEnabled
        assistantWakeWord = s.assistantWakeWord
        doubleSelectSpeak = s.doubleSelectSpeak
        queueEnabled = s.queueEnabled
        assistantComputerUse = s.assistantComputerUse
        workflowWatcherEnabled = s.workflowWatcherEnabled
        watcherInterval = Double(s.watcherIntervalSeconds)
        watcherIdlePause = Double(s.watcherIdlePauseSeconds)
        watcherKeepDays = Double(s.watcherKeepDays)
        watcherActionsEnabled = s.watcherActionsEnabled
        watcherCameraId = s.watcherCameraId
        hasOpenAIKey = KeychainStore.shared.hasOpenAIAPIKey
        hasAgentKey = KeychainStore.shared.hasAgentAPIKey
        hotkey = s.hotkey
        handsFreeHotkey = s.handsFreeHotkey
        ttsHotkey = s.ttsHotkey
        continuousCaptureHotkey = s.continuousCaptureHotkey
        snapshotHotkey = s.snapshotHotkey
        annotateHotkey = s.annotateHotkey
        loaded = true
    }

    var needsOpenAIKey: Bool { provider == .openai && !hasOpenAIKey }

    func reloadAssistantSettings() {
        loaded = false
        let settings = UserSettings.shared
        agentModel = settings.agentModel
        agentBaseURL = settings.agentBaseURL
        agentDailyBudgetUSD = settings.agentDailyBudgetUSD
        agentBackend = settings.agentBackend
        hasAgentKey = KeychainStore.shared.hasAgentAPIKey
        loaded = true
    }

    private func commit() {
        guard loaded else { return }
        let s = UserSettings.shared
        s.dictationProvider = provider
        s.micDeviceUID = micDeviceUID
        s.micDeviceName = micDeviceName
        s.soundsEnabled = soundsEnabled
        s.llmCleanupEnabled = llmCleanupEnabled
        s.customVocabulary = vocabularyText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        s.doubleTapMs = Int(doubleTapMs)
        s.ttsVoice = ttsVoice
        s.ttsSpeed = ttsSpeed
        let model = agentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        s.agentModel = model.isEmpty ? DefaultAgentModel : model
        let url = agentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        s.agentBaseURL = url.isEmpty ? DefaultAgentBaseURL : url
        s.agentDailyBudgetUSD = min(max(agentDailyBudgetUSD, 0.25), 500)
        s.agentBackend = agentBackend == AgentBackendOpenCode
            ? AgentBackendOpenCode : AgentBackendCodex
        s.assistantWakeEnabled = assistantWakeEnabled
        let wakeWord = assistantWakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        s.assistantWakeWord = wakeWord.isEmpty ? DefaultAssistantWakeWord : wakeWord
        s.doubleSelectSpeak = doubleSelectSpeak
        s.queueEnabled = queueEnabled
        s.assistantComputerUse = assistantComputerUse
        s.workflowWatcherEnabled = workflowWatcherEnabled
        s.watcherIntervalSeconds = Int(watcherInterval)
        s.watcherIdlePauseSeconds = Int(watcherIdlePause)
        s.watcherKeepDays = Int(watcherKeepDays)
        s.watcherActionsEnabled = watcherActionsEnabled
        s.watcherCameraId = watcherCameraId
        s.save()
        onSettingsChanged?()
    }

    enum HotkeyKind { case dictate, handsFree, tts, continuousCapture, snapshot, annotate }

    func setHotkey(_ kind: HotkeyKind, _ spec: HotkeySpec) {
        let s = UserSettings.shared
        switch kind {
        case .dictate:
            guard spec.keyCode != s.hotkey.keyCode || spec.modifiers != s.hotkey.modifiers else { return }
            s.hotkey = spec; hotkey = spec; onHotkeyChanged?(spec)
        case .handsFree:
            guard spec.keyCode != s.handsFreeHotkey.keyCode || spec.modifiers != s.handsFreeHotkey.modifiers else { return }
            s.handsFreeHotkey = spec; handsFreeHotkey = spec; onHandsFreeHotkeyChanged?(spec)
        case .tts:
            guard spec.keyCode != s.ttsHotkey.keyCode || spec.modifiers != s.ttsHotkey.modifiers else { return }
            s.ttsHotkey = spec; ttsHotkey = spec; onTTSHotkeyChanged?(spec)
        case .continuousCapture:
            guard spec.keyCode != s.continuousCaptureHotkey.keyCode || spec.modifiers != s.continuousCaptureHotkey.modifiers else { return }
            s.continuousCaptureHotkey = spec; continuousCaptureHotkey = spec; onContinuousCaptureHotkeyChanged?(spec)
        case .snapshot:
            guard spec.keyCode != s.snapshotHotkey.keyCode || spec.modifiers != s.snapshotHotkey.modifiers else { return }
            s.snapshotHotkey = spec; snapshotHotkey = spec; onSnapshotHotkeyChanged?(spec)
        case .annotate:
            guard spec.keyCode != s.annotateHotkey.keyCode || spec.modifiers != s.annotateHotkey.modifiers else { return }
            s.annotateHotkey = spec; annotateHotkey = spec; onAnnotateHotkeyChanged?(spec)
        }
        s.save()
        onSettingsChanged?()
    }

    // ── Keychain actions ──

    func saveOpenAIKey() {
        let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if KeychainStore.shared.saveOpenAIAPIKey(key) {
            openAIKeyDraft = ""
            hasOpenAIKey = true
            openAIKeyMessage = nil
        } else {
            NSSound.beep()
            openAIKeyMessage = "Couldn't save the key to your Keychain. Please try again."
        }
    }

    func removeOpenAIKey() {
        if KeychainStore.shared.removeOpenAIAPIKey() {
            hasOpenAIKey = false
            openAIKeyMessage = nil
        } else {
            NSSound.beep()
            openAIKeyMessage = "Couldn't remove the saved key."
        }
    }

    func saveAgentKey() {
        let key = agentKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if KeychainStore.shared.saveAgentAPIKey(key) {
            agentKeyDraft = ""
            hasAgentKey = true
            agentKeyMessage = nil
        } else {
            NSSound.beep()
            agentKeyMessage = "Couldn't save the key to your Keychain. Please try again."
        }
    }

    func removeAgentKey() {
        if KeychainStore.shared.removeAgentAPIKey() {
            hasAgentKey = false
            agentKeyMessage = nil
        } else {
            NSSound.beep()
            agentKeyMessage = "Couldn't remove the saved key."
        }
    }
}

// ── SwiftUI wrapper for the AppKit hotkey recorder ──

struct KeyRecorderView: NSViewRepresentable {
    let spec: HotkeySpec
    let onChange: (HotkeySpec) -> Void

    func makeNSView(context: Context) -> KeyRecorderButton {
        let button = KeyRecorderButton(spec: spec)
        button.onRecorded = onChange
        return button
    }

    func updateNSView(_ button: KeyRecorderButton, context: Context) {
        button.onRecorded = onChange
    }
}

// ── Shared row helpers ──

private struct SettingRowLabel: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let subtitle: String
    let spec: HotkeySpec
    let onChange: (HotkeySpec) -> Void

    var body: some View {
        LabeledContent {
            KeyRecorderView(spec: spec, onChange: onChange)
                .frame(width: 170)
        } label: {
            SettingRowLabel(title: title, subtitle: subtitle)
        }
    }
}

private struct APIKeyRow: View {
    let label: String
    let placeholder: String
    let hasKey: Bool
    @Binding var draft: String
    let message: String?
    let onSave: () -> Void
    let onRemove: () -> Void

    var body: some View {
        if hasKey {
            LabeledContent {
                Button("Remove…", role: .destructive, action: onRemove)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    SettingRowLabel(title: label, subtitle: "Saved securely in your Mac's Keychain")
                }
            }
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("", text: $draft, prompt: Text(placeholder))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                        .onSubmit(onSave)
                    Button("Save", action: onSave)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } label: {
                SettingRowLabel(title: label)
            }
        }
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

// ── Dictation tab ──

private struct DictationSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var mics: [(id: String, name: String)] = []
    // Display selection is decoupled from the stored UID: when the saved mic is
    // gone the picker shows what will actually record (system default) while the
    // UID stays saved so the mic is reclaimed on reconnect.
    @State private var micSelection: String = ""
    @State private var syncingSelection = false

    private var savedMicConnected: Bool {
        mics.contains(where: { $0.id == store.micDeviceUID })
    }

    private func syncMicSelection() {
        syncingSelection = true
        micSelection = savedMicConnected ? store.micDeviceUID : ""
        DispatchQueue.main.async { syncingSelection = false }
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $micSelection) {
                    Text("System default").tag("")
                    ForEach(mics, id: \.id) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                    if !store.micDeviceUID.isEmpty, !savedMicConnected {
                        Text("\(store.micDeviceName.isEmpty ? "Saved microphone" : store.micDeviceName) — disconnected")
                            .tag("saved-disconnected")
                    }
                } label: {
                    SettingRowLabel(title: "Record with",
                                    subtitle: "The mic used whenever you dictate or talk")
                }
                .onChange(of: micSelection) { picked in
                    guard !syncingSelection else { return }
                    if picked == "saved-disconnected" {
                        // Informational row: keep showing the actual recorder.
                        syncMicSelection()
                        return
                    }
                    store.micDeviceUID = picked
                    store.micDeviceName = mics.first(where: { $0.id == picked })?.name ?? ""
                }
                .onAppear {
                    AudioRecorder.monitorMicList()
                    mics = AudioRecorder.availableMicrophones()
                    syncMicSelection()
                }
                .onReceive(NotificationCenter.default.publisher(for: AudioRecorder.micListChanged)) { _ in
                    mics = AudioRecorder.availableMicrophones()
                    syncMicSelection()
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Pick the Mac's built-in mic to keep Bluetooth earbuds from taking over recording when they connect. If the chosen mic isn't available, the system default is used.")
            }

            Section {
                Picker(selection: $store.provider) {
                    Text("OpenAI cloud — best quality").tag(DictationProvider.openai)
                    Text("On this Mac — private, works offline").tag(DictationProvider.local)
                } label: {
                    SettingRowLabel(title: "Transcribe speech using")
                }
                .pickerStyle(.menu)

                if store.provider == .openai {
                    APIKeyRow(
                        label: "OpenAI API key",
                        placeholder: "sk-…",
                        hasKey: store.hasOpenAIKey,
                        draft: $store.openAIKeyDraft,
                        message: store.openAIKeyMessage,
                        onSave: { store.saveOpenAIKey() },
                        onRemove: { store.removeOpenAIKey() }
                    )
                    if store.needsOpenAIKey {
                        Label("Add your OpenAI key to start dictating, or switch to on-device transcription.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text(store.provider == .openai
                     ? "Audio is sent to OpenAI for transcription. Your key is billed on your own OpenAI account."
                     : "Everything stays on your Mac. Slightly less accurate than the cloud option.")
            }

            Section("Accuracy") {
                LabeledContent {
                    TextField("", text: $store.vocabularyText, prompt: Text("Claude, Anthropic, Figma…"), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .frame(minWidth: 260)
                } label: {
                    SettingRowLabel(title: "Special words",
                                    subtitle: "Names and jargon it should spell correctly, separated by commas")
                }
                if store.provider == .local {
                    Toggle(isOn: $store.llmCleanupEnabled) {
                        SettingRowLabel(title: "Polish transcripts with AI",
                                        subtitle: "Fixes punctuation and small errors after on-device transcription")
                    }
                }
            }

            Section("Feedback") {
                Toggle(isOn: $store.soundsEnabled) {
                    SettingRowLabel(title: "Play sounds",
                                    subtitle: "A soft chime when recording starts and stops")
                }
            }

            Section("Advanced") {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $store.doubleTapMs, in: 200...800, step: 50)
                            .frame(width: 180)
                        Text("\(Int(store.doubleTapMs)) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                } label: {
                    SettingRowLabel(title: "Double-press speed",
                                    subtitle: "How quickly you must press twice for hands-free mode")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// ── Voice tab ──

private struct VoiceSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(selection: $store.ttsVoice) {
                    ForEach(OpenAITTSVoices, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                } label: {
                    SettingRowLabel(title: "Voice")
                }
                .pickerStyle(.menu)

                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $store.ttsSpeed, in: 0.5...2.0, step: 0.05)
                            .frame(width: 180)
                        Text(String(format: "%.2f×", store.ttsSpeed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                } label: {
                    SettingRowLabel(title: "Speaking speed")
                }
            } header: {
                Text("Read aloud")
            } footer: {
                Text("Used when Voice Flow reads text aloud — with the Read Aloud shortcut or when the assistant speaks its replies.")
            }
        }
        .formStyle(.grouped)
    }
}

// ── Assistant tab ──

private struct AssistantSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var openCodeStatus = "Starts on demand"
    @State private var modelCatalog = OpenRouterModelCatalogResult(
        models: [], source: .fallback, fetchedAt: nil, warning: nil)
    @State private var refreshingModels = false

    private var codexStatus: String {
        guard CodexExecBackend.findBinary() != nil else { return "Not installed" }
        return CodexExecBackend.isLoggedIn ? "Signed in with ChatGPT" : "Installed — not signed in"
    }

    private var displayedWakeWord: String {
        let word = store.assistantWakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? DefaultAssistantWakeWord : word
    }

    private var pickerModels: [OpenRouterModel] {
        if modelCatalog.models.contains(where: { $0.id == store.agentModel }) {
            return modelCatalog.models
        }
        return modelCatalog.models + [.fallback(id: store.agentModel)]
    }

    private var selectedModelDetail: String {
        pickerModels.first(where: { $0.id == store.agentModel })?.detail ?? ""
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $store.agentBackend) {
                    Text("ChatGPT subscription (Codex)").tag(AgentBackendCodex)
                    Text("OpenCode harness (OpenRouter)").tag(AgentBackendOpenCode)
                } label: {
                    SettingRowLabel(title: "Backend",
                                    subtitle: "What powers the assistant's replies")
                }
                .pickerStyle(.menu)
                if store.agentBackend == AgentBackendCodex {
                    LabeledContent {
                        Text(codexStatus).foregroundStyle(.secondary)
                    } label: {
                        SettingRowLabel(title: "Codex CLI",
                                        subtitle: "Sign in once with “codex login” in Terminal — no API billing")
                    }
                } else {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(openCodeStatus).foregroundStyle(.secondary)
                            Button("Refresh") {
                                Task { await refreshOpenCodeStatus() }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Refresh OpenCode runtime health")
                        }
                    } label: {
                        SettingRowLabel(title: "OpenCode",
                                        subtitle: "Supervised by Voice Flow; model requests use your key below")
                    }
                }
            } header: {
                Text("Backend")
            } footer: {
                Text("This is the default for new conversations. Each Assistant conversation can switch between Codex and OpenCode from its own header.")
            }

            Section {
                APIKeyRow(
                    label: "OpenRouter API key",
                    placeholder: "sk-or-…",
                    hasKey: store.hasAgentKey,
                    draft: $store.agentKeyDraft,
                    message: store.agentKeyMessage,
                    onSave: { store.saveAgentKey() },
                    onRemove: { store.removeAgentKey() }
                )
            } header: {
                Text("Account")
            } footer: {
                Text(store.agentBackend == AgentBackendCodex
                     ? "Optional with the subscription backend — used as the fallback, and for anything Codex can't do."
                     : "The assistant needs an OpenRouter key (openrouter.ai) to answer questions, see your screen, and help you work.")
            }

            Section {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 5) {
                        OpenRouterModelPicker(
                            selection: $store.agentModel,
                            models: pickerModels)
                            .frame(minWidth: 360, minHeight: 26)
                        HStack(spacing: 8) {
                            Text(selectedModelDetail)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if refreshingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    Task { await refreshOpenRouterModels() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Refresh OpenRouter models")
                                .accessibilityLabel("Refresh OpenRouter models")
                            }
                        }
                        .font(.caption)
                        Text(modelCatalog.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    SettingRowLabel(title: "OpenCode model",
                                    subtitle: "Default for new OpenCode conversations")
                }
                LabeledContent {
                    TextField("", value: $store.agentDailyBudgetUSD,
                              format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Agent daily budget in US dollars")
                } label: {
                    SettingRowLabel(title: "Daily budget",
                                    subtitle: "Voice Flow stops new OpenCode requests at this total")
                }
            } header: {
                Text("Intelligence")
            } footer: {
                Text("Voice Flow reads context and output limits from OpenRouter and supplies them to OpenCode automatically. Automations pin their own model; the daily budget remains your cost guardrail.")
            }

            Section {
                Toggle(isOn: $store.assistantWakeEnabled) {
                    SettingRowLabel(title: "Wake the Assistant by voice",
                                    subtitle: "Start a normal dictation with the wake word to send it to the Assistant")
                }
                LabeledContent {
                    TextField("", text: $store.assistantWakeWord,
                              prompt: Text(DefaultAssistantWakeWord))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .multilineTextAlignment(.trailing)
                        .disabled(!store.assistantWakeEnabled)
                } label: {
                    SettingRowLabel(title: "Wake word")
                }
            } header: {
                Text("Voice wake")
            } footer: {
                Text("Say “\(displayedWakeWord), …” anywhere. Voice Flow strips the wake word and sends the rest to your active Assistant conversation instead of pasting it.")
            }

            Section {
                Toggle(isOn: $store.queueEnabled) {
                    SettingRowLabel(title: "Show the next queue",
                                    subtitle: "A small on-screen list of what you planned next. It resurfaces briefly at transition moments; when it's empty during active hours it stays up until you fill it.")
                }
            } header: {
                Text("Next queue")
            } footer: {
                Text("Tell your Assistant what to queue (“FLORA, add … to my queue”), or edit ~/.config/voice-flow/queue/queue.json directly — the file is the queue.")
            }

            Section {
                Toggle(isOn: $store.assistantComputerUse) {
                    SettingRowLabel(title: "Let the Assistant control this Mac",
                                    subtitle: "FLORA can move the mouse, click, and type during her turns — without per-action confirmation. Off keeps her to screenshots only.")
                }
            } header: {
                Text("Computer use")
            }

            Section {
                ClaudeConnectionRow()
                Toggle(isOn: $store.doubleSelectSpeak) {
                    SettingRowLabel(title: "Re-select a session to hear its messages",
                                    subtitle: "Selecting the already-active session again (⌃⌥number or the menu) reads its waiting messages aloud. Messages never auto-play on arrival.")
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Capture shortcuts route from the conversation visibly open in the panel or pill. With no conversation open, Dictate pastes its text, Snapshot pastes a saved-image reference, and Continuous pastes its bundle prompt.")
            }

            Section("Advanced") {
                LabeledContent {
                    TextField("", text: $store.agentBaseURL, prompt: Text(DefaultAgentBaseURL))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                        .multilineTextAlignment(.trailing)
                } label: {
                    SettingRowLabel(title: "API address",
                                    subtitle: "Only change this to use an OpenRouter-compatible server")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshOpenCodeStatus()
            await refreshOpenRouterModels()
        }
    }

    @MainActor
    private func refreshOpenCodeStatus() async {
        let status = await OpenCodeAgentRuntime().status()
        let version = status.version.map { " · v\($0)" } ?? ""
        switch status.health {
        case .healthy: openCodeStatus = "Healthy\(version)"
        case .starting: openCodeStatus = "Starting\(version)"
        case .degraded: openCodeStatus = "Degraded\(version)"
        case .crashed: openCodeStatus = "Crashed\(version)"
        case .versionMismatch: openCodeStatus = "Version mismatch\(version)"
        case .stopped: openCodeStatus = "Ready · starts on demand"
        }
    }

    @MainActor
    private func refreshOpenRouterModels() async {
        refreshingModels = true
        defer { refreshingModels = false }
        let configured = store.agentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(string: configured.isEmpty ? DefaultAgentBaseURL : configured)
            ?? URL(string: DefaultAgentBaseURL)!
        modelCatalog = await OpenRouterModelCatalog.shared.refresh(
            baseURL: baseURL,
            apiKey: KeychainStore.shared.loadAgentAPIKey(),
            fallbackIDs: [store.agentModel])
    }
}

private struct WatcherSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var cameras: [(id: String, name: String)] = []

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.workflowWatcherEnabled) {
                    SettingRowLabel(title: "Watch my workflow",
                                    subtitle: "An amber ring on the pill shows whenever it's recording")
                }
            } header: {
                Text("Screen Watcher")
            } footer: {
                Text("Logs the frontmost app, window title, and browser page every few seconds, plus a screenshot when the screen changed. Pauses while you're idle or the screen is locked. Everything stays on this Mac in ~/.config/voice-flow/watcher.")
            }

            Section {
                Toggle(isOn: $store.watcherActionsEnabled) {
                    SettingRowLabel(title: "Record what I do, not just what's on screen",
                                    subtitle: "Typing, clicks, scrolls and shortcuts, as readable actions")
                }
            } footer: {
                Text("Turns raw input into one line per action \u{2014} \u{201C}typed \u{2026}\u{201D}, \u{201C}clicked\u{201D}, \u{201C}scrolled\u{201D} \u{2014} which is what tells reading a reply apart from writing one. Typed text is saved as written, except in terminals, password fields, password managers and short number entries, which are recorded as a length only. Takes effect immediately; turning it off stops the capture at once.")
            }

            Section("Capture") {
                HStack {
                    SettingRowLabel(title: "Tick interval",
                                    subtitle: "How often to sample the screen")
                    Spacer()
                    Slider(value: $store.watcherInterval, in: 2...15, step: 1)
                        .frame(width: 170)
                    Text("\(Int(store.watcherInterval)) s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    SettingRowLabel(title: "Pause when idle",
                                    subtitle: "Stop capturing after this much inactivity")
                    Spacer()
                    Slider(value: $store.watcherIdlePause, in: 30...300, step: 15)
                        .frame(width: 170)
                    Text("\(Int(store.watcherIdlePause)) s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    SettingRowLabel(title: "Keep history",
                                    subtitle: "Day folders older than this are deleted; reviews and the ledger are kept forever")
                    Spacer()
                    Slider(value: $store.watcherKeepDays, in: 7...90, step: 1)
                        .frame(width: 170)
                    Text("\(Int(store.watcherKeepDays)) d")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section {
                Picker(selection: $store.watcherCameraId) {
                    Text("Off").tag("")
                    ForEach(cameras, id: \.id) { cam in
                        Text(cam.name).tag(cam.id)
                    }
                    if !store.watcherCameraId.isEmpty,
                       !cameras.contains(where: { $0.id == store.watcherCameraId }) {
                        Text("Disconnected camera").tag(store.watcherCameraId)
                    }
                } label: {
                    SettingRowLabel(title: "Body camera",
                                    subtitle: "One frame per tick from a camera pointed at you — posture, lighting, environment")
                }
                .onAppear { cameras = CameraGrabber.availableCameras() }
            } header: {
                Text("Camera")
            } footer: {
                Text("Connect any camera the Mac can see (a mirrorless over an HDMI capture dongle works best) and pick it here. Frames are deduped on motion, stored as cam-*.jpg next to the screen captures, and never leave this Mac. First use asks for camera permission.")
            }

            Section {
                LabeledContent {
                    Button("Run Now") { WatcherActions.runReviewNow() }
                } label: {
                    SettingRowLabel(title: "Nightly review",
                                    subtitle: "Claude Code reads the day's activity at 21:37 each night and suggests workflow optimizations (LaunchAgent com.voiceflow.watcher-analyze)")
                }
                LabeledContent {
                    HStack {
                        Button("Latest Review") { WatcherActions.openLatestReview() }
                        Button("Data Folder") { WatcherActions.openDataFolder() }
                    }
                } label: {
                    SettingRowLabel(title: "Files",
                                    subtitle: "Reviews, the observations ledger, and captured frames")
                }
            } header: {
                Text("Analysis")
            } footer: {
                Text("To stop the nightly review entirely: launchctl bootout gui/$UID ~/Library/LaunchAgents/com.voiceflow.watcher-analyze.plist")
            }
        }
        .formStyle(.grouped)
    }
}

private enum WatcherActions {
    static func runReviewNow() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "gui/\(getuid())/com.voiceflow.watcher-analyze"]
        try? proc.run()
    }

    static func openLatestReview() {
        let dir = WorkflowWatcher.baseDir.appendingPathComponent("reviews")
        let newest = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
        NSWorkspace.shared.open(newest ?? dir)
    }

    static func openDataFolder() {
        NSWorkspace.shared.open(WorkflowWatcher.baseDir)
    }
}

// Whether Claude Code has actually talked to the MCP server, plus the
// one-time registration command (the server is useless until it's run).
private struct ClaudeConnectionRow: View {
    @State private var lastActivity: Date? = MCPServer.lastActivity
    @State private var copied = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        LabeledContent {
            Button(copied ? "Copied" : "Copy Setup Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MCPServer.registerCommand, forType: .string)
                copied = true
            }
        } label: {
            SettingRowLabel(title: "Connection", subtitle: subtitle)
        }
        .onReceive(refresh) { _ in
            lastActivity = MCPServer.lastActivity
            copied = false
        }
    }

    private var subtitle: String {
        guard let lastActivity else {
            return "No requests from Claude Code since Voice Flow started. Register it once: copy the setup command and run it in Terminal."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Connected — last request \(formatter.localizedString(for: lastActivity, relativeTo: Date()))"
    }
}

// ── Shortcuts tab ──

private struct ShortcutsSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                ShortcutRow(title: "Dictate",
                            subtitle: "Hold to talk, release to type what you said",
                            spec: store.hotkey) { store.setHotkey(.dictate, $0) }
                ShortcutRow(title: "Toggle dictate to Inbox",
                            subtitle: "Press twice quickly to start, once to stop — uses Dictate but never pastes or sends",
                            spec: store.handsFreeHotkey) { store.setHotkey(.handsFree, $0) }
                ShortcutRow(title: "Dictate + snapshot",
                            subtitle: "Hold to speak and capture the screen at release",
                            spec: store.snapshotHotkey) { store.setHotkey(.snapshot, $0) }
                ShortcutRow(title: "Continuous dictate + snapshots",
                            subtitle: "Toggle voice and deduped screen capture; saves an ordered bundle",
                            spec: store.continuousCaptureHotkey) { store.setHotkey(.continuousCapture, $0) }
            } header: {
                Text("Capture")
            } footer: {
                Text("An open assistant or session receives the capture. Otherwise Dictate pastes, while the toggle shortcut keeps the words only in Inbox.")
            }

            Section {
                ShortcutRow(title: "Read aloud",
                            subtitle: "Speaks the selected text — press again to stop speaking",
                            spec: store.ttsHotkey) { store.setHotkey(.tts, $0) }
                ShortcutRow(title: "Draw on the screen",
                            subtitle: "Circle or write on the screen — your marks appear in every screenshot Claude sees",
                            spec: store.annotateHotkey) { store.setHotkey(.annotate, $0) }
            } header: {
                Text("Other")
            } footer: {
                Text("Click a shortcut, then press the key or combination you'd like to use. Press Esc to cancel.")
            }
        }
        .formStyle(.grouped)
    }
}

// ── Window controller (public API unchanged) ──

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onHotkeyChanged = onHotkeyChanged } }
    var onHandsFreeHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onHandsFreeHotkeyChanged = onHandsFreeHotkeyChanged } }
    var onTTSHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onTTSHotkeyChanged = onTTSHotkeyChanged } }
    var onContinuousCaptureHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onContinuousCaptureHotkeyChanged = onContinuousCaptureHotkeyChanged } }
    var onSnapshotHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onSnapshotHotkeyChanged = onSnapshotHotkeyChanged } }
    var onAnnotateHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onAnnotateHotkeyChanged = onAnnotateHotkeyChanged } }
    var onSettingsChanged: (() -> Void)? { didSet { store.onSettingsChanged = onSettingsChanged } }
    var onWindowClosed: (() -> Void)?

    private let store = SettingsStore()
    private let tabController = NSTabViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        tabController.tabStyle = .toolbar
        addTab("Dictation", symbol: "mic.fill", height: 680,
               view: DictationSettingsView(store: store))
        addTab("Voice", symbol: "speaker.wave.2.fill", height: 300,
               view: VoiceSettingsView(store: store))
        addTab("Assistant", symbol: "sparkles", height: 780,
               view: AssistantSettingsView(store: store))
        addTab("Watcher", symbol: "eye.fill", height: 560,
               view: WatcherSettingsView(store: store))
        addTab("Shortcuts", symbol: "keyboard.fill", height: 560,
               view: ShortcutsSettingsView(store: store))

        window.contentViewController = tabController
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func prepareForPresentation() {
        store.reloadAssistantSettings()
    }

    private func addTab<V: View>(_ label: String, symbol: String, height: CGFloat, view: V) {
        let hosting = NSHostingController(rootView: view.frame(width: 680))
        hosting.preferredContentSize = NSSize(width: 680, height: height)
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabController.addTabViewItem(item)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        onWindowClosed?()
        return false
    }

#if VOICE_FLOW_QA
    var qaAssistantVisible: Bool {
        window?.isVisible == true && tabController.selectedTabViewItemIndex == 2
    }

    var qaAssistantState: [String: Any] {
        guard let content = window?.contentView else { return [:] }
        let views = qaDescendants(of: content)
        let combo = views.compactMap { $0 as? OpenRouterModelComboBox }.first
        return [
            "model_accessibility_label": combo?.accessibilityLabel() ?? "",
            "model_text": combo?.stringValue ?? "",
            "model_count": combo?.allModels.count ?? 0,
            "model_width": Int(combo?.bounds.width ?? 0),
            "default_model": UserSettings.shared.agentModel,
            "visible_text": views.compactMap { ($0 as? NSTextField)?.stringValue },
        ]
    }

    func qaShowAssistant() {
        prepareForPresentation()
        tabController.selectedTabViewItemIndex = 2
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func qaClose() { window?.orderOut(nil) }

    @discardableResult
    func qaSelectModel(id: String) -> Bool {
        guard let content = window?.contentView,
              let combo = qaDescendants(of: content)
                .compactMap({ $0 as? OpenRouterModelComboBox }).first else { return false }
        return combo.selectModel(id: id)
    }

    func qaSnapshot() throws -> (path: String, width: Int, height: Int) {
        guard let view = window?.contentView else {
            throw NSError(
                domain: "VoiceFlowQA", code: 41,
                userInfo: [NSLocalizedDescriptionKey: "Settings content view is unavailable."])
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(
                domain: "VoiceFlowQA", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Settings bitmap allocation failed."])
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "VoiceFlowQA", code: 43,
                userInfo: [NSLocalizedDescriptionKey: "Settings PNG encoding failed."])
        }
        let url = VoiceFlowPaths.shared.directory("qa-artifacts")
            .appendingPathComponent("settings-opencode-model-picker.png")
        try png.write(to: url, options: .atomic)
        return (url.path, bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    private func qaDescendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(qaDescendants(of:))
    }
#endif
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Permissions Window — friendly onboarding checklist
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct PermissionViewState {
    let statusText: String
    let statusColor: NSColor
    let actionTitle: String
    let actionEnabled: Bool

    var isGranted: Bool { !actionEnabled && actionTitle == "Granted" }
}

final class PermissionsStore: ObservableObject {
    @Published var microphone: PermissionViewState?
    @Published var screenCapture: PermissionViewState?
    @Published var accessibility: PermissionViewState?
    @Published var allGranted = false

    var onRequestMicrophone: (() -> Void)?
    var onRequestScreenCapture: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onDone: (() -> Void)?
}

private struct PermissionRowView: View {
    let symbol: String
    let title: String
    let detail: String
    let state: PermissionViewState?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let state, !state.isGranted, state.statusText.count > 24 {
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            if let state {
                if state.isGranted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button(state.actionTitle == "Request" ? "Allow…" : state.actionTitle, action: action)
                        .disabled(!state.actionEnabled)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct PermissionsView: View {
    @ObservedObject var store: PermissionsStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(store.allGranted ? "You're all set" : "Let Voice Flow work with your Mac")
                    .font(.title2.weight(.semibold))
                Text(store.allGranted
                     ? "Voice Flow has everything it needs. You can close this window."
                     : "Voice Flow needs three macOS permissions. Click Allow for each one and confirm in the system dialog — this only happens once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            VStack(spacing: 0) {
                PermissionRowView(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "Hear you when you dictate or talk to the assistant",
                    state: store.microphone,
                    action: { store.onRequestMicrophone?() }
                )
                Divider()
                PermissionRowView(
                    symbol: "rectangle.inset.filled.badge.record",
                    title: "Screen Recording",
                    detail: "Let the assistant see your screen when you ask about it",
                    state: store.screenCapture,
                    action: { store.onRequestScreenCapture?() }
                )
                Divider()
                PermissionRowView(
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Enables keyboard shortcuts and lets dictation type for you",
                    state: store.accessibility,
                    action: { store.onRequestAccessibility?() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            HStack {
                Text("Statuses update automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if store.allGranted {
                    Button("Done") { store.onDone?() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .frame(width: 560)
    }
}

class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    var onRequestMicrophone: (() -> Void)? { didSet { store.onRequestMicrophone = onRequestMicrophone } }
    var onRequestScreenCapture: (() -> Void)? { didSet { store.onRequestScreenCapture = onRequestScreenCapture } }
    var onRequestAccessibility: (() -> Void)? { didSet { store.onRequestAccessibility = onRequestAccessibility } }
    var onRefresh: (() -> Void)?
    var onWindowClosed: (() -> Void)?

    private let store = PermissionsStore()
    private var refreshTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Permissions"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        store.onDone = { [weak self] in self?.window?.performClose(nil) }
        window.contentViewController = NSHostingController(rootView: PermissionsView(store: store))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startAutoRefresh()
    }

    func update(
        microphone: PermissionViewState,
        screenCapture: PermissionViewState,
        accessibility: PermissionViewState,
        allGranted: Bool
    ) {
        store.microphone = microphone
        store.screenCapture = screenCapture
        store.accessibility = accessibility
        store.allGranted = allGranted
    }

    private func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.onRefresh?()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopAutoRefresh()
        sender.orderOut(nil)
        onWindowClosed?()
        return false
    }
}
