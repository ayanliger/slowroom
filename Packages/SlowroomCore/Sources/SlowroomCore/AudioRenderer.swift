import AVFoundation

public enum AudioRenderer {
    public static func render(
        input: URL,
        output: URL,
        settings: EffectSettings,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws {
        let settings = settings.clamped
        let graph = try step("open the source") { try AudioGraph(url: input, settings: settings) }
        let format = graph.processingFormat
        try step("prepare the renderer") {
            try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw AudioError.renderFailed
        }
        let writer = try step("create the output file") { try AVAudioFile(
            forWriting: output,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) }
        var completed = false
        defer {
            writer.close()
            graph.player.stop()
            graph.engine.stop()
            graph.engine.disableManualRenderingMode()
            if !completed { try? FileManager.default.removeItem(at: output) }
        }
        graph.player.scheduleFile(graph.file, at: nil)
        try step("start the renderer") { try graph.engine.start() }
        graph.player.play()

        let tail = settings.reverb > 0 ? settings.room.tailDuration : 0
        let total = AVAudioFramePosition(ceil((graph.duration / Double(settings.speed) + tail) * format.sampleRate))
        var stalled = 0
        var reported = -1
        while graph.engine.manualRenderingSampleTime < total {
            try Task.checkCancellation()
            let remaining = total - graph.engine.manualRenderingSampleTime
            let count = AVAudioFrameCount(min(4_096, remaining))
            let status = try step("render audio") { try graph.engine.renderOffline(count, to: buffer) }
            switch status {
            case .success:
                guard buffer.frameLength > 0 else { throw AudioError.renderFailed }
                try step("write the output file") { try writer.write(from: buffer) }
                stalled = 0
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalled += 1
                guard stalled < 32 else { throw AudioError.renderFailed }
            case .error:
                throw AudioError.renderFailed
            @unknown default:
                throw AudioError.renderFailed
            }
            let fraction = Double(graph.engine.manualRenderingSampleTime) / Double(total)
            if Int(fraction * 100) != reported {
                reported = Int(fraction * 100)
                progress(fraction)
            }
        }
        completed = true
        progress(1)
    }

    private static func step<T>(_ action: String, operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            throw NSError(domain: "SlowroomRender", code: (error as NSError).code,
                          userInfo: [NSLocalizedDescriptionKey: "Could not \(action). \(error.localizedDescription)"])
        }
    }
}
