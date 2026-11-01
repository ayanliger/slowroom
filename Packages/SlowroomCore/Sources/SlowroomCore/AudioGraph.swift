import AVFoundation

public final class AudioGraph {
    public let engine = AVAudioEngine()
    public let player = AVAudioPlayerNode()
    public let file: AVAudioFile
    public let processingFormat: AVAudioFormat
    private let inputMixer = AVAudioMixerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let timePitch = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
    private var currentRoom: ReverbRoom?

    public init(url: URL, settings: EffectSettings) throws {
        file = try AVAudioFile(forReading: url)
        processingFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 2)!
        guard file.length > 0,
              file.length <= Int64(UInt32.max),
              file.processingFormat.channelCount <= 2 else {
            throw AudioError.unsupportedFormat
        }
        let format = processingFormat
        [player, inputMixer, varispeed, timePitch, reverb].forEach(engine.attach)
        // Normalize mono recordings and stereo songs to the same effect format.
        engine.connect(player, to: inputMixer, format: file.processingFormat)
        engine.connect(inputMixer, to: varispeed, format: format)
        engine.connect(varispeed, to: timePitch, format: format)
        engine.connect(timePitch, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        apply(settings)
    }

    public var duration: Double {
        Double(file.length) / file.processingFormat.sampleRate
    }

    public func apply(_ settings: EffectSettings) {
        let value = settings.clamped
        varispeed.rate = value.preservePitch ? 1 : value.speed
        timePitch.rate = value.preservePitch ? value.speed : 1
        timePitch.pitch = value.pitch * 100
        timePitch.bypass = !value.preservePitch && value.pitch == 0
        if currentRoom != value.room {
            reverb.loadFactoryPreset(value.room.preset)
            currentRoom = value.room
        }
        reverb.wetDryMix = value.reverb
        engine.mainMixerNode.outputVolume = value.volume
    }

    public func clearTail() {
        reverb.auAudioUnit.reset()
    }
}

public enum AudioError: LocalizedError {
    case unsupportedFormat
    case noAudio
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "This audio format cannot be loaded. Use a mono or stereo audio file."
        case .noAudio:
            "This file does not contain a readable audio track."
        case .renderFailed:
            "The audio render stopped. Try exporting again."
        }
    }
}
