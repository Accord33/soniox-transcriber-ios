@preconcurrency import AVFoundation
import Foundation

enum SonioxServiceError: LocalizedError, Equatable {
    case invalidKey
    case server(String)
    case connection
    case microphoneDenied
    case audioSetup

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Soniox APIキーが無効です。"
        case .server(let message): message
        case .connection: "Sonioxに接続できませんでした。通信環境を確認してください。"
        case .microphoneDenied: "マイクへのアクセスが許可されていません。"
        case .audioSetup: "マイクを開始できませんでした。"
        }
    }
}

actor SonioxWebSocket {
    static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    func connect(apiKey: String) async throws {
        closeCurrentConnection()
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let task = session.webSocketTask(with: Self.endpoint)
        self.task = task
        task.resume()
        let config: [String: Any] = [
            "api_key": apiKey,
            "model": "stt-rt-v5",
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "language_hints": ["ja"],
            "enable_speaker_diarization": true
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        guard let text = String(data: data, encoding: .utf8) else { throw SonioxServiceError.connection }
        try await task.send(.string(text))
    }

    func send(audio: Data) async throws {
        guard let task else { throw SonioxServiceError.connection }
        try await task.send(.data(audio))
    }

    func finish() async throws {
        guard let task else { throw SonioxServiceError.connection }
        try await task.send(.data(Data()))
    }

    func receive() async throws -> SonioxResponse {
        guard let task else { throw SonioxServiceError.connection }
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: throw SonioxServiceError.connection
        }
        let response = try JSONDecoder().decode(SonioxResponse.self, from: data)
        if response.errorCode != nil || response.errorType != nil {
            let type = response.errorType?.lowercased() ?? ""
            if type.contains("auth") || type.contains("api_key") || type.contains("key") {
                throw SonioxServiceError.invalidKey
            }
            let detail = response.requestID.map { " (request_id: \($0))" } ?? ""
            let message = (response.errorMessage ?? "Sonioxエラー: \(response.errorCode ?? type)") + detail
            if type == "service_unavailable" || type == "request_timeout" || type == "max_duration_reached" {
                throw SonioxServiceError.connection
            }
            throw SonioxServiceError.server(message)
        }
        return response
    }

    func close() {
        closeCurrentConnection()
    }

    private func closeCurrentConnection() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}

@MainActor
final class TranscriptionManager: ObservableObject {
    enum State: Equatable {
        case idle, connecting, recording, interrupted, reconnecting(Int), finishing, failed(String)
        var label: String {
            switch self {
            case .idle: "準備完了"
            case .connecting: "接続中…"
            case .recording: "文字起こし中"
            case .interrupted: "マイクの復帰を待っています…"
            case .reconnecting(let attempt): "再接続中… (\(attempt)回目)"
            case .finishing: "保存中…"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var finalText = ""
    @Published private(set) var provisionalText = ""
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var elapsed: TimeInterval = 0

    var onCompleted: ((String, [TranscriptSegment], TimeInterval) -> Void)?
    /// Receives a recoverable draft whenever visible transcription changes.
    /// The text includes provisional tokens so an unexpected termination loses
    /// at most audio that has not reached Soniox yet.
    var onProgress: ((String, [TranscriptSegment], TimeInterval) -> Void)?
    var isActive: Bool {
        switch state {
        case .connecting, .recording, .interrupted, .reconnecting, .finishing: true
        case .idle, .failed: false
        }
    }

    private let socket = SonioxWebSocket()
    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var accumulator = TranscriptAccumulator()
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var audioStream: AsyncStream<Data>?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var audioTapInstalled = false
    private var startedAt: Date?
    private var apiKey: String?
    private var connectionGeneration = 0
    private var recordingRequested = false
    private var completionDelivered = false

    init() {
        let session = AVAudioSession.sharedInstance()
        interruptionTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification,
                object: session
            ) {
                guard !Task.isCancelled else { return }
                await self?.processInterruption(notification)
            }
        }
        routeChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification,
                object: session
            ) {
                guard !Task.isCancelled else { return }
                await self?.processRouteChange(notification)
            }
        }
    }

    deinit {
        interruptionTask?.cancel()
        routeChangeTask?.cancel()
        receiveTask?.cancel()
        sendTask?.cancel()
        reconnectTask?.cancel()
        timerTask?.cancel()
    }

    func start(apiKey: String) async {
        guard !isActive else { return }
        resetTranscript()
        self.apiKey = apiKey
        recordingRequested = true
        state = .connecting
        guard await requestMicrophonePermission() else {
            recordingRequested = false
            state = .failed(SonioxServiceError.microphoneDenied.localizedDescription)
            return
        }
        do {
            try await connectStream(apiKey: apiKey)
            startedAt = .now
            startTimer()
        } catch {
            if !recordingRequested || state == .interrupted { return }
            await failPermanently(error)
        }
    }

    func stop() async {
        guard isActive, state != .finishing else { return }
        recordingRequested = false
        reconnectTask?.cancel()
        state = .finishing
        stopAudio(deactivateSession: true)
        do {
            try await socket.finish()
            try? await Task.sleep(for: .seconds(5))
            if state == .finishing { await complete() }
        } catch { await complete() }
    }

    private func connectStream(apiKey: String) async throws {
        try await socket.connect(apiKey: apiKey)
        guard !Task.isCancelled, recordingRequested, state != .interrupted, state != .finishing else {
            await socket.close()
            throw CancellationError()
        }
        connectionGeneration += 1
        let generation = connectionGeneration
        if audioTapInstalled {
            startSending(generation: generation)
        } else {
            try startAudio(generation: generation)
        }
        state = .recording
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop(generation: generation) }
    }

    private func receiveLoop(generation: Int) async {
        do {
            while !Task.isCancelled {
                let response = try await socket.receive()
                guard generation == connectionGeneration else { return }
                if let tokens = response.tokens {
                    accumulator.consume(tokens)
                    publishTranscript()
                }
                if response.finished == true {
                    if state == .finishing { await complete() }
                    else if recordingRequested { await recoverFromStreamFailure(generation: generation) }
                    return
                }
            }
        } catch {
            if Task.isCancelled || generation != connectionGeneration || state == .idle { return }
            if state == .finishing { await complete() } else { await fail(error) }
        }
    }

    private func startAudio(generation: Int) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = audioEngine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SonioxServiceError.audioSetup
        }
        self.converter = converter
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            // Each buffer is approximately 128 ms.  Retain roughly 30 seconds
            // of the oldest audio while the network reconnects so a short
            // lock-screen network interruption does not create a transcript gap.
            bufferingPolicy: .bufferingOldest(240)
        )
        audioStream = stream
        audioContinuation = continuation
        input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { [weak self] buffer, _ in
            guard let self, let data = self.convert(buffer, using: converter) else { return }
            continuation.yield(data)
        }
        audioTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        startSending(generation: generation)
    }

    /// Starts (or replaces) only the network sender.  The microphone capture
    /// remains alive across WebSocket reconnects, which keeps the app eligible
    /// for its background-audio execution time while the screen is locked.
    private func startSending(generation: Int) {
        guard let audioStream else { return }
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                for await data in audioStream {
                    try Task.checkCancellation()
                    try await self.socket.send(audio: data)
                }
            } catch is CancellationError {
                return
            } catch {
                await self.recoverFromStreamFailure(generation: generation)
            }
        }
    }

    nonisolated private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let pointer = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: pointer, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    private func stopAudio(deactivateSession: Bool) {
        audioContinuation?.finish()
        audioContinuation = nil
        audioStream = nil
        sendTask?.cancel()
        sendTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if audioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioTapInstalled = false
        }
        converter = nil
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                if self.elapsed >= 17_940 { await self.stop(); return }
            }
        }
    }

    private func complete() async {
        guard state == .finishing || state == .recording else { return }
        recordingRequested = false
        reconnectTask?.cancel()
        stopAudio(deactivateSession: true)
        timerTask?.cancel()
        // Normally Soniox has already sent final tokens by this point.  If the
        // connection ends before that final response, retain the text that was
        // visibly shown as provisional instead of silently discarding it.
        accumulator.finalizeProvisionalTokens()
        publishTranscript()
        receiveTask?.cancel()
        await socket.close()
        state = .idle
        deliverCompletionIfNeeded()
    }

    private func fail(_ error: Error) async {
        if let serviceError = error as? SonioxServiceError {
            switch serviceError {
            case .invalidKey, .server:
                await failPermanently(error)
                return
            case .connection, .microphoneDenied, .audioSetup:
                break
            }
        }
        await recoverFromStreamFailure(generation: connectionGeneration)
    }

    private func recoverFromStreamFailure(generation: Int) async {
        guard generation == connectionGeneration, recordingRequested else { return }
        guard case .recording = state else { return }
        accumulator.beginNewSession()
        publishTranscript()
        // Keep AVAudioEngine and its stream alive.  Stopping either here lets
        // iOS suspend the app in the background and discards audio captured
        // while the WebSocket is being re-established.
        receiveTask?.cancel()
        await socket.close()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil || reconnectTask?.isCancelled == true else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while self.recordingRequested, !Task.isCancelled {
                attempt += 1
                guard self.recordingRequested, !Task.isCancelled else { return }
                self.state = .reconnecting(attempt)
                let seconds = min(30, 1 << min(attempt - 1, 5))
                try? await Task.sleep(for: .seconds(seconds))
                guard self.recordingRequested, !Task.isCancelled, let apiKey = self.apiKey else { return }
                do {
                    try await self.connectStream(apiKey: apiKey)
                    self.reconnectTask = nil
                    return
                } catch {
                    await self.socket.close()
                    if self.isPermanentConnectionError(error) {
                        self.reconnectTask = nil
                        await self.failPermanently(error)
                        return
                    }
                }
            }
            self.reconnectTask = nil
        }
    }

    private func isPermanentConnectionError(_ error: Error) -> Bool {
        guard let error = error as? SonioxServiceError else { return false }
        switch error {
        case .invalidKey, .server:
            return true
        case .connection, .microphoneDenied, .audioSetup:
            return false
        }
    }

    private func failPermanently(_ error: Error) async {
        recordingRequested = false
        reconnectTask?.cancel()
        stopAudio(deactivateSession: true)
        timerTask?.cancel()
        receiveTask?.cancel()
        await socket.close()
        accumulator.finalizeProvisionalTokens()
        publishTranscript()
        deliverCompletionIfNeeded()
        let message = (error as? LocalizedError)?.errorDescription ?? SonioxServiceError.connection.localizedDescription
        state = .failed(message)
    }

    private func deliverCompletionIfNeeded() {
        guard !completionDelivered,
              !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        completionDelivered = true
        onCompleted?(finalText, segments, elapsed)
    }

    func resetTranscript() {
        accumulator = TranscriptAccumulator()
        finalText = ""
        provisionalText = ""
        segments = []
        elapsed = 0
        apiKey = nil
        recordingRequested = false
        completionDelivered = false
        state = .idle
    }

    private func processInterruption(_ notification: Notification) async {
        guard recordingRequested,
              let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
        switch type {
        case .began:
            guard state != .interrupted else { return }
            reconnectTask?.cancel()
            reconnectTask = nil
            state = .interrupted
            accumulator.beginNewSession()
            publishTranscript()
            stopAudio(deactivateSession: false)
            receiveTask?.cancel()
            await socket.close()
        case .ended:
            guard state == .interrupted, recordingRequested else { return }
            scheduleReconnect()
        @unknown default:
            break
        }
    }

    private func processRouteChange(_ notification: Notification) async {
        guard state == .recording,
              let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: value),
              reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .routeConfigurationChange else { return }
        do {
            stopAudio(deactivateSession: false)
            try startAudio(generation: connectionGeneration)
        } catch {
            await recoverFromStreamFailure(generation: connectionGeneration)
        }
    }

    private func publishTranscript() {
        finalText = accumulator.finalText
            .replacingOccurrences(of: "<end>", with: "")
            .replacingOccurrences(of: "<fin>", with: "")
        provisionalText = accumulator.provisionalText
        segments = accumulator.segments
        onProgress?(finalText + provisionalText, segments, elapsed)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}
