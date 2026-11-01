import AVFoundation

public enum AudioCompressor {
    public static func encodeAAC(input: URL, output: URL, progress: @Sendable (Double) -> Void = { _ in }) throws {
        let reader = try AVAudioFile(forReading: input)
        guard reader.length > 0, (1...2).contains(reader.processingFormat.channelCount) else {
            throw AudioError.unsupportedFormat
        }
        let rate = min(48_000, max(16_000, reader.processingFormat.sampleRate))
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        // Closing the writer finalizes the M4A header before validation opens it.
        do {
            let writer = try AVAudioFile(forWriting: output, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: reader.processingFormat.channelCount,
                AVEncoderBitRateKey: reader.processingFormat.channelCount == 1 ? 128_000 : 256_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            defer { writer.close() }
            guard let converter = AVAudioConverter(from: reader.processingFormat, to: writer.processingFormat),
                  let source = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8_192),
                  let destination = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 8_192) else {
                throw AudioError.renderFailed
            }
            var readError: Error?
            var lastPercent = -1
            while true {
                try Task.checkCancellation()
                var conversionError: NSError?
                let status = converter.convert(to: destination, error: &conversionError) { count, status in
                    guard reader.framePosition < reader.length else {
                        status.pointee = .endOfStream
                        return nil
                    }
                    do {
                        let remaining = AVAudioFrameCount(min(Int64(source.frameCapacity), reader.length - reader.framePosition))
                        try reader.read(into: source, frameCount: min(count, remaining))
                        status.pointee = source.frameLength == 0 ? .endOfStream : .haveData
                        return source.frameLength == 0 ? nil : source
                    } catch {
                        readError = error
                        status.pointee = .endOfStream
                        return nil
                    }
                }
                if let readError { throw readError }
                if let conversionError { throw conversionError }
                if destination.frameLength > 0 { try writer.write(from: destination) }
                let fraction = Double(reader.framePosition) / Double(reader.length)
                if Int(fraction * 100) != lastPercent {
                    lastPercent = Int(fraction * 100)
                    progress(fraction)
                }
                if status == .endOfStream { break }
                if status == .error { throw AudioError.renderFailed }
            }
        }
        let check = try AudioTrack.inspect(url: output, title: "")
        let duration = Double(reader.length) / reader.processingFormat.sampleRate
        guard abs(check.duration - duration) < 0.15 else { throw AudioError.renderFailed }
        completed = true
        progress(1)
    }
}
