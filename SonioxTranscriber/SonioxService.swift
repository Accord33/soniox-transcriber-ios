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

    func send(audio: Data) async throws { try await task?.send(.data(audio)) }
    func finish() async throws { try await task?.send(.data(Data())) }

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
        if let code = response.errorCode {
            if code.lowercased().contains("auth") || code.lowercased().contains("api_key") {
                throw SonioxServiceError.invalidKey
            }
            throw SonioxServiceError.server(response.errorMessage ?? "Sonioxエラー: \(code)")
        }
        return response
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}

@MainActor
final class TranscriptionManager: ObservableObject {
    enum State: Equatable {
        case idle, connecting, recording, finishing, failed(String)
        var label: String {
            switch self {
            case .idle: "準備完了"
            case .connecting: "接続中…"
            case .recording: "文字起こし中"
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
    var isActive: Bool { state == .connecting || state == .recording || state == .finishing }

    private let socket = SonioxWebSocket()
    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var accumulator = TranscriptAccumulator()
    private var receiveTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?

    func start(apiKey: String) async {
        guard !isActive else { return }
        resetTranscript()
        state = .connecting
        guard await requestMicrophonePermission() else {
            state = .failed(SonioxServiceError.microphoneDenied.localizedDescription)
            return
        }
        do {
            try await socket.connect(apiKey: apiKey)
            try startAudio()
            startedAt = .now
            state = .recording
            startTimer()
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
        } catch {
            await fail(error)
        }
    }

    func stop() async {
        guard state == .recording || state == .connecting else { return }
        state = .finishing
        stopAudio()
        do {
            try await socket.finish()
            try? await Task.sleep(for: .seconds(5))
            if state == .finishing { await complete() }
        } catch { await complete() }
    }

    func handleInterruption() async {
        if isActive { await stop() }
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let response = try await socket.receive()
                if let tokens = response.tokens {
                    accumulator.consume(tokens)
                    publishTranscript()
                }
                if response.finished == true { await complete(); return }
            }
        } catch {
            // `complete()` closes the socket and cancels this task.  URLSession
            // then reports a receive error, but that is an expected part of a
            // user-requested stop rather than a connectivity failure.
            if Task.isCancelled || state == .idle { return }
            if state == .finishing { await complete() } else { await fail(error) }
        }
    }

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = audioEngine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SonioxServiceError.audioSetup
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { [weak self] buffer, _ in
            guard let self, let data = self.convert(buffer, using: converter) else { return }
            Task { try? await self.socket.send(audio: data) }
        }
        audioEngine.prepare()
        try audioEngine.start()
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

    private func stopAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        timerTask?.cancel()
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
        stopAudio()
        // Normally Soniox has already sent final tokens by this point.  If the
        // connection ends before that final response, retain the text that was
        // visibly shown as provisional instead of silently discarding it.
        accumulator.finalizeProvisionalTokens()
        publishTranscript()
        receiveTask?.cancel()
        await socket.close()
        state = .idle
        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onCompleted?(finalText, segments, elapsed)
        }
    }

    private func fail(_ error: Error) async {
        stopAudio()
        receiveTask?.cancel()
        await socket.close()
        let message = (error as? LocalizedError)?.errorDescription ?? SonioxServiceError.connection.localizedDescription
        state = .failed(message)
    }

    func resetTranscript() {
        accumulator = TranscriptAccumulator()
        finalText = ""
        provisionalText = ""
        segments = []
        elapsed = 0
        state = .idle
    }

    private func publishTranscript() {
        finalText = accumulator.finalText
            .replacingOccurrences(of: "<end>", with: "")
            .replacingOccurrences(of: "<fin>", with: "")
        provisionalText = accumulator.provisionalText
        segments = accumulator.segments
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}
