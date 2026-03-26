import Cocoa
import AVFoundation
import CoreGraphics
import Accelerate
import Security

func vflog(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow/app.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Hotkey Spec (keyCode + optional modifier combo)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct HotkeySpec {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
    let label: String

    private static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    var isModifierOnly: Bool { Self.modifierKeyCodes.contains(Int(keyCode)) }
    var triggerModifierFlag: CGEventFlags? { Self.modifierFlag(for: keyCode) }

    static func buildLabel(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
        modifierLabel(for: modifiers) + keyCodeName(keyCode)
    }

    static func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 54, 55:
            return .maskCommand
        case 56, 60:
            return .maskShift
        case 58, 61:
            return .maskAlternate
        case 59, 62:
            return .maskControl
        case 63:
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    static func modifierLabel(for modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("⌃") }
        if modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(.maskShift) { parts.append("⇧") }
        if modifiers.contains(.maskCommand) { parts.append("⌘") }
        if modifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
        return parts.joined()
    }

    static func keyCodeName(_ kc: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            50: "`", 51: "Delete", 53: "Escape",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15",
            122: "F1", 120: "F2", 118: "F4",
            54: "Right ⌘", 55: "Left ⌘",
            56: "Left ⇧", 57: "Caps Lock",
            58: "Left ⌥", 59: "Left ⌃",
            60: "Right ⇧", 61: "Right ⌥",
            62: "Right ⌃", 63: "Fn",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[kc] ?? "Key\(kc)"
    }

    func toDict() -> [String: Any] {
        ["key_code": Int(keyCode), "modifiers": modifiers.rawValue, "label": label]
    }

    static func fromDict(_ dict: [String: Any]) -> HotkeySpec? {
        guard let kc = dict["key_code"] as? Int,
              let mods = dict["modifiers"] as? UInt64 else { return nil }
        let label = dict["label"] as? String
            ?? buildLabel(keyCode: CGKeyCode(kc), modifiers: CGEventFlags(rawValue: mods))
        return HotkeySpec(keyCode: CGKeyCode(kc), modifiers: CGEventFlags(rawValue: mods), label: label)
    }

    /// Convert old string format ("alt_r", "f6", etc.) to HotkeySpec
    static func fromLegacy(_ name: String) -> HotkeySpec {
        let legacyMap: [String: CGKeyCode] = [
            "alt_r": 61, "alt_l": 58, "ctrl_r": 62, "ctrl_l": 59,
            "fn": 63, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        ]
        let kc = legacyMap[name] ?? 61
        return HotkeySpec(keyCode: kc, modifiers: [], label: keyCodeName(kc))
    }
}

enum DictationProvider: String, CaseIterable {
    case local
    case openai

    var label: String {
        switch self {
        case .local:
            return "Local (on-device)"
        case .openai:
            return "OpenAI API"
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Settings (JSON at ~/.config/voice-flow/settings.json)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class UserSettings {
    static let shared = UserSettings()
    var dictationProvider: DictationProvider = .local
    var hotkey = HotkeySpec(keyCode: 63, modifiers: [], label: "Fn")
    var handsFreeHotkey = HotkeySpec(keyCode: 97, modifiers: [], label: "F6")
    var ttsHotkey = HotkeySpec(keyCode: 100, modifiers: [], label: "F8")
    var soundsEnabled: Bool = true
    var doubleTapMs: Int = 400
    var llmCleanupEnabled: Bool = true
    var ttsVoice: String = "alloy"
    var ttsSpeed: Double = 1.0
    var ttsInstructions: String = DefaultTTSInstructions

    // Foundry gateway
    var captureIntervalSeconds: Int = 30
    var captureHotkey = HotkeySpec(keyCode: 61, modifiers: [], label: "Right ⌥")
    var captureNoteHotkey = HotkeySpec(keyCode: 98, modifiers: [], label: "F7")
    var gatewayHost: String = "127.0.0.1"
    var gatewayWSPort: Int = 8789
    var gatewayHTTPPort: Int = 8791
    var tenantId: String = "local"
    var appId: String = "voice-flow"
    var userId: String = UserSettings.defaultFoundryUserId()
    var agentType: String = "eyes"
    var sessionLabel: String = "voice-flow"

    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    private func loadHotkey(_ dict: [String: Any], key: String, fallback: HotkeySpec) -> HotkeySpec {
        if let d = dict[key] as? [String: Any], let spec = HotkeySpec.fromDict(d) { return spec }
        if let s = dict[key] as? String { return HotkeySpec.fromLegacy(s) }
        return fallback
    }

    private static func trimmed(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
    }

    private static func defaultFoundryUserId() -> String {
        let raw = trimmed(NSUserName(), fallback: "local-user")
        let safe = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? "local-user" : safe
    }

    var foundryConfig: FoundryGatewayConfig {
        FoundryGatewayConfig(
            gatewayHost: Self.trimmed(gatewayHost, fallback: "127.0.0.1"),
            gatewayWSPort: max(1, gatewayWSPort),
            gatewayHTTPPort: max(1, gatewayHTTPPort),
            tenantId: Self.trimmed(tenantId, fallback: "local"),
            appId: Self.trimmed(appId, fallback: "voice-flow"),
            userId: Self.trimmed(userId, fallback: Self.defaultFoundryUserId()),
            agentType: Self.trimmed(agentType, fallback: "eyes"),
            sessionLabel: Self.trimmed(sessionLabel, fallback: "voice-flow")
        )
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let hadTTSInstructions = dict.keys.contains("tts_instructions")
        if let raw = dict["dictation_provider"] as? String,
           let provider = DictationProvider(rawValue: raw) {
            dictationProvider = provider
        }
        hotkey = loadHotkey(dict, key: "hotkey", fallback: hotkey)
        handsFreeHotkey = loadHotkey(dict, key: "hands_free_hotkey", fallback: handsFreeHotkey)
        ttsHotkey = loadHotkey(dict, key: "tts_hotkey", fallback: ttsHotkey)
        captureHotkey = loadHotkey(dict, key: "capture_hotkey", fallback: captureHotkey)
        captureNoteHotkey = loadHotkey(dict, key: "capture_note_hotkey", fallback: captureNoteHotkey)
        if let v = dict["sounds_enabled"] as? Bool { soundsEnabled = v }
        if let v = dict["double_tap_ms"] as? Int { doubleTapMs = v }
        if let v = dict["llm_cleanup_enabled"] as? Bool { llmCleanupEnabled = v }
        if let v = dict["tts_voice"] as? String { ttsVoice = v }
        if let v = dict["tts_speed"] as? Double { ttsSpeed = v }
        if let v = dict["tts_speed"] as? Int { ttsSpeed = Double(v) }
        if let v = dict["tts_instructions"] as? String { ttsInstructions = v }
        if !hadTTSInstructions || ttsInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ttsInstructions = DefaultTTSInstructions
        }
        if let v = dict["capture_interval"] as? Int { captureIntervalSeconds = v }
        if let v = dict["gateway_host"] as? String { gatewayHost = v }
        if let v = dict["gateway_ws_port"] as? Int { gatewayWSPort = v }
        if let v = dict["gateway_http_port"] as? Int { gatewayHTTPPort = v }
        if let v = dict["tenant_id"] as? String { tenantId = v }
        if let v = dict["app_id"] as? String { appId = v }
        if let v = dict["user_id"] as? String { userId = v }
        if let v = dict["agent_type"] as? String { agentType = v }
        if let v = dict["session_label"] as? String { sessionLabel = v }
    }

    func save() {
        let foundry = foundryConfig
        gatewayHost = foundry.gatewayHost
        gatewayWSPort = foundry.gatewayWSPort
        gatewayHTTPPort = foundry.gatewayHTTPPort
        tenantId = foundry.tenantId
        appId = foundry.appId
        userId = foundry.userId
        agentType = foundry.agentType
        sessionLabel = foundry.sessionLabel

        let dict: [String: Any] = [
            "dictation_provider": dictationProvider.rawValue,
            "hotkey": hotkey.toDict(),
            "hands_free_hotkey": handsFreeHotkey.toDict(),
            "tts_hotkey": ttsHotkey.toDict(),
            "sounds_enabled": soundsEnabled,
            "double_tap_ms": doubleTapMs,
            "llm_cleanup_enabled": llmCleanupEnabled,
            "tts_voice": ttsVoice,
            "tts_speed": ttsSpeed,
            "tts_instructions": ttsInstructions,
            "capture_interval": captureIntervalSeconds,
            "capture_hotkey": captureHotkey.toDict(),
            "capture_note_hotkey": captureNoteHotkey.toDict(),
            "gateway_host": foundry.gatewayHost,
            "gateway_ws_port": foundry.gatewayWSPort,
            "gateway_http_port": foundry.gatewayHTTPPort,
            "tenant_id": foundry.tenantId,
            "app_id": foundry.appId,
            "user_id": foundry.userId,
            "agent_type": foundry.agentType,
            "session_label": foundry.sessionLabel,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }
}

struct FoundryGatewayConfig: Equatable {
    let gatewayHost: String
    let gatewayWSPort: Int
    let gatewayHTTPPort: Int
    let tenantId: String
    let appId: String
    let userId: String
    let agentType: String
    let sessionLabel: String

    var canonicalSessionId: String {
        let safe = sessionLabel
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? "voice-flow" : safe
    }
}

class KeychainStore {
    static let shared = KeychainStore()

    private let service = "com.voiceflow.app"
    private let openAIAPIKeyAccount = "openai_api_key"

    var hasOpenAIAPIKey: Bool {
        loadOpenAIAPIKey() != nil
    }

    func loadOpenAIAPIKey() -> String? {
        var query = baseQuery(account: openAIAPIKeyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            if status != errSecSuccess {
                vflog("keychain read failed: \(status)")
            }
            return nil
        }
        return key
    }

    @discardableResult
    func saveOpenAIAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let deleteStatus = SecItemDelete(baseQuery(account: openAIAPIKeyAccount) as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            vflog("keychain delete-before-save failed: \(deleteStatus)")
            return false
        }

        var query = baseQuery(account: openAIAPIKeyAccount)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            vflog("keychain save failed: \(status)")
            return false
        }
        return true
    }

    @discardableResult
    func removeOpenAIAPIKey() -> Bool {
        let status = SecItemDelete(baseQuery(account: openAIAPIKeyAccount) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            vflog("keychain delete failed: \(status)")
            return false
        }
        return true
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Hotkey Manager (CGEventTap)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private final class WeakHotkeyManagerRef {
    weak var value: HotkeyManager?

    init(_ value: HotkeyManager) {
        self.value = value
    }
}

class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onHandsFree: ((Bool) -> Void)?
    var allowsHandsFreeDoublePress = false

    private var keyCode: CGKeyCode
    private var requiredModifiers: CGEventFlags = []
    private var pressed = false
    private var handsFree = false
    private var pressTime: TimeInterval = 0
    private var pendingRelease = false
    private var pendingTimer: Timer?
    private var pendingActivation = false
    private var pendingActivationTimer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private var pressedModifierKeyCodes: Set<CGKeyCode> = []
    private var doubleTapWaitingForSecond = false
    private var doubleTapTimer: Timer?
    private var doubleTapExactDown = false
    private var doubleTapSessionActive = false
    private var doubleTapContaminated = false

    private static let interestingModifiers: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn
    ]
    private static let chordResolutionDelay: TimeInterval = 0.12
    private static var registry: [WeakHotkeyManagerRef] = []

    init(spec: HotkeySpec) {
        self.keyCode = spec.keyCode
        self.requiredModifiers = spec.modifiers
        Self.registry = Self.registry.filter { $0.value != nil }
        Self.registry.append(WeakHotkeyManagerRef(self))
    }

    func updateSpec(_ spec: HotkeySpec) {
        keyCode = spec.keyCode
        requiredModifiers = spec.modifiers
        pressed = false
        handsFree = false
        pendingRelease = false
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingActivation = false
        pendingActivationTimer?.invalidate()
        pendingActivationTimer = nil
        pressedModifierKeyCodes.removeAll()
        resetDoubleTapState()
    }

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                mgr.handleEvent(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            vflog("CGEventTap failed — accessibility not granted?")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        vflog("hotkey listener started (keyCode=\(keyCode), mods=\(requiredModifiers.rawValue))")
    }

    private func handleEvent(_ event: CGEvent) {
        if allowsHandsFreeDoublePress {
            handleDoublePressEvent(event)
            return
        }

        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let type = event.type

        if type == .flagsChanged {
            updateModifierState(for: kc, flags: event.flags)

            guard let triggerModifier = HotkeySpec.modifierFlag(for: keyCode) else { return }
            let expected = normalizeModifiers(requiredModifiers).union(triggerModifier)
            let held = normalizeModifiers(event.flags)
            let primaryDown = pressedModifierKeyCodes.contains(keyCode)
            if primaryDown && held == expected {
                armOrHandleModifierPress()
            } else {
                cancelPendingActivation()
                handleRelease()
            }
        } else if type == .keyDown || type == .keyUp {
            guard HotkeySpec.modifierFlag(for: keyCode) == nil else { return }
            guard kc == keyCode else { return }
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            let held = normalizeModifiers(event.flags)
            let required = normalizeModifiers(requiredModifiers)
            guard held == required else { return }
            cancelPendingActivation()
            if type == .keyDown { handlePress() } else { handleRelease() }
        }
    }

    private func handlePress() {
        if !allowsHandsFreeDoublePress {
            guard !pressed else { return }
            pressed = true
            DispatchQueue.main.async { self.onPress?() }
            return
        }

        if handsFree {
            handsFree = false
            DispatchQueue.main.async { self.onHandsFree?(false) }
            DispatchQueue.main.async { self.onRelease?() }
            return
        }
        if pendingRelease {
            pendingRelease = false
            pendingTimer?.invalidate()
            pendingTimer = nil
            handsFree = true
            DispatchQueue.main.async { self.onHandsFree?(true) }
            return
        }
        if !pressed {
            pressed = true
            pressTime = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { self.onPress?() }
        }
    }

    private func handleRelease() {
        if pendingActivation {
            cancelPendingActivation()
            if allowsHandsFreeDoublePress {
                if handsFree {
                    handsFree = false
                    DispatchQueue.main.async { self.onHandsFree?(false) }
                } else if pendingRelease {
                    pendingRelease = false
                    pendingTimer?.invalidate()
                    pendingTimer = nil
                    handsFree = true
                    DispatchQueue.main.async { self.onHandsFree?(true) }
                } else {
                    armDoublePressFromAmbiguousTap()
                }
            }
            return
        }
        guard pressed else { return }
        if !allowsHandsFreeDoublePress {
            pressed = false
            DispatchQueue.main.async { self.onRelease?() }
            return
        }

        if handsFree { pressed = false; return }

        let holdMs = (ProcessInfo.processInfo.systemUptime - pressTime) * 1000
        pressed = false
        let threshold = Double(UserSettings.shared.doubleTapMs)

        if holdMs < threshold * 0.6 {
            pendingRelease = true
            pendingTimer = Timer.scheduledTimer(withTimeInterval: threshold / 1000.0, repeats: false) { [weak self] _ in
                guard let self, self.pendingRelease else { return }
                self.pendingRelease = false
                self.onRelease?()
            }
        } else {
            DispatchQueue.main.async { self.onRelease?() }
        }
    }

    private func updateModifierState(for keyCode: CGKeyCode, flags: CGEventFlags) {
        guard HotkeySpec.modifierFlag(for: keyCode) != nil else { return }
        if isModifierKeyDown(keyCode, flags: flags) {
            pressedModifierKeyCodes.insert(keyCode)
        } else {
            pressedModifierKeyCodes.remove(keyCode)
        }
    }

    private func normalizeModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(Self.interestingModifiers)
    }

    private func armOrHandleModifierPress() {
        guard shouldDelayModifierActivation() else {
            cancelPendingActivation()
            handlePress()
            return
        }
        guard !pressed, !pendingActivation else { return }
        pendingActivation = true
        pendingActivationTimer = Timer.scheduledTimer(withTimeInterval: Self.chordResolutionDelay, repeats: false) { [weak self] _ in
            guard let self, self.pendingActivation else { return }
            self.pendingActivation = false
            self.pendingActivationTimer = nil
            self.handlePress()
        }
    }

    private func cancelPendingActivation() {
        pendingActivation = false
        pendingActivationTimer?.invalidate()
        pendingActivationTimer = nil
    }

    private func armDoublePressFromAmbiguousTap() {
        DispatchQueue.main.async { self.onPress?() }
        let threshold = Double(UserSettings.shared.doubleTapMs)
        pendingRelease = true
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: threshold / 1000.0, repeats: false) { [weak self] _ in
            guard let self, self.pendingRelease else { return }
            self.pendingRelease = false
            self.onRelease?()
        }
    }

    private func shouldDelayModifierActivation() -> Bool {
        guard let triggerModifier = HotkeySpec.modifierFlag(for: keyCode) else { return false }
        let currentSet = normalizeModifiers(requiredModifiers).union(triggerModifier)

        for other in Self.activeManagers where other !== self {
            if let otherTriggerModifier = HotkeySpec.modifierFlag(for: other.keyCode) {
                let otherSet = other.normalizeModifiers(other.requiredModifiers).union(otherTriggerModifier)
                if otherSet != currentSet && containsAllModifiers(otherSet, currentSet) {
                    return true
                }
                continue
            }

            let otherRequired = other.normalizeModifiers(other.requiredModifiers)
            if containsAllModifiers(otherRequired, currentSet) {
                return true
            }
        }
        return false
    }

    private func containsAllModifiers(_ flags: CGEventFlags, _ required: CGEventFlags) -> Bool {
        (flags.rawValue & required.rawValue) == required.rawValue
    }

    private static var activeManagers: [HotkeyManager] {
        registry = registry.filter { $0.value != nil }
        return registry.compactMap(\.value)
    }

    private func isModifierKeyDown(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55:
            return flags.contains(.maskCommand)
        case 56, 60:
            return flags.contains(.maskShift)
        case 58, 61:
            return flags.contains(.maskAlternate)
        case 59, 62:
            return flags.contains(.maskControl)
        case 63:
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }

    private func handleDoublePressEvent(_ event: CGEvent) {
        if HotkeySpec.modifierFlag(for: keyCode) != nil {
            handleModifierDoublePressEvent(event)
        } else {
            handleKeyDoublePressEvent(event)
        }
    }

    private func handleModifierDoublePressEvent(_ event: CGEvent) {
        guard event.type == .flagsChanged else { return }

        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        updateModifierState(for: kc, flags: event.flags)

        guard let triggerModifier = HotkeySpec.modifierFlag(for: keyCode) else { return }
        let held = normalizeModifiers(event.flags)
        let expected = normalizeModifiers(requiredModifiers).union(triggerModifier)
        let triggerDown = pressedModifierKeyCodes.contains(keyCode)
        let exact = triggerDown && held == expected
        let contaminated = triggerDown && containsAllModifiers(held, expected) && held != expected

        if !doubleTapSessionActive && triggerDown {
            doubleTapSessionActive = true
            doubleTapContaminated = false
        }
        if contaminated {
            doubleTapContaminated = true
            if doubleTapWaitingForSecond {
                resetDoubleTapWindow()
            }
        }

        if exact && !doubleTapExactDown {
            doubleTapExactDown = true
        }

        if doubleTapExactDown && !exact {
            if !contaminated && !doubleTapContaminated {
                completeDoubleTap()
            }
            doubleTapExactDown = false
        }

        if !triggerDown {
            doubleTapSessionActive = false
            doubleTapContaminated = false
            doubleTapExactDown = false
        }
    }

    private func handleKeyDoublePressEvent(_ event: CGEvent) {
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard kc == keyCode else { return }

        let held = normalizeModifiers(event.flags)
        let required = normalizeModifiers(requiredModifiers)

        if event.type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            guard held == required else { return }
            doubleTapExactDown = true
            return
        }

        guard event.type == .keyUp else { return }
        if doubleTapExactDown && held == required {
            completeDoubleTap()
        }
        doubleTapExactDown = false
    }

    private func completeDoubleTap() {
        if handsFree {
            handsFree = false
            resetDoubleTapWindow()
            DispatchQueue.main.async { self.onHandsFree?(false) }
            return
        }

        if doubleTapWaitingForSecond {
            doubleTapWaitingForSecond = false
            doubleTapTimer?.invalidate()
            doubleTapTimer = nil
            handsFree = true
            DispatchQueue.main.async { self.onHandsFree?(true) }
            return
        }

        let threshold = Double(UserSettings.shared.doubleTapMs)
        doubleTapWaitingForSecond = true
        doubleTapTimer?.invalidate()
        doubleTapTimer = Timer.scheduledTimer(withTimeInterval: threshold / 1000.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.resetDoubleTapWindow()
        }
    }

    private func resetDoubleTapWindow() {
        doubleTapWaitingForSecond = false
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
    }

    private func resetDoubleTapState() {
        resetDoubleTapWindow()
        doubleTapExactDown = false
        doubleTapSessionActive = false
        doubleTapContaminated = false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Audio Recorder (AVAudioEngine → PCM int16)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioData = Data()
    private(set) var isRecording = false
    private(set) var clippingDetected = false
    private let sampleRate: Double = 16000

    // Drain state — wait for engine to flush after stop()
    private var drainCompletion: ((Data?) -> Void)?
    private var drainTimer: Timer?

    // ── High-pass filter state (2nd-order Butterworth @ 80Hz) ──
    // Pre-computed coefficients for 80Hz cutoff at 16kHz sample rate
    // Using bilinear transform of s-domain Butterworth
    private var hpX1: Float = 0, hpX2: Float = 0
    private var hpY1: Float = 0, hpY2: Float = 0
    private let hpB0: Float =  0.9837613  // numerator coefficients
    private let hpB1: Float = -1.9675226
    private let hpB2: Float =  0.9837613
    private let hpA1: Float = -1.9674474  // denominator coefficients (a0=1)
    private let hpA2: Float =  0.9675978

    // ── Silence trimming (trailing only) ──
    // Very low threshold to preserve whispered/quiet speech (~-66dBFS)
    private let silenceThresholdRMS: Float = 0.0005

    func start() {
        // Pre-allocate for up to 60 seconds of 16kHz int16 audio
        audioData = Data(capacity: Int(sampleRate) * 2 * 60)
        isRecording = true
        clippingDetected = false

        // Reset filter state
        hpX1 = 0; hpX2 = 0; hpY1 = 0; hpY2 = 0

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Target format: 16kHz mono float32 (process in float, convert to int16 at end)
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Install tap with converter — smaller buffer (1024) for lower tail latency
        let converter = AVAudioConverter(from: hwFormat, to: desiredFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / hwFormat.sampleRate)
            guard capacity > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard let floatData = converted.floatChannelData else { return }
            let frameCount = Int(converted.frameLength)
            let ptr = floatData[0]

            // ── 1. High-pass filter (80Hz, removes rumble/HVAC) ──
            for i in 0..<frameCount {
                let x = ptr[i]
                let y = self.hpB0 * x + self.hpB1 * self.hpX1 + self.hpB2 * self.hpX2
                      - self.hpA1 * self.hpY1 - self.hpA2 * self.hpY2
                self.hpX2 = self.hpX1; self.hpX1 = x
                self.hpY2 = self.hpY1; self.hpY1 = y
                ptr[i] = y
            }

            // ── 2. Clipping detection ──
            var maxVal: Float = 0
            vDSP_maxmgv(ptr, 1, &maxVal, vDSP_Length(frameCount))
            if maxVal >= 0.99 {
                self.clippingDetected = true
            }

            // ── 3. Convert float32 → int16, accumulate ──
            var scale: Float = 32767.0
            var int16Buf = [Int16](repeating: 0, count: frameCount)
            var scaled = [Float](repeating: 0, count: frameCount)
            vDSP_vsmul(ptr, 1, &scale, &scaled, 1, vDSP_Length(frameCount))
            vDSP_vfix16(scaled, 1, &int16Buf, 1, vDSP_Length(frameCount))

            int16Buf.withUnsafeBufferPointer { bufPtr in
                self.audioData.append(bufPtr)
            }

            // If we're draining (stop was called), this buffer confirms
            // the engine has flushed — signal teardown on main thread
            if !self.isRecording {
                DispatchQueue.main.async { self.finishStop() }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            vflog("audio engine error: \(error)")
            isRecording = false
        }
    }

    func stop(completion: @escaping (Data?) -> Void) {
        isRecording = false
        drainCompletion = completion

        // Safety timeout — if no buffer arrives within 200ms, tear down anyway
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.finishStop()
        }
    }

    private func finishStop() {
        guard let completion = drainCompletion else { return }
        drainCompletion = nil
        drainTimer?.invalidate()
        drainTimer = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        if clippingDetected {
            vflog("warning: clipping detected in recording")
        }

        guard audioData.count > 3200 else { // < 100ms at 16kHz int16
            completion(nil)
            return
        }

        // Trim trailing silence
        let trimmed = trimTrailingSilence(audioData, sampleRate: Int(sampleRate))

        guard trimmed.count > 3200 else {
            completion(nil)
            return
        }

        completion(trimmed)
    }

    /// Remove trailing silent samples (below threshold) from int16 PCM data.
    private func trimTrailingSilence(_ data: Data, sampleRate: Int) -> Data {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return data }

        // Work in chunks of 50ms from the end (larger chunks prevent
        // brief quiet moments from being mistaken for trailing silence)
        let chunkSamples = sampleRate / 20  // 800 samples at 16kHz
        let threshold: Int16 = Int16(silenceThresholdRMS * 32767)

        return data.withUnsafeBytes { rawBuf -> Data in
            let samples = rawBuf.bindMemory(to: Int16.self)
            var lastSpeechSample = sampleCount

            // Walk backwards in chunks
            var chunkEnd = sampleCount
            while chunkEnd > 0 {
                let chunkStart = max(0, chunkEnd - chunkSamples)
                var maxAbs: Int16 = 0
                for i in chunkStart..<chunkEnd {
                    let abs = samples[i] < 0 ? -samples[i] : samples[i]
                    if abs > maxAbs { maxAbs = abs }
                }
                if maxAbs > threshold {
                    lastSpeechSample = chunkEnd
                    break
                }
                chunkEnd = chunkStart
            }

            if lastSpeechSample == 0 {
                return Data()  // All silence
            }
            return Data(rawBuf.prefix(lastSpeechSample * 2))
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Backend Bridge (Python subprocess)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class BackendBridge {
    var onReady: (() -> Void)?
    var onResult: ((String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var readyReceived = false

    func start() {
        let projectDir = Self.projectDir()
        let python = projectDir + "/.venv/bin/python"

        // Use bundled Python source (self-contained), fall back to project dir
        let resourcesDir = Bundle.main.resourcePath ?? projectDir
        let bundledModule = resourcesDir + "/voice_flow"
        let moduleDir = FileManager.default.fileExists(atPath: bundledModule) ? resourcesDir : projectDir

        vflog("backend python=\(python) modules=\(moduleDir)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-m", "voice_flow.backend"]
        proc.currentDirectoryURL = URL(fileURLWithPath: moduleDir)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Log stderr for debugging
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            for line in str.components(separatedBy: "\n") where !line.isEmpty {
                vflog("[backend-err] \(line)")
            }
        }

        self.stdin = inPipe.fileHandleForWriting

        // Read stdout line by line
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            for line in str.components(separatedBy: "\n") where !line.isEmpty {
                self?.handleLine(line)
            }
        }

        do {
            try proc.run()
            self.process = proc
            // load command is sent when we receive the "ready" event (see handleLine)
        } catch {
            vflog("failed to start backend: \(error)")
        }
    }

    func transcribe(
        pcmData: Data,
        sampleRate: Int,
        provider: DictationProvider,
        skipCleanup: Bool = false,
        openAIAPIKey: String? = nil
    ) {
        let b64 = pcmData.base64EncodedString()
        var msg: [String: Any] = [
            "cmd": "transcribe",
            "audio_b64": b64,
            "sample_rate": sampleRate,
            "provider": provider.rawValue,
        ]
        if skipCleanup {
            msg["skip_cleanup"] = true
        }
        if let openAIAPIKey, !openAIAPIKey.isEmpty {
            msg["openai_api_key"] = openAIAPIKey
        }
        send(msg)
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        let line = str + "\n"
        stdin?.write(line.data(using: .utf8)!)
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else { return }

        DispatchQueue.main.async { [self] in
            switch event {
            case "ready":
                readyReceived = true
                vflog("backend ready")
                onReady?()
            case "loaded":
                onStatus?("Models preloaded")
            case "result":
                let raw = dict["raw"] as? String ?? ""
                let cleaned = dict["cleaned"] as? String ?? ""
                onResult?(raw, cleaned)
            case "error":
                let msg = dict["message"] as? String ?? "unknown"
                onError?(msg)
            case "status":
                let msg = dict["message"] as? String ?? ""
                onStatus?(msg)
            default:
                break
            }
        }
    }

    static func projectDir() -> String {
        // Read from bundled config, or fall back to parent of bundle
        let bundle = Bundle.main
        if let path = bundle.path(forResource: "project_dir", ofType: "txt"),
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: infer from bundle location during development
        let bundlePath = bundle.bundlePath
        return (bundlePath as NSString).deletingLastPathComponent
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Paster (clipboard + simulated Cmd+V)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class Paster {
    private var pasteTargetApp: NSRunningApplication?

    func capturePasteTarget() {
        pasteTargetApp = NSWorkspace.shared.frontmostApplication
        if let app = pasteTargetApp {
            vflog("captured paste target: \(app.localizedName ?? app.bundleIdentifier ?? "unknown")")
        } else {
            vflog("captured paste target: none")
        }
    }

    func paste(_ text: String) {
        if let targetApp = pasteTargetApp, !targetApp.isTerminated {
            targetApp.activate(options: [])
            usleep(120_000)
        }

        let pb = NSPasteboard.general
        let snapshot = clonePasteboardItems(from: pb)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Let clipboard settle (matches Python's 50ms delay)
        usleep(50_000)

        pressCommandKey(9) // V
        usleep(120_000)
        restorePasteboard(snapshot, to: pb)
        pasteTargetApp = nil
    }

    func copySelectedText() -> String? {
        let pb = NSPasteboard.general
        let originalChangeCount = pb.changeCount
        let snapshot = clonePasteboardItems(from: pb)

        pressCommandKey(8) // C

        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            if pb.changeCount != originalChangeCount { break }
            usleep(10_000)
        }

        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        restorePasteboard(snapshot, to: pb)

        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private func pressCommandKey(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func clonePasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                } else if let string = item.string(forType: type) {
                    clone.setString(string, forType: type)
                }
            }
            return clone
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
