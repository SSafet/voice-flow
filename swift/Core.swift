import Cocoa
import AVFoundation
import CoreGraphics

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
    }

    func save() {
        let dict: [String: Any] = [
            "hotkey": hotkey,
            "sounds_enabled": soundsEnabled,
            "double_tap_ms": doubleTapMs,
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
//  Audio Recorder (AVAudioEngine → WAV)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioData = Data()
    private(set) var isRecording = false
    private let sampleRate: Double = 16000

    func start() {
        audioData = Data()
        isRecording = true

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // 16kHz mono int16
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on hardware format, convert ourselves
        let converter = AVAudioConverter(from: hwFormat, to: desiredFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / hwFormat.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let ptr = converted.int16ChannelData {
                let byteCount = Int(converted.frameLength) * 2
                self.audioData.append(UnsafeBufferPointer(start: ptr[0], count: Int(converted.frameLength)))
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

    func stop(completion: @escaping (String?) -> Void) {
        isRecording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        guard audioData.count > 3200 else { // < 100ms at 16kHz int16
            completion(nil)
            return
        }

        // Write WAV file
        let path = NSTemporaryDirectory() + "voice-flow-\(UUID().uuidString).wav"
        writeWAV(path: path, data: audioData, sampleRate: UInt32(sampleRate))
        completion(path)
    }

    private func writeWAV(path: String, data: Data, sampleRate: UInt32) {
        var header = Data()
        let dataSize = UInt32(data.count)
        let fileSize = dataSize + 36

        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })   // chunk size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })    // PCM
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })    // mono
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })   // sample rate
        header.append(withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Data($0) }) // byte rate
        header.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })    // block align
        header.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })   // bits per sample
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var fileData = header
        fileData.append(data)
        try? fileData.write(to: URL(fileURLWithPath: path))
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
            // Send load command after ready
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                self.send(["cmd": "load"])
            }
        } catch {
            vflog("failed to start backend: \(error)")
        }
    }

    func transcribe(audioPath: String) {
        send(["cmd": "transcribe", "audio_path": audioPath])
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
