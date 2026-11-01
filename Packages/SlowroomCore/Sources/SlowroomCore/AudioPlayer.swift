import AVFoundation
import Observation

@MainActor
@Observable
public final class AudioPlayer {
    public private(set) var track: AudioTrack?
    public private(set) var settings = EffectSettings()
    public private(set) var isPlaying = false
    public private(set) var isOriginal = false
    public private(set) var position: Double = 0
    public var isLooping = false
    @ObservationIgnored public var onPlaybackEnded: (@MainActor () -> Void)?

    @ObservationIgnored private var graph: AudioGraph?
    @ObservationIgnored private var scheduledStart: Double = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {}

    public var duration: Double { track?.duration ?? 0 }
    public var effectiveSpeed: Double { isOriginal ? 1 : Double(settings.speed) }

    public func load(_ track: AudioTrack) throws {
        let next = try AudioGraph(url: track.fileURL, settings: isOriginal ? settings.original : settings)
        stop()
        graph?.engine.stop()
        graph = next
        self.track = track
        position = 0
        schedule(at: 0)
    }

    public func clear() {
        stop()
        graph?.engine.stop()
        graph = nil
        track = nil
        position = 0
    }

    public func update(_ value: EffectSettings) {
        updatePosition()
        settings = value.clamped
        graph?.apply(isOriginal ? settings.original : settings)
    }

    public func compareOriginal(_ enabled: Bool) {
        updatePosition()
        isOriginal = enabled
        graph?.apply(enabled ? settings.original : settings)
    }

    public func play() throws {
        guard let graph, !isPlaying else { return }
        if position >= duration - 0.01 { schedule(at: 0) }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        #endif
        if !graph.engine.isRunning {
            graph.engine.prepare()
            try graph.engine.start()
        }
        graph.player.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
                self?.updatePosition()
            }
        }
    }

    public func pause() {
        updatePosition()
        graph?.player.pause()
        isPlaying = false
        ticker?.cancel()
    }

    public func seek(to seconds: Double) {
        guard let graph else { return }
        let resume = isPlaying
        schedule(at: min(max(0, seconds), max(0, duration - 0.001)))
        if resume {
            graph.player.play()
            isPlaying = true
        }
    }

    public func recoverAfterAudioChange() {
        pause()
        guard let track else { return }
        graph?.engine.stop()
        if let replacement = try? AudioGraph(url: track.fileURL, settings: isOriginal ? settings.original : settings) {
            graph = replacement
        }
        schedule(at: min(position, max(0, duration - 0.001)))
    }

    private func stop() {
        generation = UUID()
        ticker?.cancel()
        isPlaying = false
        graph?.player.stop()
    }

    private func schedule(at seconds: Double) {
        guard let graph else { return }
        generation = UUID()
        let token = generation
        graph.player.stop()
        graph.clearTail()
        let frame = min(graph.file.length - 1, AVAudioFramePosition(seconds * graph.file.processingFormat.sampleRate))
        scheduledStart = Double(frame) / graph.file.processingFormat.sampleRate
        position = scheduledStart
        graph.player.scheduleSegment(
            graph.file, startingFrame: frame,
            frameCount: AVAudioFrameCount(graph.file.length - frame), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isPlaying else { return }
                if self.isLooping {
                    self.seek(to: 0)
                } else {
                    self.isPlaying = false
                    self.position = self.duration
                    self.ticker?.cancel()
                    self.onPlaybackEnded?()
                }
            }
        }
    }

    private func updatePosition() {
        guard isPlaying, let graph,
              let renderTime = graph.player.lastRenderTime,
              let time = graph.player.playerTime(forNodeTime: renderTime) else { return }
        position = min(duration, scheduledStart + max(0, Double(time.sampleTime) / time.sampleRate))
    }
}
