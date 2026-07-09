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
    var onSessionHotkeyChanged: ((HotkeySpec) -> Void)?
    var onTalkHotkeyChanged: ((HotkeySpec) -> Void)?
    var onSnapTalkHotkeyChanged: ((HotkeySpec) -> Void)?
    var onAnnotateHotkeyChanged: ((HotkeySpec) -> Void)?
    var onSettingsChanged: (() -> Void)?

    @Published var provider: DictationProvider { didSet { commit() } }
    @Published var soundsEnabled: Bool { didSet { commit() } }
    @Published var llmCleanupEnabled: Bool { didSet { commit() } }
    @Published var vocabularyText: String { didSet { commit() } }
    @Published var doubleTapMs: Double { didSet { commit() } }
    @Published var ttsVoice: String { didSet { commit() } }
    @Published var ttsSpeed: Double { didSet { commit() } }
    @Published var agentModel: String { didSet { commit() } }
    @Published var agentBaseURL: String { didSet { commit() } }
    @Published var sessionSendToAgent: Bool { didSet { commit() } }
    @Published var talkSendToAgent: Bool { didSet { commit() } }

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
    @Published var sessionHotkey: HotkeySpec
    @Published var talkHotkey: HotkeySpec
    @Published var snapTalkHotkey: HotkeySpec
    @Published var annotateHotkey: HotkeySpec

    private var loaded = false

    init() {
        let s = UserSettings.shared
        provider = s.dictationProvider
        soundsEnabled = s.soundsEnabled
        llmCleanupEnabled = s.llmCleanupEnabled
        vocabularyText = s.customVocabulary.joined(separator: ", ")
        doubleTapMs = Double(s.doubleTapMs)
        ttsVoice = s.ttsVoice
        ttsSpeed = s.ttsSpeed
        agentModel = s.agentModel
        agentBaseURL = s.agentBaseURL
        sessionSendToAgent = s.sessionSendToAgent
        talkSendToAgent = s.talkSendToAgent
        hasOpenAIKey = KeychainStore.shared.hasOpenAIAPIKey
        hasAgentKey = KeychainStore.shared.hasAgentAPIKey
        hotkey = s.hotkey
        handsFreeHotkey = s.handsFreeHotkey
        ttsHotkey = s.ttsHotkey
        sessionHotkey = s.sessionHotkey
        talkHotkey = s.talkHotkey
        snapTalkHotkey = s.snapTalkHotkey
        annotateHotkey = s.annotateHotkey
        loaded = true
    }

    var needsOpenAIKey: Bool { provider == .openai && !hasOpenAIKey }

    private func commit() {
        guard loaded else { return }
        let s = UserSettings.shared
        s.dictationProvider = provider
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
        s.sessionSendToAgent = sessionSendToAgent
        s.talkSendToAgent = talkSendToAgent
        s.save()
        onSettingsChanged?()
    }

    enum HotkeyKind { case dictate, handsFree, tts, session, talk, snapTalk, annotate }

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
        case .session:
            guard spec.keyCode != s.sessionHotkey.keyCode || spec.modifiers != s.sessionHotkey.modifiers else { return }
            s.sessionHotkey = spec; sessionHotkey = spec; onSessionHotkeyChanged?(spec)
        case .talk:
            guard spec.keyCode != s.talkHotkey.keyCode || spec.modifiers != s.talkHotkey.modifiers else { return }
            s.talkHotkey = spec; talkHotkey = spec; onTalkHotkeyChanged?(spec)
        case .snapTalk:
            guard spec.keyCode != s.snapTalkHotkey.keyCode || spec.modifiers != s.snapTalkHotkey.modifiers else { return }
            s.snapTalkHotkey = spec; snapTalkHotkey = spec; onSnapTalkHotkeyChanged?(spec)
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

    var body: some View {
        Form {
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

    var body: some View {
        Form {
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
                Text("The assistant needs an OpenRouter key (openrouter.ai) to answer questions, see your screen, and help you work.")
            }

            Section {
                LabeledContent {
                    TextField("", text: $store.agentModel, prompt: Text(DefaultAgentModel))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                        .multilineTextAlignment(.trailing)
                } label: {
                    SettingRowLabel(title: "Model",
                                    subtitle: "Any OpenRouter model that supports images and tools")
                }
            } header: {
                Text("Intelligence")
            }

            Section {
                ClaudeConnectionRow()
                Toggle(isOn: $store.talkSendToAgent) {
                    SettingRowLabel(title: "Talk hotkeys go to the in-app assistant",
                                    subtitle: "Off: talking with the Talk / Talk + snap shortcuts sends your words to Claude Code — instantly when Claude is listening, queued otherwise")
                }
                Toggle(isOn: $store.sessionSendToAgent) {
                    SettingRowLabel(title: "Sessions go to the in-app assistant",
                                    subtitle: "Off: session recordings are saved as capture bundles (voice + ordered screenshots) for Claude Code")
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Once connected, Claude can ask you questions on screen, receive your voice messages and captures, place guides and panels, draw on your screen, and speak to you. These switches re-route the hotkeys to the built-in assistant instead.")
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
                ShortcutRow(title: "Hands-free dictation",
                            subtitle: "Press twice quickly to start, once to stop",
                            spec: store.handsFreeHotkey) { store.setHotkey(.handsFree, $0) }
                ShortcutRow(title: "Read aloud",
                            subtitle: "Speaks the selected text — press again to stop speaking",
                            spec: store.ttsHotkey) { store.setHotkey(.tts, $0) }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Click a shortcut, then press the key or combination you'd like to use. Press Esc to cancel.")
            }

            Section {
                ShortcutRow(title: "Talk to Claude",
                            subtitle: "Hold to speak — answers a waiting question, or queues a voice message Claude picks up when it checks in",
                            spec: store.talkHotkey) { store.setHotkey(.talk, $0) }
                ShortcutRow(title: "Talk + snap for Claude",
                            subtitle: "Hold to speak and attach a screenshot of what you're looking at",
                            spec: store.snapTalkHotkey) { store.setHotkey(.snapTalk, $0) }
                ShortcutRow(title: "Record a capture session",
                            subtitle: "Records your voice and screen while you demonstrate something; saves a capture bundle for Claude when you stop",
                            spec: store.sessionHotkey) { store.setHotkey(.session, $0) }
                ShortcutRow(title: "Draw on the screen",
                            subtitle: "Circle or write on the screen — your marks appear in every screenshot Claude sees",
                            spec: store.annotateHotkey) { store.setHotkey(.annotate, $0) }
            } header: {
                Text("Claude & assistant")
            } footer: {
                Text("These shortcuts talk to Claude Code through the Voice Flow MCP server. Flip the switches in the Assistant tab to route them to the built-in assistant instead.")
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
    var onSessionHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onSessionHotkeyChanged = onSessionHotkeyChanged } }
    var onTalkHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onTalkHotkeyChanged = onTalkHotkeyChanged } }
    var onSnapTalkHotkeyChanged: ((HotkeySpec) -> Void)? { didSet { store.onSnapTalkHotkeyChanged = onSnapTalkHotkeyChanged } }
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
        addTab("Dictation", symbol: "mic.fill", height: 560,
               view: DictationSettingsView(store: store))
        addTab("Voice", symbol: "speaker.wave.2.fill", height: 300,
               view: VoiceSettingsView(store: store))
        addTab("Assistant", symbol: "sparkles", height: 620,
               view: AssistantSettingsView(store: store))
        addTab("Shortcuts", symbol: "keyboard.fill", height: 560,
               view: ShortcutsSettingsView(store: store))

        window.contentViewController = tabController
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

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
