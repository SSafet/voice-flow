import Foundation
import AVFoundation
import Darwin
import CryptoKit

let OpenAITTSModel = "gpt-4o-mini-tts"
let OpenAITTSVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse", "marin", "cedar"]
let DefaultTTSInstructions = "Speak with bright, alert energy. Conversational and crisp. Keep a steady forward pace, clear emphasis, and short pauses. Avoid sleepy or drawn-out delivery."

struct TTSStylePreset {
    let title: String
    let instructions: String
}

let OpenAITTSStylePresets: [TTSStylePreset] = [
    TTSStylePreset(
        title: "Bright Narrator",
        instructions: DefaultTTSInstructions
    ),
    TTSStylePreset(
        title: "Crisp Explainer",
        instructions: "Speak like a sharp explainer. Clean diction, brisk pace, light emphasis on key words, and no sleepy trailing off."
    ),
    TTSStylePreset(
        title: "Confident Presenter",
        instructions: "Sound like a confident presenter. Energetic, clear, and engaged. Use assertive phrasing, firm cadence, and short pauses."
    ),
    TTSStylePreset(
        title: "Punchy Demo",
        instructions: "Deliver this like a product demo. Upbeat, focused, and easy to follow. Keep sentences moving and land each point cleanly."
    ),
    TTSStylePreset(
        title: "Warm But Awake",
        instructions: "Keep a warm tone, but stay alert and lively. Natural rhythm, clear emphasis, and no slow or dreamy pacing."
    ),
]

struct TTSRequest: Equatable {
    var text: String
    var voice: String
    var speed: Double
    var instructions: String

    func normalized() -> TTSRequest {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVoice = OpenAITTSVoices.contains(voice) ? voice : UserSettings.shared.ttsVoice
        let normalizedSpeed = min(max(speed, 0.25), 4.0)
        let normalizedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return TTSRequest(
            text: trimmedText,
            voice: normalizedVoice,
            speed: normalizedSpeed,
            instructions: normalizedInstructions
        )
    }
}

struct TTSAPIUpdatePayload: Decodable {
    var text: String?
    var voice: String?
    var speed: Double?
    var instructions: String?
    var position: Double?
    var reveal: Bool?
}

enum TTSPlaybackPhase: String {
    case idle
    case generating
    case ready
    case playing
    case error
}

struct TTSStatusSnapshot {
    var phase: TTSPlaybackPhase
    var message: String
    var currentTime: Double
    var duration: Double
    var hasAudio: Bool
    var isCached: Bool
}

enum TTSError: LocalizedError {
    case emptyText
    case missingAPIKey
    case requestFailed(String)
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Text is empty."
        case .missingAPIKey:
            return "OpenAI API key is not configured."
        case .requestFailed(let message):
            return message
        case .invalidAudio:
            return "The TTS response could not be played."
        }
    }
}

private enum TTSAudioSource {
    case none
    case live
    case cache
}

private let TTSSampleRate: Double = 24_000
private let TTSChannels: AVAudioChannelCount = 1
private let TTSBytesPerFrame = 2
private let TTSLiveChunkFrames: AVAudioFrameCount = 4_800
private let TTSLiveStartupFrames: AVAudioFramePosition = 12_000
private let OpenAITTSInputCharacterLimit = 4_096
private let OpenAITTSChunkTargetCharacterLimit = 3_900

private final class TTSPCMStreamSession: NSObject, URLSessionDataDelegate {
    let requestID: UUID
    
    var onPCMData: ((UUID, Data) -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    var onFinished: ((UUID) -> Void)?

    private let request: URLRequest
    private let delegateQueue: OperationQueue

    private var urlSession: URLSession?
    private var task: URLSessionDataTask?
    private var errorResponseData = Data()
    private var failedStatusCode: Int?

    init(requestID: UUID, request: URLRequest) {
        self.requestID = requestID
        self.request = request
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        urlSession = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        urlSession?.invalidateAndCancel()
        task = nil
        urlSession = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail("TTS request failed: invalid response.")
            completionHandler(.cancel)
            return
        }

        if (200...299).contains(http.statusCode) {
            completionHandler(.allow)
            return
        }

        failedStatusCode = http.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if failedStatusCode != nil {
            errorResponseData.append(data)
            return
        }
        DispatchQueue.main.async {
            self.onPCMData?(self.requestID, data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            urlSession?.finishTasksAndInvalidate()
            urlSession = nil
            self.task = nil
        }

        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                return
            }
            fail("TTS request failed: \(error.localizedDescription)")
            return
        }

        if let statusCode = failedStatusCode {
            let message = errorMessage(from: errorResponseData)
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            fail("TTS request failed (\(statusCode)): \(message)")
            return
        }

        DispatchQueue.main.async {
            self.onFinished?(self.requestID)
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.onFailure?(self.requestID, message)
        }
    }

    private func errorMessage(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}

final class TTSController: NSObject {
    var onStatusChanged: ((TTSStatusSnapshot) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: TTSSampleRate, channels: TTSChannels)!
    private var activeRequestID = UUID()
    private var currentRequest: TTSRequest?
    private var currentStreamSession: TTSPCMStreamSession?
    private var currentCacheURL: URL?
    private var currentAudioSource: TTSAudioSource = .none
    private var currentPCMData = Data()
    private var pendingPCMData = Data()
    private var speechChunks: [String] = []
    private var activeSpeechChunkIndex = 0
    private var speechCacheURL: URL?
    private var speechAPIKey = ""
    // Live feed: text arrives incrementally (agent replies) — chunks are
    // appended while earlier ones fetch/play, and completion waits for
    // endLiveSpeech() instead of the last queued chunk.
    private var liveFeedActive = false
    private var awaitingLiveText = false
    private var playbackTimer: Timer?
    private var scheduledBufferCount = 0
    private var streamCompleted = false
    private var livePlaybackStarted = false
    private var isPlaybackPaused = false
    private var playbackBaseFrameOffset: AVAudioFramePosition = 0
    private var cachedTotalFrames: AVAudioFramePosition = 0
    private var engineConfigured = false
    private(set) var status = TTSStatusSnapshot(
        phase: .idle,
        message: "Idle",
        currentTime: 0,
        duration: 0,
        hasAudio: false,
        isCached: false
    )

    override init() {
        super.init()
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        stop()
        engine.stop()
    }

    func speak(request: TTSRequest) throws {
        let normalized = request.normalized()
        guard !normalized.text.isEmpty else {
            throw TTSError.emptyText
        }
        guard let apiKey = KeychainStore.shared.loadOpenAIAPIKey(), !apiKey.isEmpty else {
            throw TTSError.missingAPIKey
        }

        if normalized == currentRequest,
           currentStreamSession != nil || !currentPCMData.isEmpty || currentCacheURL != nil {
            if playerNode.isPlaying || currentStreamSession != nil, !isPlaybackPaused {
                pause()
                return
            }
            try resumeCurrentAudio()
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        discardCurrentAudio()
        currentRequest = normalized
        playbackBaseFrameOffset = 0

        let cacheURL = cacheURL(for: normalized)
        currentCacheURL = nil

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            currentCacheURL = cacheURL
            try playCachedAudio(from: cacheURL, startAtFrame: 0, autoPlay: true)
            return
        }

        speechChunks = splitSpeechInput(normalized.text)
        activeSpeechChunkIndex = 0
        speechCacheURL = cacheURL
        speechAPIKey = apiKey
        try startSpeechChunk(at: 0)
    }

    private func startSpeechChunk(at index: Int) throws {
        guard let currentRequest,
              index >= 0,
              index < speechChunks.count,
              !speechAPIKey.isEmpty else {
            throw TTSError.invalidAudio
        }

        let cacheURL = speechCacheURL  // nil for live-fed speech (not cacheable)
        activeSpeechChunkIndex = index
        let chunkRequest = TTSRequest(
            text: speechChunks[index],
            voice: currentRequest.voice,
            speed: currentRequest.speed,
            instructions: currentRequest.instructions
        )

        let urlRequest = try makeOpenAIURLRequest(for: chunkRequest, apiKey: speechAPIKey)
        let session = TTSPCMStreamSession(requestID: activeRequestID, request: urlRequest)
        session.onPCMData = { [weak self] requestID, data in
            self?.appendLivePCM(requestID: requestID, data: data)
        }
        session.onFailure = { [weak self] requestID, message in
            DispatchQueue.main.async {
                self?.fail(requestID: requestID, message: message)
            }
        }
        session.onFinished = { [weak self] requestID in
            DispatchQueue.main.async {
                self?.finishLiveStream(requestID: requestID, cacheURL: cacheURL)
            }
        }

        currentStreamSession = session
        currentAudioSource = .live
        try ensureAudioEngineStarted()
        refreshPlaybackStatus()
        session.start()
    }

    func pause() {
        guard currentRequest != nil else { return }

        let currentFrame = playbackFramePosition()
        isPlaybackPaused = true
        stopPlaybackTimer()
        playerNode.stop()
        playerNode.reset()
        scheduledBufferCount = 0
        playbackBaseFrameOffset = currentFrame

        if currentStreamSession != nil {
            let totalFrames = currentPCMFrameCount()
            let pausedFrame = max(0, min(currentFrame, totalFrames))
            let byteOffset = Int(pausedFrame) * TTSBytesPerFrame
            if byteOffset < currentPCMData.count {
                pendingPCMData = Data(currentPCMData[byteOffset...])
            } else {
                pendingPCMData.removeAll()
            }
            currentAudioSource = .live
            setStatus(.ready, "Paused")
            return
        }

        if currentCacheURL != nil {
            currentAudioSource = .cache
            setStatus(.ready, "Paused")
            return
        }

        setStatus(.idle, "Paused")
    }

    func stop() {
        if currentStreamSession != nil {
            activeRequestID = UUID()
            currentStreamSession?.cancel()
            currentStreamSession = nil
            clearSpeechPlan()
            stopPlaybackTimer()
            playerNode.stop()
            playerNode.reset()
            scheduledBufferCount = 0
            pendingPCMData.removeAll()
            streamCompleted = false
            isPlaybackPaused = false
            playbackBaseFrameOffset = 0

            if currentCacheURL != nil {
                currentAudioSource = .cache
                setStatus(.ready, "Ready")
            } else {
                currentRequest = nil
                currentCacheURL = nil
                currentAudioSource = .none
                currentPCMData.removeAll()
                cachedTotalFrames = 0
                setStatus(.idle, "Stopped")
            }
            return
        }

        guard playerNode.isPlaying || scheduledBufferCount > 0 || currentCacheURL != nil else {
            currentRequest = nil
            currentCacheURL = nil
            currentAudioSource = .none
            currentPCMData.removeAll()
            pendingPCMData.removeAll()
            clearSpeechPlan()
            streamCompleted = false
            cachedTotalFrames = 0
            isPlaybackPaused = false
            playbackBaseFrameOffset = 0
            setStatus(.idle, "Idle")
            return
        }

        stopPlaybackTimer()
        playerNode.stop()
        playerNode.reset()
        scheduledBufferCount = 0
        isPlaybackPaused = false
        playbackBaseFrameOffset = 0

        if currentCacheURL != nil {
            currentAudioSource = .cache
            setStatus(.ready, "Ready")
        } else {
            currentRequest = nil
            currentAudioSource = .none
            currentPCMData.removeAll()
            pendingPCMData.removeAll()
            clearSpeechPlan()
            streamCompleted = false
            cachedTotalFrames = 0
            setStatus(.idle, "Stopped")
        }
    }

    func seek(to seconds: Double) {
        guard let currentCacheURL else { return }
        let targetFrame = AVAudioFramePosition(max(0, min(seconds * TTSSampleRate, Double(cachedTotalFrames))))
        do {
            try playCachedAudio(from: currentCacheURL, startAtFrame: targetFrame, autoPlay: false)
            setStatus(.ready, "Ready")
        } catch {
            setStatus(.error, error.localizedDescription)
        }
    }

    private func appendLivePCM(requestID: UUID, data: Data) {
        guard requestID == activeRequestID else { return }
        currentPCMData.append(data)
        pendingPCMData.append(data)
        if isPlaybackPaused {
            setStatus(.ready, "Paused")
            return
        }
        schedulePendingLiveAudioIfPossible()

        let canStart = livePlaybackStarted || canStartLivePlayback()
        if !playerNode.isPlaying && scheduledBufferCount > 0 && canStart {
            livePlaybackStarted = true
            playerNode.play()
            startPlaybackTimer()
            setStatus(.playing, playbackMessage())
        } else if playerNode.isPlaying {
            setStatus(.playing, playbackMessage())
        } else {
            setStatus(.generating, generationMessage())
        }
    }

    private func finishLiveStream(requestID: UUID, cacheURL: URL?) {
        guard requestID == activeRequestID else { return }
        currentStreamSession = nil
        if !isPlaybackPaused {
            schedulePendingLiveAudioIfPossible(flushAll: true)
        }

        let nextIndex = activeSpeechChunkIndex + 1
        if nextIndex < speechChunks.count {
            do {
                try startSpeechChunk(at: nextIndex)
            } catch {
                fail(requestID: requestID, message: error.localizedDescription)
            }
            return
        }

        // Live feed still open — keep the plan alive and wait for more text.
        if liveFeedActive {
            awaitingLiveText = true
            refreshPlaybackStatus()
            return
        }

        guard !currentPCMData.isEmpty else {
            setStatus(.error, TTSError.invalidAudio.localizedDescription)
            return
        }

        streamCompleted = true
        speechAPIKey = ""
        speechCacheURL = nil
        if let cacheURL {
            do {
                let wavData = makeWAVData(from: currentPCMData)
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try wavData.write(to: cacheURL, options: .atomic)
                currentCacheURL = cacheURL
                cachedTotalFrames = AVAudioFramePosition(currentPCMData.count / TTSBytesPerFrame)
                refreshPlaybackStatus()
            } catch {
                vflog("tts cache write failed: \(error)")
            }
        }

        if scheduledBufferCount == 0 {
            stopPlaybackTimer()
            setStatus(.ready, isPlaybackPaused ? "Paused" : "Ready")
        }
    }

    // ── Live-fed speech (speak an agent reply while it streams) ──

    /// Prepare the engine to speak text that will arrive incrementally via
    /// `feedLiveSpeech`. Playback starts as soon as the first chunk's audio
    /// arrives; call `endLiveSpeech()` once the text source is done.
    func beginLiveSpeech(voice: String, speed: Double, instructions: String) throws {
        guard let apiKey = KeychainStore.shared.loadOpenAIAPIKey(), !apiKey.isEmpty else {
            throw TTSError.missingAPIKey
        }
        activeRequestID = UUID()
        discardCurrentAudio()
        currentRequest = TTSRequest(text: " ", voice: voice, speed: speed, instructions: instructions).normalized()
        playbackBaseFrameOffset = 0
        speechChunks = []
        activeSpeechChunkIndex = 0
        speechCacheURL = nil
        speechAPIKey = apiKey
        liveFeedActive = true
        awaitingLiveText = true
        currentAudioSource = .live
        setStatus(.generating, "Waiting for reply…")
    }

    func feedLiveSpeech(_ text: String) {
        guard liveFeedActive else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speechChunks.append(trimmed)
        if awaitingLiveText, currentStreamSession == nil {
            awaitingLiveText = false
            do {
                try startSpeechChunk(at: speechChunks.count - 1)
            } catch {
                fail(requestID: activeRequestID, message: error.localizedDescription)
            }
        }
    }

    func endLiveSpeech() {
        guard liveFeedActive else { return }
        liveFeedActive = false
        // If a chunk is still fetching, finishLiveStream finalizes when it ends.
        guard awaitingLiveText, currentStreamSession == nil else { return }
        awaitingLiveText = false
        speechAPIKey = ""
        guard !currentPCMData.isEmpty else {
            currentRequest = nil
            currentAudioSource = .none
            setStatus(.idle, "Idle")
            return
        }
        streamCompleted = true
        if scheduledBufferCount == 0 {
            stopPlaybackTimer()
            setStatus(.ready, isPlaybackPaused ? "Paused" : "Ready")
        } else {
            refreshPlaybackStatus()
        }
    }

    private func makeOpenAIURLRequest(for request: TTSRequest, apiKey: String) throws -> URLRequest {
        var body: [String: Any] = [
            "model": OpenAITTSModel,
            "input": request.text,
            "voice": request.voice,
            "response_format": "pcm",
            "speed": request.speed,
        ]
        if !request.instructions.isEmpty {
            body["instructions"] = request.instructions
        }

        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func ensureAudioEngineStarted() throws {
        guard !engineConfigured else {
            if !engine.isRunning {
                try engine.start()
            }
            return
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
        try engine.start()
        engineConfigured = true
    }

    private func schedulePendingLiveAudioIfPossible(flushAll: Bool = false) {
        let chunkBytes = Int(TTSLiveChunkFrames) * TTSBytesPerFrame
        while pendingPCMData.count >= chunkBytes || (flushAll && !pendingPCMData.isEmpty) {
            let take = flushAll ? pendingPCMData.count : chunkBytes
            let chunk = Data(pendingPCMData.prefix(take))
            pendingPCMData.removeFirst(take)
            schedulePCMChunk(chunk)
        }
    }

    private func schedulePCMChunk(_ data: Data) {
        let frames = data.count / TTSBytesPerFrame
        guard frames > 0 else { return }

        let frameCount = AVAudioFrameCount(frames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard samples.count >= frames else { return }
            for i in 0..<frames {
                channel[i] = Float(samples[i]) / 32768.0
            }
        }

        scheduledBufferCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleScheduledBufferPlayed()
            }
        }
    }

    private func handleScheduledBufferPlayed() {
        scheduledBufferCount = max(0, scheduledBufferCount - 1)
        if scheduledBufferCount == 0, streamCompleted || currentAudioSource == .cache {
            stopPlaybackTimer()
            setStatus(.ready, "Ready")
        } else {
            refreshPlaybackStatus()
        }
    }

    private func refreshPlaybackStatus() {
        let duration = currentDuration()
        let currentTime = currentPlaybackTime()
        let hasAudio = !currentPCMData.isEmpty || currentCacheURL != nil

        let phase: TTSPlaybackPhase
        let message: String
        if isPlaybackPaused {
            phase = hasAudio ? .ready : .idle
            message = hasAudio ? "Paused" : "Idle"
        } else if playerNode.isPlaying {
            phase = .playing
            message = playbackMessage()
        } else if currentStreamSession != nil {
            phase = .generating
            message = generationMessage()
        } else {
            phase = hasAudio ? .ready : .idle
            message = hasAudio ? "Ready" : "Idle"
        }

        status = TTSStatusSnapshot(
            phase: phase,
            message: message,
            currentTime: currentTime,
            duration: duration,
            hasAudio: hasAudio,
            isCached: currentCacheURL != nil
        )
        onStatusChanged?(status)
    }

    private func fail(requestID: UUID, message: String) {
        guard requestID == activeRequestID else { return }
        currentStreamSession?.cancel()
        currentStreamSession = nil
        clearSpeechPlan()
        stopPlaybackTimer()
        playerNode.stop()
        playerNode.reset()
        scheduledBufferCount = 0
        streamCompleted = false
        isPlaybackPaused = false
        setStatus(.error, message)
    }

    private func setStatus(_ phase: TTSPlaybackPhase, _ message: String) {
        status = TTSStatusSnapshot(
            phase: phase,
            message: message,
            currentTime: currentPlaybackTime(),
            duration: currentDuration(),
            hasAudio: !currentPCMData.isEmpty || currentCacheURL != nil,
            isCached: currentCacheURL != nil
        )
        onStatusChanged?(status)
    }

    private func resumeCurrentAudio() throws {
        isPlaybackPaused = false
        if currentCacheURL != nil && (scheduledBufferCount == 0 || currentAudioSource == .cache) {
            try playCachedAudio(from: currentCacheURL!, startAtFrame: playbackFramePosition() >= cachedTotalFrames - 1 ? 0 : playbackFramePosition(), autoPlay: true)
            return
        }

        if scheduledBufferCount == 0 && !pendingPCMData.isEmpty {
            schedulePendingLiveAudioIfPossible(flushAll: streamCompleted)
        }

        guard scheduledBufferCount > 0 || currentStreamSession != nil else {
            throw TTSError.invalidAudio
        }

        if scheduledBufferCount > 0 && (livePlaybackStarted || canStartLivePlayback()) {
            livePlaybackStarted = true
            playerNode.play()
            startPlaybackTimer()
        }
        refreshPlaybackStatus()
    }

    private func playbackMessage() -> String {
        switch currentAudioSource {
        case .live:
            if speechChunks.count > 1 {
                return "Speaking \(activeSpeechChunkIndex + 1)/\(speechChunks.count)"
            }
            return "Speaking live stream"
        case .cache:
            return "Speaking cached audio"
        case .none:
            return "Speaking"
        }
    }

    private func generationMessage() -> String {
        if speechChunks.count > 1 {
            return "Streaming speech \(activeSpeechChunkIndex + 1)/\(speechChunks.count)…"
        }
        return "Streaming speech…"
    }

    private func splitSpeechInput(_ text: String) -> [String] {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remaining.count > OpenAITTSInputCharacterLimit else {
            return remaining.isEmpty ? [] : [remaining]
        }

        var chunks: [String] = []
        while remaining.count > OpenAITTSInputCharacterLimit {
            let targetOffset = min(OpenAITTSChunkTargetCharacterLimit, remaining.count)
            let targetIndex = remaining.index(remaining.startIndex, offsetBy: targetOffset)
            let splitIndex = bestSpeechSplitIndex(in: remaining, before: targetIndex)
            let chunk = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !remaining.isEmpty {
            chunks.append(remaining)
        }
        return chunks
    }

    private func bestSpeechSplitIndex(in text: String, before targetIndex: String.Index) -> String.Index {
        let minimumOffset = min(OpenAITTSChunkTargetCharacterLimit / 2, max(text.count - 1, 0))
        let minimumIndex = text.index(text.startIndex, offsetBy: minimumOffset)
        let preferredRange = minimumIndex..<targetIndex
        let separators = ["\n\n", "\n", ". ", "! ", "? ", "; ", ": ", ", "]

        for separator in separators {
            if let range = text.range(of: separator, options: .backwards, range: preferredRange) {
                return range.upperBound
            }
        }

        if let range = text.range(of: " ", options: .backwards, range: text.startIndex..<targetIndex) {
            return range.upperBound
        }
        return targetIndex
    }

    private func canStartLivePlayback() -> Bool {
        if streamCompleted || currentStreamSession == nil {
            return true
        }

        let receivedFrames = AVAudioFramePosition(currentPCMData.count / TTSBytesPerFrame)
        let playedFrames = min(playbackFramePosition(), receivedFrames)
        let bufferedFrames = max(0, receivedFrames - playedFrames)
        return bufferedFrames >= TTSLiveStartupFrames
    }

    private func playCachedAudio(from url: URL, startAtFrame: AVAudioFramePosition, autoPlay: Bool) throws {
        try ensureAudioEngineStarted()

        let file = try AVAudioFile(forReading: url)
        cachedTotalFrames = file.length
        let clampedStartFrame = min(max(startAtFrame, 0), max(file.length - 1, 0))
        let remainingFrames = max(file.length - clampedStartFrame, 0)
        let frameCount = AVAudioFrameCount(remainingFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw TTSError.invalidAudio
        }

        file.framePosition = clampedStartFrame
        try file.read(into: buffer, frameCount: frameCount)

        playerNode.stop()
        playerNode.reset()
        stopPlaybackTimer()
        scheduledBufferCount = 0
        playbackBaseFrameOffset = clampedStartFrame
        currentAudioSource = .cache
        currentCacheURL = url
        isPlaybackPaused = false

        if currentPCMData.isEmpty {
            currentPCMData = Data(count: Int(file.length) * TTSBytesPerFrame)
        }

        if buffer.frameLength == 0 {
            setStatus(.ready, "Ready")
            return
        }

        scheduledBufferCount = 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleScheduledBufferPlayed()
            }
        }

        if autoPlay {
            playerNode.play()
            startPlaybackTimer()
            setStatus(.playing, playbackMessage())
        } else {
            setStatus(.ready, "Ready")
        }
    }

    private func discardCurrentAudio() {
        currentStreamSession?.cancel()
        currentStreamSession = nil
        clearSpeechPlan()
        stopPlaybackTimer()
        playerNode.stop()
        playerNode.reset()
        scheduledBufferCount = 0
        currentCacheURL = nil
        currentAudioSource = .none
        currentPCMData.removeAll()
        pendingPCMData.removeAll()
        streamCompleted = false
        livePlaybackStarted = false
        isPlaybackPaused = false
        playbackBaseFrameOffset = 0
        cachedTotalFrames = 0
    }

    private func clearSpeechPlan() {
        speechChunks.removeAll()
        activeSpeechChunkIndex = 0
        speechCacheURL = nil
        speechAPIKey = ""
        liveFeedActive = false
        awaitingLiveText = false
    }

    private func currentPCMFrameCount() -> AVAudioFramePosition {
        AVAudioFramePosition(currentPCMData.count / TTSBytesPerFrame)
    }

    private func playbackFramePosition() -> AVAudioFramePosition {
        guard engineConfigured, playerNode.engine != nil else {
            return playbackBaseFrameOffset
        }
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            return playbackBaseFrameOffset
        }
        return playbackBaseFrameOffset + AVAudioFramePosition(playerTime.sampleTime)
    }

    private func currentPlaybackTime() -> Double {
        Double(playbackFramePosition()) / TTSSampleRate
    }

    private func currentDuration() -> Double {
        let frameCount = currentCacheURL != nil ? cachedTotalFrames : AVAudioFramePosition(currentPCMData.count / TTSBytesPerFrame)
        return Double(frameCount) / TTSSampleRate
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshPlaybackStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func makeWAVData(from pcm: Data) -> Data {
        let dataSize = UInt32(pcm.count)
        let byteRate = UInt32(TTSSampleRate) * UInt32(TTSChannels) * UInt32(TTSBytesPerFrame)
        let blockAlign = UInt16(TTSChannels) * UInt16(TTSBytesPerFrame)
        let chunkSize = 36 + dataSize

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(littleEndianBytes(chunkSize))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(littleEndianBytes(UInt32(16)))
        wav.append(littleEndianBytes(UInt16(1)))
        wav.append(littleEndianBytes(UInt16(TTSChannels)))
        wav.append(littleEndianBytes(UInt32(TTSSampleRate)))
        wav.append(littleEndianBytes(byteRate))
        wav.append(littleEndianBytes(blockAlign))
        wav.append(littleEndianBytes(UInt16(16)))
        wav.append(contentsOf: Array("data".utf8))
        wav.append(littleEndianBytes(dataSize))
        wav.append(pcm)
        return wav
    }

    private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    private func cacheURL(for request: TTSRequest) -> URL {
        let payload = [
            OpenAITTSModel,
            request.voice,
            String(format: "%.3f", request.speed),
            request.instructions,
            request.text,
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined() + ".wav"
        return cacheDirectory().appendingPathComponent(filename)
    }

    private func cacheDirectory() -> URL {
        let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        let dir = baseDir
            .appendingPathComponent("com.voiceflow.app", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Agent Reply Speaker — speaks a streaming reply as it arrives
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Buffers assistant deltas and cuts them at sentence boundaries so the
//  TTS engine can start talking long before the full reply exists.

final class AgentReplySpeaker {
    private let tts: TTSController
    private var buffer = ""
    private(set) var isActive = false

    // A chunk must be at least this long before we cut at a sentence end —
    // sub-clause fragments make the voice sound choppy.
    private let minChunkLength = 25
    // Without any sentence boundary, cut at the last space past this point.
    private let maxChunkLength = 360

    init(tts: TTSController) {
        self.tts = tts
    }

    func begin() {
        guard !isActive else { return }
        buffer = ""
        let settings = UserSettings.shared
        do {
            try tts.beginLiveSpeech(
                voice: settings.ttsVoice,
                speed: settings.ttsSpeed,
                instructions: settings.ttsInstructions
            )
            isActive = true
        } catch {
            vflog("live reply speech unavailable: \(error.localizedDescription)")
        }
    }

    func append(_ delta: String) {
        guard isActive else { return }
        buffer += delta
        while let chunk = nextChunk() {
            tts.feedLiveSpeech(chunk)
        }
    }

    func finish() {
        guard isActive else { return }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            tts.feedLiveSpeech(rest)
        }
        buffer = ""
        isActive = false
        tts.endLiveSpeech()
    }

    func cancel() {
        guard isActive else { return }
        buffer = ""
        isActive = false
        tts.stop()
    }

    /// Pop the next speakable chunk off the buffer, or nil to wait for more text.
    private func nextChunk() -> String? {
        var count = 0
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let ch = buffer[index]
            let next = buffer.index(after: index)
            count += 1
            if ch == "\n", count >= minChunkLength {
                return popChunk(upTo: next)
            }
            if ".!?".contains(ch), count >= minChunkLength,
               next < buffer.endIndex, buffer[next] == " " || buffer[next] == "\n" {
                return popChunk(upTo: next)
            }
            index = next
        }

        if buffer.count >= maxChunkLength {
            if let lastSpace = buffer.lastIndex(of: " "), lastSpace > buffer.startIndex {
                return popChunk(upTo: lastSpace)
            }
            return popChunk(upTo: buffer.endIndex)
        }
        return nil
    }

    private func popChunk(upTo index: String.Index) -> String? {
        let chunk = String(buffer[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeSubrange(..<index)
        return chunk.isEmpty ? nil : chunk
    }
}

struct LocalAPIResponse {
    let statusCode: Int
    let body: [String: Any]

    static func ok(_ body: [String: Any]) -> LocalAPIResponse {
        LocalAPIResponse(statusCode: 200, body: body)
    }

    static func accepted(_ body: [String: Any]) -> LocalAPIResponse {
        LocalAPIResponse(statusCode: 202, body: body)
    }

    static func error(_ statusCode: Int, _ message: String) -> LocalAPIResponse {
        LocalAPIResponse(statusCode: statusCode, body: ["ok": false, "error": message])
    }
}

private struct LocalHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

final class LocalAPIServer {
    static let host = "127.0.0.1"
    static let port: UInt16 = 8792

    var onStatus: (() -> LocalAPIResponse)?
    var onSet: ((TTSAPIUpdatePayload) -> LocalAPIResponse)?
    var onSpeak: ((TTSAPIUpdatePayload) -> LocalAPIResponse)?
    var onSeek: ((TTSAPIUpdatePayload) -> LocalAPIResponse)?
    var onStop: (() -> LocalAPIResponse)?
    var onServerMessage: ((String) -> Void)?
    /// MCP endpoint: (raw JSON-RPC body, Mcp-Session-Id) in → (status,
    /// body, sessionIdToIssue) out. May block for minutes (ask_user),
    /// hence the concurrent client queue below.
    var onMCP: ((Data, String?) -> (status: Int, payload: Data?, sessionId: String?))?
    /// DELETE /mcp with a session id — Claude Code ending its session.
    var onMCPSessionEnd: ((String) -> Void)?

    private let queue = DispatchQueue(label: "voiceflow.local-api", qos: .userInitiated)
    // Each connection is served on its own thread so one long-running MCP
    // tool call can't block TTS control or other MCP requests.
    private let clientQueue = DispatchQueue(
        label: "voiceflow.local-api.clients", qos: .userInitiated, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    var baseURL: String {
        "http://\(Self.host):\(Self.port)"
    }

    func start() {
        guard listenFD == -1 else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            onServerMessage?("Local API failed to create socket.")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Self.port).bigEndian
        let hostCString = strdup(Self.host)
        inet_pton(AF_INET, hostCString, &addr.sin_addr)
        free(hostCString)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            onServerMessage?("Local API bind failed: \(message)")
            return
        }

        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            onServerMessage?("Local API listen failed: \(message)")
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptNextClient()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            Darwin.close(self.listenFD)
            self.listenFD = -1
        }
        acceptSource = source
        source.resume()
        onServerMessage?("Local API ready at \(baseURL)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    private func acceptNextClient() {
        var addr = sockaddr()
        var addrLen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = Darwin.accept(listenFD, &addr, &addrLen)
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        clientQueue.async { [weak self] in
            self?.handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        guard let request = readRequest(from: fd) else {
            writeResponse(LocalAPIResponse.error(400, "Invalid request."), to: fd)
            return
        }

        if request.path == "/mcp" {
            handleMCPRequest(request, fd: fd)
            return
        }

        let response = route(request)
        writeResponse(response, to: fd)
    }

    private func handleMCPRequest(_ request: LocalHTTPRequest, fd: Int32) {
        let sessionId = request.headers["mcp-session-id"]
        if request.method == "DELETE" {
            // Explicit session teardown from the client.
            if let sessionId {
                onMCPSessionEnd?(sessionId)
            }
            writeRawResponse(status: 200, payload: Data("{}".utf8), to: fd)
            return
        }
        guard request.method == "POST" else {
            // Streamable HTTP allows a server without an SSE listening
            // stream to reject GET.
            writeRawResponse(status: 405, payload: Data("{}".utf8), to: fd)
            return
        }
        guard let onMCP else {
            writeRawResponse(status: 503, payload: Data("{}".utf8), to: fd)
            return
        }
        let (status, payload, issued) = onMCP(request.body, sessionId)
        var extraHeaders: [String: String] = [:]
        if let issued {
            extraHeaders["Mcp-Session-Id"] = issued
        }
        writeRawResponse(status: status, payload: payload, extraHeaders: extraHeaders, to: fd)
    }

    private func route(_ request: LocalHTTPRequest) -> LocalAPIResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/tts/status"):
            return onStatus?() ?? LocalAPIResponse.error(503, "TTS status unavailable.")
        case ("POST", "/api/tts/set"):
            switch decodePayload(request.body) {
            case .success(let payload):
                return onSet?(payload) ?? LocalAPIResponse.error(503, "TTS controls unavailable.")
            case .failure(let error):
                return LocalAPIResponse.error(400, error.localizedDescription)
            }
        case ("POST", "/api/tts/speak"):
            switch decodePayload(request.body) {
            case .success(let payload):
                return onSpeak?(payload) ?? LocalAPIResponse.error(503, "TTS speak unavailable.")
            case .failure(let error):
                return LocalAPIResponse.error(400, error.localizedDescription)
            }
        case ("POST", "/api/tts/seek"):
            switch decodePayload(request.body) {
            case .success(let payload):
                return onSeek?(payload) ?? LocalAPIResponse.error(503, "TTS seek unavailable.")
            case .failure(let error):
                return LocalAPIResponse.error(400, error.localizedDescription)
            }
        case ("POST", "/api/tts/stop"):
            return onStop?() ?? LocalAPIResponse.error(503, "TTS stop unavailable.")
        default:
            return LocalAPIResponse.error(404, "Not found.")
        }
    }

    private func decodePayload(_ data: Data) -> Result<TTSAPIUpdatePayload, Error> {
        if data.isEmpty {
            return .success(TTSAPIUpdatePayload())
        }
        return Result {
            try JSONDecoder().decode(TTSAPIUpdatePayload.self, from: data)
        }
    }

    private func readRequest(from fd: Int32) -> LocalHTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headersEnd: Data.Index?
        var contentLength = 0

        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(chunk, count: count)

            if headersEnd == nil, let range = buffer.range(of: separator) {
                headersEnd = range.upperBound
                let headerData = Data(buffer[..<range.lowerBound])
                guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
                let parsedHeaders = parseHeaders(headerString)
                contentLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
            }

            if let headersEnd, buffer.count >= headersEnd + contentLength {
                break
            }
        }

        guard let request = parseRequest(buffer, contentLength: contentLength) else {
            return nil
        }
        return request
    }

    private func parseRequest(_ buffer: Data, contentLength: Int) -> LocalHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let headerData = Data(buffer[..<range.lowerBound])
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let headers = parseHeaders(headerString)
        let rawPath = String(parts[1])
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let bodyStart = range.upperBound
        let bodyEnd = min(buffer.count, bodyStart + contentLength)
        let body = bodyStart < bodyEnd ? Data(buffer[bodyStart..<bodyEnd]) : Data()

        return LocalHTTPRequest(
            method: String(parts[0]),
            path: path,
            headers: headers,
            body: body
        )
    }

    private func parseHeaders(_ headerString: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in headerString.components(separatedBy: "\r\n").dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private func writeResponse(_ response: LocalAPIResponse, to fd: Int32) {
        let payloadData = (try? JSONSerialization.data(withJSONObject: response.body, options: [.prettyPrinted])) ?? Data("{}".utf8)
        writeRawResponse(status: response.statusCode, payload: payloadData, to: fd)
    }

    private func writeRawResponse(status: Int, payload: Data?, extraHeaders: [String: String] = [:], to fd: Int32) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Error"
        }
        let payloadData = payload ?? Data()

        var lines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(payloadData.count)",
            "Connection: close",
        ]
        for (key, value) in extraHeaders {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        let header = lines.joined(separator: "\r\n")

        writeAll(fd: fd, data: Data(header.utf8))
        if !payloadData.isEmpty {
            writeAll(fd: fd, data: payloadData)
        }
    }

    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.write(fd, base.advanced(by: totalSent), data.count - totalSent)
                if sent <= 0 { return }
                totalSent += sent
            }
        }
    }
}
