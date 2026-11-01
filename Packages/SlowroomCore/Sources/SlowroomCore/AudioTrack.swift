import AVFoundation
import Accelerate
import Foundation

public struct AudioTrack: Codable, Sendable, Equatable {
    public let fileURL: URL
    public let title: String
    public let author: String
    public let sourceURL: URL?
    public let duration: Double
    public let waveform: [Float]

    public static func inspect(
        url: URL,
        title: String,
        author: String = "",
        sourceURL: URL? = nil
    ) throws -> Self {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= Int64(UInt32.max),
              file.processingFormat.channelCount <= 2 else {
            throw AudioError.unsupportedFormat
        }
        let binCount = 160
        let framesPerBin = max(1, Double(file.length) / Double(binCount))
        var peaks = [Float](repeating: 0, count: binCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw AudioError.noAudio
        }
        var offset: Int64 = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var frame = 0
            while frame < Int(buffer.frameLength) {
                let bin = min(binCount - 1, Int(Double(offset + Int64(frame)) / framesPerBin))
                let boundary = Int64(ceil(Double(bin + 1) * framesPerBin))
                let end = min(Int(buffer.frameLength), max(frame + 1, Int(boundary - offset)))
                for channel in 0..<Int(buffer.format.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[channel].advanced(by: frame), 1, &peak, vDSP_Length(end - frame))
                    peaks[bin] = max(peaks[bin], peak)
                }
                frame = end
            }
            offset += Int64(buffer.frameLength)
        }
        let maximum = max(peaks.max() ?? 0, 0.001)
        return Self(
            fileURL: url, title: title, author: author,
            sourceURL: sourceURL,
            duration: Double(file.length) / file.processingFormat.sampleRate,
            waveform: peaks.map { $0 / maximum }
        )
    }
}
