import AVFoundation
import MediaPlayer
import Observation
import SlowroomCore
import SwiftUI

@MainActor
@Observable
final class DeckModel {
    let player = AudioPlayer()
    let spotify = SpotifyAccount()
    var sourceText = ""
    var loadStage: String?
    var error: String?
    var showSource = false
    var showSpotifyAccount = false
    var exportProgress: Double?
    var exportURL: URL?
    var showExport = false
    var selectedTab = 0
    var libraryItems: [SlowroomCore.LibraryItem] = []
    var libraryStage: String?
    var libraryReport: LibraryImportReport?
    var showLibraryImport = false
    var currentLibraryID: UUID?
    var libraryNotice: String?
    var showOriginalCleanup = false
    var cleanupPlan: OriginalCleanupPlan?
    var cleanupResult: OriginalCleanupResult?
    var cleanupStage: String?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupOperationID = UUID()
    let libraryDirectory: URL
    private var library: AudioLibrary?
    private var libraryTask: Task<Void, Never>?
    private var libraryOperationID = UUID()
    private var queue: [UUID] = []

    private let mediaDirectory: URL
    private let sessionFile: URL
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<URL, Error>?
    private var finishExportTask: Task<Void, Never>?
    private var loadID = UUID()
    private var remoteTargets: [Any] = []
    private var effectsKey: String {
        ProcessInfo.processInfo.arguments.contains("--uitesting") ? "testEffects" : "effects"
    }

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let workspace = testing ? caches.appendingPathComponent("SlowroomUITests") : caches
        mediaDirectory = workspace.appendingPathComponent("SlowroomMedia")
        sessionFile = workspace.appendingPathComponent("slowroom-session.json")
        let documents = testing ? caches.appendingPathComponent("LibraryUITests")
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-test-library") {
            try? FileManager.default.removeItem(at: documents)
        }
        #endif
        libraryDirectory = documents.appendingPathComponent("Slowroom Library")
        let support = testing ? documents : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do { library = try AudioLibrary(directory: libraryDirectory, catalogURL: support.appendingPathComponent("Slowroom/library.json")) }
        catch { self.error = error.localizedDescription }
        if let data = UserDefaults.standard.data(forKey: effectsKey),
           let effects = try? JSONDecoder().decode(EffectSettings.self, from: data) {
            player.update(effects)
        }
        configureRemoteControls()
        player.onPlaybackEnded = { [weak self] in self?.advanceQueue() }
        Task {
            do { try await library?.cleanImportedNames() }
            catch { self.error = error.localizedDescription }
            await refreshLibrary()
            if !testing, !ProcessInfo.processInfo.arguments.contains("--demo"),
               let saved = UserDefaults.standard.string(forKey: "lastLibraryTrack"),
               let item = libraryItems.first(where: { $0.id.uuidString == saved }) {
                do {
                    try player.load(item.audioTrack(in: libraryDirectory))
                    player.compareOriginal(true)
                    currentLibraryID = item.id
                    queue = [item.id]
                } catch { self.error = error.localizedDescription }
            }
        }
        #if DEBUG
        if testing && ProcessInfo.processInfo.arguments.contains("--seed-library") {
            seedTestLibrary()
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            loadDemo()
        } else if !ProcessInfo.processInfo.arguments.contains("--uitesting"),
                  let data = try? Data(contentsOf: sessionFile),
                  let track = try? JSONDecoder().decode(AudioTrack.self, from: data),
                  track.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                    == mediaDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
                  FileManager.default.fileExists(atPath: track.fileURL.path) {
            try? player.load(track)
        }
    }

    var busy: Bool { loadStage != nil || exportProgress != nil || libraryStage != nil || cleanupStage != nil || spotify.isSigningIn }

    func change(_ keyPath: WritableKeyPath<EffectSettings, Float>, to value: Float) {
        var settings = player.settings
        settings[keyPath: keyPath] = value
        apply(settings)
    }

    func apply(_ settings: EffectSettings) {
        player.update(settings)
        if let data = try? JSONEncoder().encode(player.settings) { UserDefaults.standard.set(data, forKey: effectsKey) }
        updateNowPlaying()
    }

    func togglePlayback() {
        if player.isPlaying { player.pause() }
        else {
            do { try player.play() }
            catch { self.error = error.localizedDescription }
        }
        updateNowPlaying()
    }

    func loadLink() {
        let link: SourceLink
        do { link = try SourceLink(sourceText) }
        catch { self.error = error.localizedDescription; return }
        if link.requiresSpotifyAccount && !spotify.isSignedIn {
            showSpotifyAccount = true
            error = "Sign in to Spotify below, then load your link."
            return
        }
        beginLoading { [mediaDirectory, spotify] stage in
            switch link {
            case .youtube(let id):
                return try await SourceService.loadYouTube(videoID: id, directory: mediaDirectory, stage: stage)
            case .spotify, .spotifyShort:
                let token = try await spotify.accessToken()
                stage("Reading Spotify track")
                let track = try await SourceService.spotifyTrack(from: link)
                return try await NativeSpotify.load(track: track, accessToken: token, directory: mediaDirectory, stage: stage)
            }
        }
    }

    func loadFile(_ url: URL) {
        beginLoading { [mediaDirectory] stage in
            stage("Reading your file")
            return try await MediaImporter.load(url, directory: mediaDirectory)
        }
    }

    func loadDemo() {
        beginLoading { [mediaDirectory] stage in
            stage("Preparing the synth demo")
            return try await Task.detached(priority: .userInitiated) { try DemoAudio.create(in: mediaDirectory) }.value
        }
    }

    private func beginLoading(_ operation: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> AudioTrack) {
        cancelLoading()
        error = nil
        loadStage = "Opening source"
        let id = loadID
        loadTask = Task { [weak self] in
            do {
                let track = try await operation { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.loadID == id else { return }
                        self.loadStage = message
                    }
                }
                guard let self, self.loadID == id, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: track.fileURL)
                    return
                }
                try self.player.load(track)
                self.player.compareOriginal(false)
                self.currentLibraryID = nil
                self.queue = []
                if !ProcessInfo.processInfo.arguments.contains("--uitesting") {
                    UserDefaults.standard.removeObject(forKey: "lastLibraryTrack")
                }
                self.loadID = UUID()
                self.loadTask = nil
                self.loadStage = nil
                self.showSource = false
                self.sourceText = ""
                if let data = try? JSONEncoder().encode(track) { try? data.write(to: self.sessionFile, options: .atomic) }
                self.removeOldMedia(keeping: track.fileURL)
                self.updateNowPlaying()
            } catch {
                guard let self, self.loadID == id else { return }
                self.loadID = UUID()
                self.loadTask = nil
                self.loadStage = nil
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancelLoading() {
        loadID = UUID()
        loadTask?.cancel()
        loadStage = nil
    }

    func saveMix(toLibrary: Bool = false) {
        guard let track = player.track, !busy else { return }
        let settings = player.settings
        let directory = mediaDirectory.deletingLastPathComponent().appendingPathComponent("SlowroomExports")
        let cleaned = track.title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((cleaned.isEmpty ? "Slowroom" : cleaned).prefix(80)) + " slowed.wav"
        let output = directory.appendingPathComponent(name)
        exportProgress = 0
        let model = self
        renderTask = Task.detached(priority: .userInitiated) { [model] in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for previous in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try? FileManager.default.removeItem(at: previous)
            }
            try AudioRenderer.render(input: track.fileURL, output: output, settings: settings) { fraction in
                Task { @MainActor in
                    guard model.exportProgress != nil else { return }
                    model.exportProgress = fraction
                }
            }
            return output
        }
        finishExportTask = Task { [weak self] in
            guard let self, let task = self.renderTask else { return }
            do {
                let url = try await task.value
                if toLibrary, let library = self.library {
                    self.libraryStage = "Adding your mix"
                    let title = track.title.localizedCaseInsensitiveContains("slowed") ? track.title : track.title + " (Slowed + Reverb)"
                    _ = try await library.importFile(url, kind: .mix, title: title, artist: track.author,
                                                     sourceURL: track.sourceURL, effects: settings)
                    await self.refreshLibrary()
                    self.libraryStage = nil
                    self.libraryNotice = "Mix saved to your library."
                    try? FileManager.default.removeItem(at: url)
                } else {
                    self.exportURL = url
                    self.showExport = true
                }
                self.exportProgress = nil
            } catch {
                self.exportProgress = nil
                self.libraryStage = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            self.renderTask = nil
            self.finishExportTask = nil
        }
    }

    func cancelExport() { renderTask?.cancel(); finishExportTask?.cancel() }

    func clearTrack() {
        player.clear()
        currentLibraryID = nil
        queue = []
        if !ProcessInfo.processInfo.arguments.contains("--uitesting") {
            UserDefaults.standard.removeObject(forKey: "lastLibraryTrack")
        }
        try? FileManager.default.removeItem(at: sessionFile)
        removeOldMedia(keeping: nil)
        updateNowPlaying()
    }

    func interruption(_ notification: Notification) {
        let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        if value == AVAudioSession.InterruptionType.began.rawValue { player.pause(); updateNowPlaying() }
    }

    func routeChanged(_ notification: Notification) {
        let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            player.recoverAfterAudioChange()
            updateNowPlaying()
        }
    }

    func updateNowPlaying() {
        guard let track = player.track else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.author,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? player.effectiveSpeed : 0
        ]
    }

    private func configureRemoteControls() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets.append(center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in try? self?.player.play(); self?.updateNowPlaying() }
            return .success
        })
        remoteTargets.append(center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause(); self?.updateNowPlaying() }
            return .success
        })
        remoteTargets.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.player.seek(to: time); self?.updateNowPlaying() }
            return .success
        })
        remoteTargets.append(center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.advanceQueue() }
            return .success
        })
        remoteTargets.append(center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousTrack() }
            return .success
        })
    }

    func refreshLibrary() async {
        libraryItems = await library?.allItems() ?? []
    }

    func importLibrary(_ urls: [URL], kind: LibraryKind, optimize: Bool) {
        guard let library, !busy else { return }
        libraryReport = nil
        libraryStage = "Reading selected files"
        libraryOperationID = UUID()
        let operationID = libraryOperationID
        showLibraryImport = false
        libraryTask = Task { [weak self] in
            let report = await library.importFiles(urls, kind: kind, optimize: optimize) { [weak self] message in
                Task { @MainActor in
                    guard let self, self.libraryOperationID == operationID, self.libraryStage != nil else { return }
                    self.libraryStage = message
                }
            }
            guard let self else { return }
            await self.refreshLibrary()
            self.libraryStage = nil
            self.libraryReport = report
            self.libraryTask = nil
        }
    }

    func cancelLibraryImport() { libraryTask?.cancel() }

    func findOriginals(_ urls: [URL]) {
        guard let library, !busy else { return }
        cleanupPlan = nil
        cleanupResult = nil
        error = nil
        cleanupStage = "Checking originals and library copies"
        cleanupOperationID = UUID()
        let id = cleanupOperationID
        cleanupTask = Task { [weak self] in
            do {
                let plan = try await library.findOriginals(urls) { [weak self] stage in
                    Task { @MainActor in
                        guard let self, self.cleanupOperationID == id, self.cleanupStage != nil else { return }
                        self.cleanupStage = stage
                    }
                }
                self?.cleanupPlan = plan
            } catch { if !(error is CancellationError) { self?.error = error.localizedDescription } }
            self?.cleanupStage = nil
            self?.cleanupTask = nil
        }
    }

    func deleteMatchedOriginals() {
        guard let library, let plan = cleanupPlan, !busy else { return }
        error = nil
        cleanupStage = "Verifying files before deletion"
        cleanupOperationID = UUID()
        let id = cleanupOperationID
        cleanupTask = Task { [weak self] in
            do {
                let result = try await library.deleteOriginals(planID: plan.id) { [weak self] stage in
                    Task { @MainActor in
                        guard let self, self.cleanupOperationID == id, self.cleanupStage != nil else { return }
                        self.cleanupStage = stage
                    }
                }
                self?.cleanupResult = result
                self?.cleanupPlan = nil
            } catch { self?.error = error.localizedDescription }
            self?.cleanupStage = nil
            self?.cleanupTask = nil
        }
    }

    func cancelOriginalCleanup() { cleanupTask?.cancel() }

    func keepCurrentSource() {
        guard let library, let track = player.track, !busy else { return }
        libraryStage = "Saving source"
        libraryTask = Task { [weak self] in
            do {
                _ = try await library.importFile(track.fileURL, kind: .source, title: track.title,
                                                 artist: track.author, sourceURL: track.sourceURL)
                await self?.refreshLibrary()
                self?.libraryNotice = "Source saved to your library."
            } catch { self?.error = error.localizedDescription }
            self?.libraryStage = nil
            self?.libraryTask = nil
        }
    }

    func playLibrary(_ item: SlowroomCore.LibraryItem, queue items: [SlowroomCore.LibraryItem]? = nil, edit: Bool = false) {
        guard !busy else { return }
        do {
            try player.load(item.audioTrack(in: libraryDirectory))
            player.compareOriginal(!edit)
            player.isLooping = false
            currentLibraryID = item.id
            if !ProcessInfo.processInfo.arguments.contains("--uitesting") {
                UserDefaults.standard.set(item.id.uuidString, forKey: "lastLibraryTrack")
            }
            queue = (items ?? [item]).map(\.id)
            if edit { selectedTab = 0 }
            else { try player.play() }
            updateNowPlaying()
        } catch { self.error = error.localizedDescription }
    }

    var hasNextTrack: Bool {
        guard let id = currentLibraryID, let index = queue.firstIndex(of: id) else { return false }
        return index + 1 < queue.count
    }

    func advanceQueue() {
        guard hasNextTrack, let id = currentLibraryID, let index = queue.firstIndex(of: id),
              let next = libraryItems.first(where: { $0.id == queue[index + 1] }) else { updateNowPlaying(); return }
        let ordered = queue.compactMap { id in libraryItems.first { $0.id == id } }
        playLibrary(next, queue: ordered)
    }

    func previousTrack() {
        guard player.position < 3, let id = currentLibraryID, let index = queue.firstIndex(of: id), index > 0,
              let previous = libraryItems.first(where: { $0.id == queue[index - 1] }) else {
            player.seek(to: 0); updateNowPlaying(); return
        }
        let ordered = queue.compactMap { id in libraryItems.first { $0.id == id } }
        playLibrary(previous, queue: ordered)
    }

    func renameLibrary(_ item: SlowroomCore.LibraryItem, title: String, artist: String) async -> Bool {
        guard let library, !busy else { return false }
        let active = currentLibraryID == item.id
        let resume = active && player.isPlaying
        let position = player.position
        let original = player.isOriginal
        if active { player.pause() }
        do {
            let updated = try await library.rename(item.id, title: title, artist: artist)
            await refreshLibrary()
            if active {
                try player.load(updated.audioTrack(in: libraryDirectory))
                player.compareOriginal(original)
                player.seek(to: position)
                if resume { try player.play() }
                updateNowPlaying()
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    #if DEBUG
    private func seedTestLibrary() {
        guard let library else { return }
        libraryStage = "Preparing test library"
        Task {
            do {
                let folder = libraryDirectory.deletingLastPathComponent().appendingPathComponent("fixtures")
                let demo = try await Task.detached { try DemoAudio.create(in: folder) }.value
                let mix = folder.appendingPathComponent("mix.wav")
                try await Task.detached {
                    try AudioRenderer.render(input: demo.fileURL, output: mix, settings: EffectSettings())
                }.value
                if ProcessInfo.processInfo.arguments.contains("--large-cleanup-fixtures") {
                    try await Task.detached {
                        try Self.padTestAudio(mix)
                    }.value
                }
                _ = try await library.importFile(demo.fileURL, kind: .source, title: demo.title, artist: "Slowroom")
                _ = try await library.importFile(mix, kind: .mix, title: "Evening study (Slowed + Reverb)", artist: "Slowroom")
                await refreshLibrary()
            } catch { self.error = error.localizedDescription }
            libraryStage = nil
        }
    }

    private nonisolated static func padTestAudio(_ url: URL) throws {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("RIFF".utf8) else { throw AudioError.unsupportedFormat }
        let end = try file.seekToEnd()
        // A sparse JUNK chunk exercises multi-gigabyte scans without hours of test audio.
        let padding: UInt32 = 3_584 * 1_024 * 1_024
        var chunkSize = padding.littleEndian
        try file.write(contentsOf: Data("JUNK".utf8))
        try withUnsafeBytes(of: &chunkSize) { try file.write(contentsOf: Data($0)) }
        try file.truncate(atOffset: end + 8 + UInt64(padding))
        try file.seek(toOffset: 4)
        var riffSize = UInt32(end + UInt64(padding)).littleEndian
        try withUnsafeBytes(of: &riffSize) { try file.write(contentsOf: Data($0)) }
    }
    #endif

    private func removeOldMedia(keeping: URL?) {
        MediaCache.removeOldFiles(in: mediaDirectory, keeping: keeping)
    }
}

private extension SourceLink {
    var requiresSpotifyAccount: Bool {
        switch self {
        case .spotify, .spotifyShort: true
        case .youtube: false
        }
    }
}
