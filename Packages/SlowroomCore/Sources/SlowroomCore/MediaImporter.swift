import AVFoundation

public enum MediaImporter {
    public static func load(_ source: URL, directory: URL) async throws -> AudioTrack {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let title = source.deletingPathExtension().lastPathComponent
        let destination: URL
        if (try? AVAudioFile(forReading: source)) != nil {
            destination = directory.appendingPathComponent(identifier).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            let asset = AVURLAsset(url: source)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                  try await !asset.load(.hasProtectedContent),
                  let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw AudioError.noAudio
            }
            destination = directory.appendingPathComponent(identifier).appendingPathExtension("m4a")
            do { try await export.export(to: destination, as: .m4a) }
            catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        do {
            return try AudioTrack.inspect(url: destination, title: title, author: "Imported file")
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

public enum DemoAudio {
    public static func create(in directory: URL) throws -> AudioTrack {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("evening-study.caf")
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(sampleRate * 24)
        let chords: [[Double]] = [[130.81, 164.81, 196, 246.94], [110, 130.81, 164.81, 196],
                                  [87.31, 130.81, 174.61, 220], [98, 146.83, 196, 246.94]]
        var offset = 0
        while offset < total {
            try Task.checkCancellation()
            let count = min(4_096, total - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = buffer.floatChannelData!
            for frame in 0..<count {
                let time = Double(offset + frame) / sampleRate
                let chord = chords[min(3, Int(time / 6))]
                let beat = time.truncatingRemainder(dividingBy: 0.75)
                let note = chord[Int(time / 0.75) % chord.count] * 2
                let pluck = sin(2 * .pi * note * time) * exp(-beat * 6) * 0.18
                let envelope = min(1, time / 0.1) * min(1, (24 - time) / 0.5)
                let chordTime = time.truncatingRemainder(dividingBy: 6)
                let padEnvelope = min(1, chordTime / 0.3) * min(1, (6 - chordTime) / 0.4)
                for channel in 0..<2 {
                    let detune = channel == 0 ? 0.999 : 1.001
                    let pad = chord.reduce(0.0) { $0 + sin(2 * .pi * $1 * detune * time) } * 0.035
                    channels[channel][frame] = Float((pad * padEnvelope + pluck) * envelope)
                }
            }
            try file.write(from: buffer)
            offset += count
        }
        file.close()
        return try AudioTrack.inspect(url: url, title: "Evening study", author: "Built-in synth demo")
    }
}
