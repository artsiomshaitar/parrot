import AVFoundation
import Foundation

/// Captures microphone audio and returns it as 16 kHz mono Float32.
final class AudioCapture {
    enum CaptureError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case converterCreationFailed
        case inputUnavailable

        var description: String {
            switch self {
            case .engineStartFailed(let error): return "couldn't start audio engine: \(error)"
            case .converterCreationFailed: return "couldn't create audio converter"
            case .inputUnavailable: return "input device reported no usable format"
            }
        }
    }

    static let targetSampleRate: Double = 16_000

    /// Recreated after each capture; a stopped engine still holds the device.
    private var engine = AVAudioEngine()
    /// Rebuilt when the input format changes, as it does on a codec switch.
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var samples: [Float] = []
    /// Engine running and tapped. Not the same as collecting.
    private var isOpen = false
    /// Whether buffers are being kept — the key is held.
    private var isCollecting = false
    private var teardown: DispatchWorkItem?
    private let lock = NSLock()

    /// Seconds to keep the mic running after a dictation. 0 releases at once.
    var holdSeconds: TimeInterval = 0

    /// Buffer RMS level (0…~1). Called on an arbitrary thread.
    var onLevel: ((Float) -> Void)?

    /// Fires when audio actually starts, which lags `start()` by 40–235ms.
    var onFirstBuffer: ((TimeInterval) -> Void)?

    private var collectingSince: Date?
    private var sawFirstBuffer = false

    var debug = false

    private var configObserver: NSObjectProtocol?

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func handleConfigurationChange() {
        guard isOpen else { return }
        if debug { logLine("mic: audio configuration changed") }
        let wasCollecting = isCollecting
        lock.lock()
        let sofar = samples
        lock.unlock()

        isCollecting = false
        releaseDevice()
        guard wasCollecting else { return }
        do {
            try start()
            lock.lock()
            samples.insert(contentsOf: sofar, at: 0)
            lock.unlock()
            if debug {
                logLine(String(
                    format: "mic: restarted after configuration change (kept %.2fs)",
                    Double(sofar.count) / Self.targetSampleRate
                ))
            }
        } catch {
            logLine("mic: couldn't restart after configuration change: \(error)")
        }
    }

    /// Idempotent — starting while already recording is a no-op.
    func start() throws {
        teardown?.cancel()
        teardown = nil
        guard !isCollecting else { return }

        if isOpen {
            lock.lock()
            samples.removeAll(keepingCapacity: true)
            lock.unlock()
            isCollecting = true
            collectingSince = Date()
            sawFirstBuffer = false
            if debug { logLine("mic: resumed (engine already running)") }
            return
        }

        let input = engine.inputNode
        guard input.outputFormat(forBus: 0).sampleRate > 0 else {
            throw CaptureError.inputUnavailable
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        converter = nil
        converterInput = nil

        input.removeTap(onBus: 0)

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        isOpen = true
        isCollecting = true
        collectingSince = Date()
        sawFirstBuffer = false
        if debug { logLine("mic: engine started") }
    }

    @discardableResult
    func stop() -> [Float] {
        guard isCollecting else { return [] }
        isCollecting = false

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        if holdSeconds > 0 {
            if debug { logLine(String(format: "mic: holding %.0fs for another dictation", holdSeconds)) }
            let work = DispatchWorkItem { [weak self] in self?.releaseDevice() }
            teardown = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds, execute: work)
        } else {
            releaseDevice()
        }
        return captured
    }

    /// Hands the device back; a Bluetooth headset leaves call mode ~200ms later.
    private func releaseDevice() {
        teardown = nil
        guard isOpen, !isCollecting else { return }
        if debug { logLine("mic: releasing engine") }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isOpen = false
        engine = AVAudioEngine()
        converter = nil
    }

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCapture.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private func process(buffer: AVAudioPCMBuffer) {
        guard isCollecting else { return }

        if !sawFirstBuffer {
            sawFirstBuffer = true
            let waited = collectingSince.map { Date().timeIntervalSince($0) } ?? 0
            if debug { logLine(String(format: "mic: first audio after %.0fms", waited * 1000)) }
            onFirstBuffer?(waited)
        }

        let targetFormat = Self.targetFormat
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInput = buffer.format
            if debug { logLine("mic: input format now \(Int(buffer.format.sampleRate)) Hz") }
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
    }
}

// MARK: - WAV writer (for debugging M3 captures)

enum WAVWriter {
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
