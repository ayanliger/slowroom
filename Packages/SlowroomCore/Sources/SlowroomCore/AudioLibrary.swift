import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public actor AudioLibrary {
    public nonisolated let directory: URL
    private let catalogURL: URL
    private var items: [LibraryItem]
    private let fileManager = FileManager.default

    public init(directory: URL, catalogURL: URL) throws {
        self.directory = directory
        self.catalogURL = catalogURL
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            items = try JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: catalogURL))
            guard items.allSatisfy({ Self.validPath($0.relativePath) }) else { throw LibraryError.invalidCatalog }
        } else { items = [] }
        for kind in LibraryKind.allCases {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(kind.rawValue),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func allItems() -> [LibraryItem] { items }

    public func importFiles(
        _ selections: [URL], kind: LibraryKind, optimize: Bool,
        progress: @Sendable (String) -> Void = { _ in }
    ) async -> LibraryImportReport {
        var report = LibraryImportReport()
        for selection in selections {
            let access = selection.startAccessingSecurityScopedResource()
            defer { if access { selection.stopAccessingSecurityScopedResource() } }
            do {
                let files = try Self.audioFiles(in: selection)
                if files.isEmpty { report.failures.append(selection.lastPathComponent + ": no audio files found.") }
                for (index, url) in files.enumerated() {
                    if Task.isCancelled { report.cancelled = true; return report }
                    progress("\(index + 1)/\(files.count) · \(url.lastPathComponent)")
                    do {
                        if let item = try await importFile(url, kind: kind, optimize: optimize) {
                            report.added.append(item)
                        } else { report.duplicates += 1 }
                    } catch is CancellationError { report.cancelled = true; return report }
                    catch { report.failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
                }
            } catch { report.failures.append(selection.lastPathComponent + ": " + error.localizedDescription) }
        }
        return report
    }

    public func importFile(
        _ source: URL, kind: LibraryKind, optimize: Bool = true,
        title: String? = nil, artist: String? = nil, sourceURL: URL? = nil, effects: EffectSettings? = nil
    ) async throws -> LibraryItem? {
        let staging = catalogURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let local = staging.appendingPathComponent(source.lastPathComponent)
        try Self.coordinatedCopy(source, to: local)
        try Task.checkCancellation()
        let fingerprint = try Self.fingerprint(local)
        if isDuplicate(fingerprint, kind: kind) { return nil }
        let originalBytes = try Self.bytes(local)
        let names = await Self.names(for: local)
        let finalTitle = LibraryNaming.clean(title ?? names.title)
        let finalArtist = LibraryNaming.clean(artist ?? names.artist)
        let playable: URL
        if let file = try? AVAudioFile(forReading: local) {
            let format = file.fileFormat.streamDescription.pointee.mFormatID
            let lossless = [kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC].contains(format)
            if optimize && lossless {
                let compressed = staging.appendingPathComponent(UUID().uuidString + ".m4a")
                try AudioCompressor.encodeAAC(input: local, output: compressed)
                playable = try Self.bytes(compressed) < originalBytes ? compressed : local
            } else { playable = local }
        } else {
            let imported = try await MediaImporter.load(local, directory: staging.appendingPathComponent("audio"))
            playable = imported.fileURL
        }
        try Task.checkCancellation()
        if isDuplicate(fingerprint, kind: kind) { return nil }
        let track = try AudioTrack.inspect(url: playable, title: finalTitle, author: finalArtist, sourceURL: sourceURL)
        let path = availablePath(title: finalTitle, artist: finalArtist, kind: kind, extension: playable.pathExtension)
        let destination = directory.appendingPathComponent(path)
        let item = LibraryItem(id: UUID(), title: finalTitle, artist: finalArtist, relativePath: path, kind: kind,
                               addedAt: Date(), duration: track.duration, waveform: track.waveform,
                               originalBytes: originalBytes, storedBytes: try Self.bytes(playable),
                               originalName: source.lastPathComponent, fingerprint: fingerprint,
                               storedFingerprint: try Self.fingerprint(playable),
                               sourceURL: sourceURL, effects: effects)
        try fileManager.moveItem(at: playable, to: destination)
        do { try persist(items + [item]) }
        catch { try? fileManager.removeItem(at: destination); throw error }
        items.append(item)
        return item
    }

    public func rename(_ id: UUID, title: String, artist: String) throws -> LibraryItem {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingFile }
        var item = items[index]
        let oldURL = directory.appendingPathComponent(item.relativePath)
        item.title = LibraryNaming.clean(title)
        guard !item.title.isEmpty else { throw LibraryError.emptyTitle }
        item.artist = LibraryNaming.clean(artist)
        item.relativePath = availablePath(title: item.title, artist: item.artist, kind: item.kind,
                                          extension: oldURL.pathExtension, excluding: item.relativePath)
        let newURL = directory.appendingPathComponent(item.relativePath)
        if newURL != oldURL { try fileManager.moveItem(at: oldURL, to: newURL) }
        var updated = items
        updated[index] = item
        do { try persist(updated) }
        catch {
            if newURL != oldURL { try? fileManager.moveItem(at: newURL, to: oldURL) }
            throw error
        }
        items = updated
        return item
    }

    private func persist(_ items: [LibraryItem]) throws {
        try JSONEncoder().encode(items).write(to: catalogURL, options: .atomic)
    }

    private func isDuplicate(_ fingerprint: String, kind: LibraryKind) -> Bool {
        items.contains { ($0.fingerprint == fingerprint || $0.storedFingerprint == fingerprint) && $0.kind == kind
            && fileManager.fileExists(atPath: directory.appendingPathComponent($0.relativePath).path) }
    }

    private func availablePath(title: String, artist: String, kind: LibraryKind, extension ext: String, excluding: String? = nil) -> String {
        let base = kind.rawValue + "/" + LibraryNaming.basename(title: title, artist: artist, kind: kind)
        var candidate = base + "." + ext.lowercased()
        var count = 2
        while candidate != excluding && (items.contains(where: { $0.relativePath == candidate })
            || fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)) {
            candidate = base + " (\(count))." + ext.lowercased()
            count += 1
        }
        return candidate
    }

    private static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && LibraryKind.allCases.contains(where: { $0.rawValue == parts[0] })
            && !parts[1].isEmpty && parts[1] != "." && parts[1] != ".."
    }

    private static func audioFiles(in selection: URL) throws -> [URL] {
        let values = try selection.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { return [selection] }
        guard let enumerator = FileManager.default.enumerator(at: selection,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw LibraryError.missingFile }
        var files: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey])
            if value.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            let type = value.contentType ?? UTType(filenameExtension: url.pathExtension)
            if value.isRegularFile == true && (type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true) {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func coordinatedCopy(_ source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: url, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private static func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(_ url: URL) throws -> Int64 {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }

    private static func names(for url: URL) async -> (title: String, artist: String) {
        let fallback = LibraryNaming.infer(from: url.lastPathComponent)
        let metadata = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        var title: String?
        var artist: String?
        for item in metadata {
            if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
        }
        return (title?.isEmpty == false ? title! : fallback.title,
                artist?.isEmpty == false ? artist! : fallback.artist)
    }
}

public enum LibraryError: LocalizedError {
    case invalidCatalog, missingFile, emptyTitle
    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The library index contains an invalid path. Its files have been preserved."
        case .missingFile: "This file is no longer in the library folder. Import it again from Files."
        case .emptyTitle: "Enter a title for this track."
        }
    }
}
