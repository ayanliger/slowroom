import AVFoundation
import Foundation
import Testing
@testable import SlowroomCore

@Suite(.serialized)
struct AudioTests {
    @Test func slowedAudioHasExpectedDurationAndLowerPitch() throws {
        try withFixture { input, output in
            var settings = EffectSettings()
            settings.speed = 0.5
            settings.reverb = 0
            try AudioRenderer.render(input: input, output: output, settings: settings)
            let samples = try read(output)
            #expect(abs(samples.duration - 4) < 0.01)
            #expect(abs(samples.frequency - 100) < 3)
        }
    }

    @Test func pitchPreservingSlowdownRetainsTheInputFrequency() throws {
        try withFixture { input, output in
            var settings = EffectSettings()
            settings.speed = 0.5
            settings.preservePitch = true
            settings.reverb = 0
            try AudioRenderer.render(input: input, output: output, settings: settings)
            let samples = try read(output)
            #expect(abs(samples.duration - 4) < 0.01)
            #expect(abs(samples.frequency - 200) < 3)
        }
    }

    @Test func independentPitchShiftChangesAnOctave() throws {
        try withFixture { input, output in
            var settings = EffectSettings()
            settings.speed = 1
            settings.pitch = 12
            settings.reverb = 0
            try AudioRenderer.render(input: input, output: output, settings: settings)
            #expect(abs(try read(output).frequency - 400) < 5)
        }
    }

    @Test func reverbProducesATailAndExportHasSixteenBitPCM() throws {
        try withFixture { input, output in
            var settings = EffectSettings()
            settings.speed = 1
            settings.reverb = 60
            settings.room = .hall
            try AudioRenderer.render(input: input, output: output, settings: settings)
            let result = try read(output)
            #expect(abs(result.duration - 6) < 0.01)
            #expect(result.tailRMS > 0.00001)
            let file = try AVAudioFile(forReading: output)
            #expect(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        }
    }

    @Test func invalidInputDoesNotProduceAnExport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("invalid.wav")
        let output = folder.appendingPathComponent("output.wav")
        try Data("not audio".utf8).write(to: source)
        #expect(throws: (any Error).self) {
            try AudioRenderer.render(input: source, output: output, settings: EffectSettings())
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func demoProducesStereoAudioAndWaveform() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = try DemoAudio.create(in: folder)
        #expect(abs(demo.duration - 24) < 0.01)
        #expect(demo.waveform.count == 160)
        #expect((demo.waveform.max() ?? 0) > 0.9)
        #expect(try AVAudioFile(forReading: demo.fileURL).processingFormat.channelCount == 2)
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("tone.caf")
        let output = folder.appendingPathComponent("output.wav")
        try writeTone(to: input)
        try body(input, output)
    }

    private func writeTone(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
        buffer.frameLength = 88_200
        for index in 0..<88_200 {
            buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 200 * Double(index) / 44_100)) * 0.25
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func read(_ url: URL) throws -> (duration: Double, frequency: Double, tailRMS: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let rate = file.processingFormat.sampleRate
        let start = Int(rate * 0.5)
        let end = min(Int(buffer.frameLength) - 1, start + Int(rate))
        var crossings = 0
        for index in start..<end {
            if samples[index] <= 0 && samples[index + 1] > 0 { crossings += 1 }
        }
        let tailStart = min(Int(buffer.frameLength) - 1, Int(rate * 2.05))
        let tailEnd = min(Int(buffer.frameLength), tailStart + Int(rate * 0.5))
        var sum = 0.0
        for index in tailStart..<tailEnd { sum += Double(samples[index] * samples[index]) }
        return (
            Double(file.length) / rate,
            Double(crossings) * rate / Double(end - start),
            sqrt(sum / Double(max(1, tailEnd - tailStart)))
        )
    }
}
