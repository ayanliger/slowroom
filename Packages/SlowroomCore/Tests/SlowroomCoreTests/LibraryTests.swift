import AVFoundation
import Foundation
import Testing
@testable import SlowroomCore

@Suite(.serialized)
struct LibraryTests {
    @Test func deletesOnlyVerifiedOriginalAndPreservesLibraryCopy() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Artist - Song.wav")
        let unrelated = root.appendingPathComponent("Unrelated.wav")
        try tone(source, seconds: 2)
        try tone(unrelated, seconds: 3)
        let library = try makeLibrary(root)
        let item = try #require(try await library.importFile(source, kind: .mix))
        let copy = item.audioTrack(in: library.directory).fileURL
        let contents = try Data(contentsOf: copy)
        let plan = try await library.findOriginals([root, source])
        #expect(plan.candidates.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        let result = try await library.deleteOriginals(planID: plan.id)
        #expect(result.deleted == [source.lastPathComponent])
        #expect(result.deletedBytes == item.originalBytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try Data(contentsOf: copy) == contents)
        #expect(await library.allItems() == [item])
    }

    @Test func keepsOriginalWhenItsLibraryCopyChangesAfterPreview() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.wav")
        try tone(source, seconds: 2)
        let library = try makeLibrary(root)
        let item = try #require(try await library.importFile(source, kind: .mix))
        let plan = try await library.findOriginals([source])
        let copy = item.audioTrack(in: library.directory).fileURL
        var damaged = try Data(contentsOf: copy)
        damaged[damaged.count / 2] ^= 1
        try damaged.write(to: copy)
        let result = try await library.deleteOriginals(planID: plan.id)
        #expect(result.deleted.isEmpty)
        #expect(result.issues.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        let next = try await library.findOriginals([source])
        #expect(next.candidates.isEmpty)
    }

    @Test func keepsChangedOriginalAndNeverDeletesLibraryFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.wav")
        try tone(source, seconds: 2)
        let library = try makeLibrary(root)
        let item = try #require(try await library.importFile(source, kind: .source, optimize: false, title: "song"))
        let plan = try await library.findOriginals([source])
        var changed = try Data(contentsOf: source)
        changed[changed.count / 2] ^= 1
        try changed.write(to: source)
        let result = try await library.deleteOriginals(planID: plan.id)
        #expect(result.deleted.isEmpty)
        #expect(result.issues.count == 1)
        #expect(try Data(contentsOf: source) == changed)
        let protected = try await library.findOriginals([library.directory])
        #expect(protected.candidates.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.audioTrack(in: library.directory).fileURL.path))
    }

    @Test func keepsOriginalWhenLibraryCopyIsMissingOrReplacedByLink() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.wav")
        try tone(source, seconds: 2)
        let library = try makeLibrary(root)
        let item = try #require(try await library.importFile(source, kind: .source, optimize: false))
        let copy = item.audioTrack(in: library.directory).fileURL
        try FileManager.default.removeItem(at: copy)
        #expect(try await library.findOriginals([source]).candidates.isEmpty)
        try FileManager.default.createSymbolicLink(at: copy, withDestinationURL: source)
        #expect(try await library.findOriginals([source]).candidates.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func removesDownloaderNamesAndRetainsVersions() {
        let first = LibraryNaming.infer(from: "SpotiDown.App - Song - Remastered 2016 - An Artist-slowedandreverbstudio (1).wav")
        #expect(first.artist == "An Artist")
        #expect(first.title == "Song - Remastered 2016 (Slowed + Reverb) (1)")
        let second = LibraryNaming.infer(from: "An Artist - Song [OFFICIAL VIDEO] - Label (youtube)-slowedandreverbstudio.wav")
        #expect(second.artist == "An Artist")
        #expect(second.title == "Song (Slowed + Reverb)")
        let third = LibraryNaming.infer(from: "Game 3_ Subtitle Music- Boss Battle [aB3deF9hiJK]-slowedandreverbstudio.wav")
        #expect(third.artist == "Game 3 Subtitle")
        #expect(third.title == "Boss Battle (Slowed + Reverb)")
        let fourth = LibraryNaming.infer(from: "SpotiDownloader.com - Song - Artist_s Band (1)-slowedandreverbstudio.wav")
        #expect(fourth.artist == "Artist's Band")
        #expect(fourth.title == "Song (Slowed + Reverb) (1)")
    }

    @Test func cleansExistingImportsWithoutChangingAudioOrManualNames() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("SpotiDown.App - Song - Artist-slowedandreverbstudio.wav")
        try tone(file, seconds: 2)
        let library = try makeLibrary(root)
        let item = try #require(try await library.importFile(file, kind: .mix, title: "Song - Artist-slowedandreverbstudio", artist: "SpotiDown.App"))
        let audio = try Data(contentsOf: item.audioTrack(in: library.directory).fileURL)
        #expect(try await library.cleanImportedNames() == 1)
        let renamed = try #require(await library.allItems().first)
        #expect(renamed.id == item.id)
        #expect(renamed.title == "Song (Slowed + Reverb)")
        #expect(renamed.artist == "Artist")
        #expect(try Data(contentsOf: renamed.audioTrack(in: library.directory).fileURL) == audio)
        try tone(file, seconds: 3)
        _ = try await library.importFile(file, kind: .mix, title: "Song - Artist-slowedandreverbstudio", artist: "SpotiDown.App")
        #expect(try await library.cleanImportedNames() == 1)
        #expect(await library.allItems().last?.title == "Song (Slowed + Reverb) (2)")
        _ = try await library.rename(item.id, title: "My custom mix", artist: "Me")
        #expect(try await library.cleanImportedNames() == 0)
    }

    @Test func cacheCleanupRetainsSourceThroughDirectoryAlias() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cache)
        let active = cache.appendingPathComponent("active.wav")
        let old = cache.appendingPathComponent("old.wav")
        try Data("active".utf8).write(to: active)
        try Data("old".utf8).write(to: old)
        MediaCache.removeOldFiles(in: cache, keeping: alias.appendingPathComponent("active.wav"))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        MediaCache.removeOldFiles(in: cache, keeping: nil)
        #expect(!FileManager.default.fileExists(atPath: active.path))
    }

    @Test func importsCompressesDeduplicatesAndRestores() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Artist - Evening (slowed + reverb).wav")
        try tone(input, seconds: 12, rate: 48_000)
        let original = try Data(contentsOf: input)
        let library = try makeLibrary(root)
        let imported = try #require(try await library.importFile(input, kind: .mix))
        #expect(imported.artist == "Artist")
        #expect(imported.title == "Evening (slowed + reverb)")
        #expect(imported.relativePath == "Slowed + Reverb/Artist - Evening (slowed + reverb).m4a")
        #expect(imported.storedBytes < imported.originalBytes / 3)
        #expect(abs(imported.duration - 12) < 0.15)
        #expect(try Data(contentsOf: input) == original)
        let audio = try AVAudioFile(forReading: imported.audioTrack(in: library.directory).fileURL)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(try frequency(audio) - 220) < 2)
        #expect(try await library.importFile(input, kind: .mix) == nil)
        #expect(try await library.importFile(imported.audioTrack(in: library.directory).fileURL, kind: .mix) == nil)
        let restored = try makeLibrary(root)
        #expect(await restored.allItems() == [imported])
        let moved = root.appendingPathComponent("Moved library")
        try FileManager.default.moveItem(at: library.directory, to: moved)
        let relocated = try AudioLibrary(directory: moved, catalogURL: root.appendingPathComponent("support/library.json"))
        let restoredItem = try #require(await relocated.allItems().first)
        #expect(FileManager.default.fileExists(atPath: restoredItem.audioTrack(in: moved).fileURL.path))
    }

    @Test func avoidsLossyReencodingAndResolvesFilenameCollisions() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("one.wav")
        let aac = root.appendingPathComponent("Artist - Song.m4a")
        try tone(input, seconds: 4)
        try AudioCompressor.encodeAAC(input: input, output: aac)
        let original = try Data(contentsOf: aac)
        let library = try makeLibrary(root)
        let first = try #require(try await library.importFile(aac, kind: .mix))
        #expect(first.storedBytes == first.originalBytes)
        #expect(try Data(contentsOf: first.audioTrack(in: library.directory).fileURL) == original)
        try tone(input, seconds: 5)
        let second = try #require(try await library.importFile(input, kind: .mix, title: "Song", artist: "Artist"))
        #expect(first.relativePath != second.relativePath)
        #expect(second.relativePath.hasSuffix("(2).m4a"))
        let renamed = try await library.rename(first.id, title: "../New / title", artist: "A:B")
        #expect(!renamed.relativePath.contains("../"))
        #expect(renamed.relativePath.split(separator: "/").count == 2)
        #expect(FileManager.default.fileExists(atPath: renamed.audioTrack(in: library.directory).fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: first.audioTrack(in: library.directory).fileURL.path))
        let restored = try makeLibrary(root)
        #expect(await restored.allItems().first?.title == renamed.title)
    }

    @Test func batchImportPreservesSuccessWhenAnotherFileFails() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try tone(inputs.appendingPathComponent("good.wav"), seconds: 2)
        try Data("invalid".utf8).write(to: inputs.appendingPathComponent("bad.wav"))
        try Data("ignore".utf8).write(to: inputs.appendingPathComponent("notes.txt"))
        let library = try makeLibrary(root)
        let report = await library.importFiles([inputs], kind: .mix, optimize: true)
        #expect(report.added.count == 1)
        #expect(report.failures.count == 1)
        #expect(await library.allItems().count == 1)
        let files = try FileManager.default.contentsOfDirectory(at: library.directory.appendingPathComponent("Slowed + Reverb"), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
    }

    @Test func compressionResamplesHighRateWithoutChangingPitch() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("high.wav")
        let output = root.appendingPathComponent("output.m4a")
        try tone(input, seconds: 3, rate: 96_000)
        try AudioCompressor.encodeAAC(input: input, output: output)
        let file = try AVAudioFile(forReading: output)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 3) < 0.15)
        #expect(abs(try frequency(file) - 220) < 2)
    }

    @Test func catalogFailureDoesNotLeaveAnUnindexedCopy() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.wav")
        try tone(input, seconds: 1)
        let library = try makeLibrary(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("support/library.json"), withIntermediateDirectories: true)
        do {
            _ = try await library.importFile(input, kind: .mix)
            Issue.record("Expected the catalog write to fail")
        } catch {}
        #expect(await library.allItems().isEmpty)
        let copies = try FileManager.default.contentsOfDirectory(at: library.directory.appendingPathComponent("Slowed + Reverb"), includingPropertiesForKeys: nil)
        #expect(copies.isEmpty)
        #expect(FileManager.default.fileExists(atPath: input.path))
    }

    private func makeLibrary(_ root: URL) throws -> AudioLibrary {
        try AudioLibrary(directory: root.appendingPathComponent("Slowroom Library"), catalogURL: root.appendingPathComponent("support/library.json"))
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func tone(_ url: URL, seconds: Double, rate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        var position = 0
        let length = Int(seconds * rate)
        while position < length {
            let count = min(4_096, length - position)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 {
                for frame in 0..<count {
                    buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * 220 * Double(position + frame) / rate)) * 0.25
                }
            }
            try writer.write(from: buffer)
            position += count
        }
    }

    private func frequency(_ file: AVAudioFile) throws -> Double {
        file.framePosition = AVAudioFramePosition(file.processingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        var crossings = 0
        for index in 1..<Int(buffer.frameLength) {
            if samples[index - 1] <= 0 && samples[index] > 0 { crossings += 1 }
        }
        return Double(crossings) * file.processingFormat.sampleRate / Double(buffer.frameLength)
    }
}
