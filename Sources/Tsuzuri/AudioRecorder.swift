import AVFoundation
import CoreAudio
import TsuzuriCore

enum RecorderError: Error {
    case noInputDevice
    case permissionDenied

    /// Short text for the overlay.
    var message: String {
        switch self {
        case .noInputDevice: String(localized: "No microphone found")
        case .permissionDenied: String(localized: "Microphone access is off (menu → Permissions…)")
        }
    }
}

/// Captures the default input device as mono Float32 at 16 kHz.
///
/// A new `AVAudioEngine` is created for every recording. An engine binds its input
/// node to whatever device was the default when it was first used; after the device
/// changes (AirPods connect / disconnect) or disappears, a reused engine reports a
/// stale format and `installTap` raises an Objective-C exception that Swift cannot
/// catch, which crashes the app.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(Transcriber.sampleRate),
                                             channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []

    /// Called on the audio thread with an RMS level in 0...1.
    var onLevel: ((Float) -> Void)?

    /// Called on the main queue when the input device changes or goes away while
    /// recording. Capture has already stopped; `stop()` still returns what was recorded.
    var onInterrupted: (() -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Whether the system currently has a default input device at all
    /// (a Mac mini or Mac Studio has none until a mic or headset is connected).
    static var hasInputDevice: Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown
    }

    func start() throws {
        tearDown()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw RecorderError.permissionDenied
        default: break
        }
        guard Self.hasInputDevice else { throw RecorderError.noInputDevice }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        // installTap throws an uncatchable exception unless the tap format matches
        // the hardware; check it here so a vanished device becomes a normal error.
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              inputFormat.sampleRate == hardwareFormat.sampleRate,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.noInputDevice
        }

        lock.withLock { samples.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, with: converter)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, self.engine === engine else { return }
            self.onInterrupted?()
        }
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            throw error
        }
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        tearDown()
        return lock.withLock { samples }
    }

    private func tearDown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func consume(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        lock.withLock { samples.append(contentsOf: chunk) }
        if let onLevel, !chunk.isEmpty {
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            onLevel(min(1, rms * 8))
        }
    }
}
