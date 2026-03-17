import Cocoa
import AVFoundation
import CoreGraphics
import Accelerate

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
//  Settings (JSON at ~/.config/voice-flow/settings.json)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class UserSettings {
    static let shared = UserSettings()
    var hotkey: String = "alt_r"
    var soundsEnabled: Bool = true
    var doubleTapMs: Int = 400
    var llmCleanupEnabled: Bool = true

    // Foundry gateway
    var captureIntervalSeconds: Int = 30
    var captureHotkey: String = "f6"
    var gatewayHost: String = "127.0.0.1"
    var gatewayWSPort: Int = 8789
    var gatewayHTTPPort: Int = 8791
    var tenantId: String = "local"
    var userId: String = "safet"
    var agentType: String = "eyes"
    var sessionLabel: String = "eyes-session"

    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    func load() {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let v = dict["hotkey"] as? String { hotkey = v }
        if let v = dict["sounds_enabled"] as? Bool { soundsEnabled = v }
        if let v = dict["double_tap_ms"] as? Int { doubleTapMs = v }
        if let v = dict["llm_cleanup_enabled"] as? Bool { llmCleanupEnabled = v }
        if let v = dict["capture_interval"] as? Int { captureIntervalSeconds = v }
        if let v = dict["capture_hotkey"] as? String { captureHotkey = v }
        if let v = dict["gateway_host"] as? String { gatewayHost = v }
        if let v = dict["gateway_ws_port"] as? Int { gatewayWSPort = v }
        if let v = dict["gateway_http_port"] as? Int { gatewayHTTPPort = v }
        if let v = dict["tenant_id"] as? String { tenantId = v }
        if let v = dict["user_id"] as? String { userId = v }
        if let v = dict["agent_type"] as? String { agentType = v }
        if let v = dict["session_label"] as? String { sessionLabel = v }
    }

    func save() {
        let dict: [String: Any] = [
            "hotkey": hotkey,
            "sounds_enabled": soundsEnabled,
            "double_tap_ms": doubleTapMs,
            "llm_cleanup_enabled": llmCleanupEnabled,
            "capture_interval": captureIntervalSeconds,
            "capture_hotkey": captureHotkey,
            "gateway_host": gatewayHost,
            "gateway_ws_port": gatewayWSPort,
            "gateway_http_port": gatewayHTTPPort,
            "tenant_id": tenantId,
            "user_id": userId,
            "agent_type": agentType,
            "session_label": sessionLabel,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Hotkey Manager (CGEventTap)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onHandsFree: ((Bool) -> Void)?

    private var keyCode: CGKeyCode
    private var pressed = false
    private var handsFree = false
    private var pressTime: TimeInterval = 0
    private var pendingRelease = false
    private var pendingTimer: Timer?
    private var runLoopSource: CFRunLoopSource?

    static let keyMap: [String: CGKeyCode] = [
        "alt_r": 61, "alt_l": 58, "ctrl_r": 62, "ctrl_l": 59,
        "fn": 63, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    ]
    static let keyLabels: [String: String] = [
        "alt_r": "Right Option", "alt_l": "Left Option",
        "ctrl_r": "Right Control", "ctrl_l": "Left Control",
        "fn": "Fn (Globe)", "f5": "F5", "f6": "F6", "f7": "F7", "f8": "F8",
    ]

    init(keyName: String) {
        self.keyCode = Self.keyMap[keyName] ?? 61
    }

    func updateKey(_ keyName: String) {
        keyCode = Self.keyMap[keyName] ?? 61
        pressed = false
        handsFree = false
        pendingRelease = false
        pendingTimer?.invalidate()
        pendingTimer = nil
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
        vflog("hotkey listener started (keyCode=\(keyCode))")
    }

    private func handleEvent(_ event: CGEvent) {
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let type = event.type

        // For modifier keys, use flagsChanged
        if type == .flagsChanged {
            guard kc == keyCode else { return }
            // Check if the modifier is currently pressed by looking at flags
            let flags = event.flags
            let isDown: Bool
            switch keyCode {
            case 61: isDown = flags.contains(.maskAlternate) && kc == 61  // right alt
            case 58: isDown = flags.contains(.maskAlternate) && kc == 58  // left alt
            case 62: isDown = flags.contains(.maskControl) && kc == 62
            case 59: isDown = flags.contains(.maskControl) && kc == 59
            case 63: isDown = flags.contains(.maskSecondaryFn)
            default: isDown = false
            }
            if isDown { handlePress() } else { handleRelease() }
        } else if type == .keyDown || type == .keyUp {
            guard kc == keyCode else { return }
            if type == .keyDown { handlePress() } else { handleRelease() }
        }
    }

    private func handlePress() {
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
        guard pressed else { return }
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

    // ── Pre-emphasis coefficient (~+6dB above 2kHz) ──
    private var preEmphPrev: Float = 0
    private let preEmphCoeff: Float = 0.97

    // ── Silence trimming ──
    // Low threshold to preserve whispered speech (~-60dBFS)
    private let silenceThresholdRMS: Float = 0.001

    func start() {
        // Pre-allocate for up to 60 seconds of 16kHz int16 audio
        audioData = Data(capacity: Int(sampleRate) * 2 * 60)
        isRecording = true
        clippingDetected = false

        // Reset filter state
        hpX1 = 0; hpX2 = 0; hpY1 = 0; hpY2 = 0
        preEmphPrev = 0

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

            // ── 2. Pre-emphasis filter (+6dB/oct above ~2kHz for consonant clarity) ──
            for i in 0..<frameCount {
                let x = ptr[i]
                ptr[i] = x - self.preEmphCoeff * self.preEmphPrev
                self.preEmphPrev = x
            }

            // ── 3. RMS check — skip near-silent buffers (trim leading/trailing silence) ──
            var sumSq: Float = 0
            vDSP_measqv(ptr, 1, &sumSq, vDSP_Length(frameCount))
            let rms = sqrtf(sumSq)
            let isSilent = rms < self.silenceThresholdRMS

            // Only skip if we haven't accumulated any speech yet (leading silence)
            if isSilent && self.audioData.isEmpty {
                return
            }

            // ── 4. Clipping detection ──
            var maxVal: Float = 0
            vDSP_maxmgv(ptr, 1, &maxVal, vDSP_Length(frameCount))
            if maxVal >= 0.99 {
                self.clippingDetected = true
            }

            // ── 5. Clamp to [-1,1] (pre-emphasis can exceed), convert float32 → int16, accumulate ──
            var clampLo: Float = -1.0, clampHi: Float = 1.0
            vDSP_vclip(ptr, 1, &clampLo, &clampHi, ptr, 1, vDSP_Length(frameCount))

            var scale: Float = 32767.0
            var int16Buf = [Int16](repeating: 0, count: frameCount)
            var scaled = [Float](repeating: 0, count: frameCount)
            vDSP_vsmul(ptr, 1, &scale, &scaled, 1, vDSP_Length(frameCount))
            vDSP_vfix16(scaled, 1, &int16Buf, 1, vDSP_Length(frameCount))

            int16Buf.withUnsafeBufferPointer { bufPtr in
                self.audioData.append(bufPtr)
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

        // Work in chunks of 10ms from the end
        let chunkSamples = sampleRate / 100  // 160 samples at 16kHz
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
    var onLoaded: (() -> Void)?
    var onResult: ((String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var readyReceived = false

    func start() {
        let projectDir = Self.projectDir()
        vflog("backend projectDir=\(projectDir)")
        let python = projectDir + "/.venv/bin/python"
        vflog("backend python=\(python) exists=\(FileManager.default.fileExists(atPath: python))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-m", "voice_flow.backend"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectDir)

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

    func transcribe(pcmData: Data, sampleRate: Int, skipCleanup: Bool = false) {
        let b64 = pcmData.base64EncodedString()
        var msg: [String: Any] = [
            "cmd": "transcribe",
            "audio_b64": b64,
            "sample_rate": sampleRate,
        ]
        if skipCleanup {
            msg["skip_cleanup"] = true
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
                vflog("backend ready — sending load")
                send(["cmd": "load"])
            case "loaded":
                onLoaded?()
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
    func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Let clipboard settle (matches Python's 50ms delay)
        usleep(50_000)

        // Simulate Cmd+V
        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // 9 = 'v'
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
