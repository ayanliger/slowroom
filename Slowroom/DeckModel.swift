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

    private let mediaDirectory: URL
    private let sessionFile: URL
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<URL, Error>?
    private var loadID = UUID()
    private var remoteTargets: [Any] = []

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        mediaDirectory = caches.appendingPathComponent("SlowroomMedia")
        sessionFile = caches.appendingPathComponent("slowroom-session.json")
        if let data = UserDefaults.standard.data(forKey: "effects"),
           let effects = try? JSONDecoder().decode(EffectSettings.self, from: data) {
            player.update(effects)
        }
        configureRemoteControls()
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            loadDemo()
        } else if !ProcessInfo.processInfo.arguments.contains("--uitesting"),
                  let data = try? Data(contentsOf: sessionFile),
                  let track = try? JSONDecoder().decode(AudioTrack.self, from: data),
                  track.fileURL.deletingLastPathComponent() == mediaDirectory,
                  FileManager.default.fileExists(atPath: track.fileURL.path) {
            try? player.load(track)
        }
    }

    var busy: Bool { loadStage != nil || exportProgress != nil || spotify.isSigningIn }

    func change(_ keyPath: WritableKeyPath<EffectSettings, Float>, to value: Float) {
        var settings = player.settings
        settings[keyPath: keyPath] = value
        apply(settings)
    }

    func apply(_ settings: EffectSettings) {
        player.update(settings)
        if let data = try? JSONEncoder().encode(player.settings) { UserDefaults.standard.set(data, forKey: "effects") }
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

    func saveMix() {
        guard let track = player.track, exportProgress == nil else { return }
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
        Task { [weak self] in
            guard let self, let task = self.renderTask else { return }
            do {
                let url = try await task.value
                self.exportProgress = nil
                self.exportURL = url
                self.showExport = true
            } catch {
                self.exportProgress = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            self.renderTask = nil
        }
    }

    func cancelExport() { renderTask?.cancel() }

    func clearTrack() {
        player.clear()
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
    }

    private func removeOldMedia(keeping: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file != keeping { try? FileManager.default.removeItem(at: file) }
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
