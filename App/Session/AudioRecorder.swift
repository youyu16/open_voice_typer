@preconcurrency import AVFoundation
import Foundation

/// Captures microphone audio via an `AVAudioEngine` tap, downsamples to
/// 16 kHz mono 16-bit PCM, and finalizes capture windows to WAV files.
///
/// Engine lifetime and capture are separate on purpose: during a keyboard
/// session the engine runs continuously (an active audio session is what
/// keeps the app alive in the background), while capture only spans one
/// dictation. Buffers outside a capture window are discarded.
///
/// The tap callback runs on an audio thread, so mutable state is lock-guarded.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples = Data()
    private var capturing = false
    private var converter: AVAudioConverter?

    /// Called on the main queue with a 0...1 mic level while the engine runs.
    var onLevel: (@Sendable (Float) -> Void)?

    private(set) var isEngineRunning = false

    /// False when an audio-session interruption (call, Siri, another app
    /// grabbing the mic) has stopped the engine underneath us while a
    /// session logically remains open.
    var isEngineHealthy: Bool {
        isEngineRunning && engine.isRunning
    }

    var isCapturing: Bool {
        lock.withLock { capturing }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Engine lifecycle

    func startEngine() throws {
        guard !isEngineRunning else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try audioSession.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.formatUnavailable
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, targetFormat: targetFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Unwind the tap before rethrowing. Only one tap may exist per bus,
            // and installing a second one raises an Objective-C exception that
            // Swift cannot catch — so leaving this one behind would turn a
            // recoverable start failure (session grabbed by a call, route
            // change mid-start) into a crash the moment the user pressed Start
            // again. `removeTap` on an untapped bus is a no-op.
            input.removeTap(onBus: 0)
            throw error
        }
        isEngineRunning = true
    }

    /// Restarts a running-but-interrupted engine (the tap survives; only the
    /// session activation and engine need a kick). No-op when healthy.
    func recoverEngine() throws {
        guard isEngineRunning, !engine.isRunning else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try engine.start()
    }

    /// Full teardown and rebuild, for when `recoverEngine()` can't help.
    ///
    /// Recovery reuses the tap and converter installed by `startEngine()`, and
    /// both are bound to the input format sampled at that moment. An
    /// interruption that changes the route (headphones pulled, a call ending on
    /// a different device) leaves them describing hardware that no longer
    /// exists, and the engine can never be started against them again — every
    /// later `recoverEngine()` throws the same error forever. Dropping the tap
    /// and re-sampling the format is the only way out.
    func restartEngine() throws {
        stopEngine()
        try startEngine()
    }

    func stopEngine() {
        guard isEngineRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isEngineRunning = false
        lock.withLock {
            capturing = false
            samples = Data()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { [onLevel] in onLevel?(0) }
    }

    // MARK: Capture windows

    func beginCapture() {
        lock.withLock {
            samples = Data()
            capturing = true
        }
    }

    /// Ends the capture window and returns it as a complete WAV file.
    func endCapture() -> Data {
        let pcm = lock.withLock {
            capturing = false
            let data = samples
            samples = Data()
            return data
        }
        return Self.wavFile(fromPCM: pcm)
    }

    func cancelCapture() {
        lock.withLock {
            capturing = false
            samples = Data()
        }
    }

    // MARK: Audio thread

    private func consume(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside convert(to:error:).
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.int16ChannelData else { return }

        let frameCount = Int(converted.frameLength)
        guard frameCount > 0 else { return }

        var sumSquares: Float = 0
        for frame in 0..<frameCount {
            let normalized = Float(channel[0][frame]) / Float(Int16.max)
            sumSquares += normalized * normalized
        }

        lock.withLock {
            guard capturing else { return }
            let chunk = channel[0].withMemoryRebound(to: UInt8.self, capacity: frameCount * 2) {
                Data(bytes: $0, count: frameCount * 2)
            }
            samples.append(chunk)
        }

        // Map RMS to a 0...1 level with a floor so quiet speech still registers.
        let rms = sqrt(sumSquares / Float(frameCount))
        let level = min(1, rms * 8)
        DispatchQueue.main.async { [onLevel] in onLevel?(level) }
    }

    // MARK: WAV encoding

    /// Wraps raw 16 kHz mono 16-bit PCM in a standard 44-byte WAV header.
    static func wavFile(fromPCM pcm: Data) -> Data {
        let sampleRate = UInt32(Self.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * bitsPerSample / 8

        // Sized up front: this runs the moment the user stops speaking, and
        // growing a header into a megabyte of audio would recopy the whole
        // buffer on the way to the transcription request.
        var header = Data()
        header.reserveCapacity(44 + pcm.count)
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendLittleEndian(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1)) // PCM
        header.appendLittleEndian(channels)
        header.appendLittleEndian(sampleRate)
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)
        header.append(contentsOf: Array("data".utf8))
        header.appendLittleEndian(UInt32(pcm.count))
        header.append(pcm)
        return header
    }
}

enum AudioRecorderError: LocalizedError {
    case formatUnavailable
    case microphonePermissionDenied
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            "Could not configure the 16 kHz recording format."
        case .microphonePermissionDenied:
            "Microphone permission was denied. Enable it in iOS Settings."
        case .engineUnavailable:
            "The microphone is unavailable — another app or a call may be using it. Tap the mic to start it again."
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
