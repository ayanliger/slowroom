import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public actor AudioLibrary {
    public nonisolated let directory: URL
    private let catalogURL: URL
    private var items: [LibraryItem]
    private var cleanupPlan: OriginalCleanupPlan?
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

    public func findOriginals(_ selections: [URL], progress: @Sendable (String) -> Void = { _ in }) throws -> OriginalCleanupPlan {
        cleanupPlan = nil
        var candidates: [OriginalCleanupCandidate] = []
        var skipped = 0
        var issues: [String] = []
        var seen = Set<String>()
        let names = Dictionary(grouping: items, by: { $0.originalName.precomposedStringWithCanonicalMapping })
        for selection in selections {
            let access = selection.startAccessingSecurityScopedResource()
            defer { if access { selection.stopAccessingSecurityScopedResource() } }
            for url in try Self.audioFiles(in: selection) {
                try Task.checkCancellation()
                let path = Self.canonicalPath(url)
                guard seen.insert(path).inserted else { continue }
                progress("Checking \(url.lastPathComponent)")
                do {
                    guard !isLibraryFile(url),
                          let possible = names[url.lastPathComponent.precomposedStringWithCanonicalMapping] else {
                        skipped += 1; continue
                    }
                    var matching: LibraryItem?
                    var coordinationError: NSError?
                    var readError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                        do {
                            guard !isLibraryFile(coordinatedURL), try Self.regularFile(coordinatedURL) else { return }
                            let size = try Self.bytes(coordinatedURL)
                            let sized = possible.filter { $0.originalBytes == size }
                            guard !sized.isEmpty else { return }
                            let fingerprint = try Self.fingerprint(coordinatedURL)
                            matching = sized.first(where: { $0.fingerprint == fingerprint })
                        } catch { readError = error }
                    }
                    if let coordinationError { throw coordinationError }
                    if let readError { throw readError }
                    guard let item = matching else { skipped += 1; continue }
                    try verifyLibraryCopy(item)
                    candidates.append(OriginalCleanupCandidate(id: UUID(), name: url.lastPathComponent,
                                                               bytes: item.originalBytes, fileURL: url, libraryID: item.id))
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
        }
        let plan = OriginalCleanupPlan(id: UUID(), candidates: candidates, skippedCount: skipped,
                                       issues: issues, selections: selections)
        cleanupPlan = plan
        return plan
    }

    public func deleteOriginals(planID: UUID, progress: @Sendable (String) -> Void = { _ in }) throws -> OriginalCleanupResult {
        guard let plan = cleanupPlan, plan.id == planID else { throw LibraryError.cleanupExpired }
        cleanupPlan = nil
        let scopes = plan.selections.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        var result = OriginalCleanupResult()
        for (index, candidate) in plan.candidates.enumerated() {
            if Task.isCancelled { result.cancelled = true; break }
            progress("Removing original \(index + 1)/\(plan.candidates.count)")
            do {
                guard let item = items.first(where: { $0.id == candidate.libraryID }) else { throw LibraryError.missingFile }
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var deletionError: Error?
                coordinator.coordinate(readingItemAt: directory.appendingPathComponent(item.relativePath), options: [],
                                       writingItemAt: candidate.fileURL, options: .forDeleting, error: &coordinationError) { copy, url in
                    do {
                        try verifyLibraryCopy(item, at: copy)
                        // Recheck under coordination: Files may have replaced the original after the preview.
                        guard !isLibraryFile(url), try Self.regularFile(url),
                              try Self.bytes(url) == item.originalBytes,
                              try Self.fingerprint(url) == item.fingerprint else { throw LibraryError.originalChanged }
                        try Task.checkCancellation()
                        try fileManager.removeItem(at: url)
                    } catch { deletionError = error }
                }
                if let coordinationError { throw coordinationError }
                if let deletionError { throw deletionError }
                result.deleted.append(candidate.name)
                result.deletedBytes += candidate.bytes
            } catch is CancellationError { result.cancelled = true; break }
            catch { result.issues.append(candidate.name + ": " + error.localizedDescription) }
        }
        result.completedAt = Date()
        let receipt = catalogURL.deletingLastPathComponent().appendingPathComponent("last-original-cleanup.json")
        do { try JSONEncoder().encode(result).write(to: receipt, options: .atomic) }
        catch { result.issues.append("Could not save the cleanup record: " + error.localizedDescription) }
        return result
    }

    private func verifyLibraryCopy(_ item: LibraryItem, at url: URL? = nil) throws {
        let url = url ?? directory.appendingPathComponent(item.relativePath)
        guard let fingerprint = item.storedFingerprint, try Self.regularFile(url),
              try Self.bytes(url) == item.storedBytes,
              try Self.fingerprint(url) == fingerprint else { throw LibraryError.copyNotVerified }
    }

    private func isLibraryFile(_ url: URL) -> Bool {
        let root = Self.canonicalPath(directory)
        let path = Self.canonicalPath(url)
        return path == root || path.hasPrefix(root + "/")
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func regularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    @discardableResult
    public func cleanImportedNames() throws -> Int {
        let pending = items.filter { LibraryNaming.containsExportArtifacts(title: $0.title, artist: $0.artist) }
        var count = 0
        for item in pending {
            let names = LibraryNaming.infer(from: item.originalName)
            var title = names.title
            var variant = 2
            while items.contains(where: { $0.id != item.id && $0.kind == item.kind
                && $0.artist == names.artist && $0.title == title }) {
                title = String(names.title.prefix(94)) + " (\(variant))"
                variant += 1
            }
            if title != item.title || names.artist != item.artist {
                _ = try rename(item.id, title: title, artist: names.artist)
                count += 1
            }
        }
        return count
    }

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

    static func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            // Foundation retains read buffers until its pool drains, which can span the whole scan.
            let hasBytes = try autoreleasepool {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !hasBytes { break }
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
    case invalidCatalog, missingFile, emptyTitle, cleanupExpired, originalChanged, copyNotVerified
    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The library index contains an invalid path. Its files have been preserved."
        case .missingFile: "This file is no longer in the library folder. Import it again from Files."
        case .emptyTitle: "Enter a title for this track."
        case .cleanupExpired: "Choose the original files again before deleting them."
        case .originalChanged: "The original no longer matches its import record. It was kept."
        case .copyNotVerified: "The library copy could not be verified. The original was kept."
        }
    }
}
