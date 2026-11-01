import AVFoundation
import SlowroomCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum DeckTheme {
    static let background = Color(red: 0.074, green: 0.086, blue: 0.082)
    static let surface = Color(red: 0.12, green: 0.14, blue: 0.13)
    static let line = Color(red: 0.28, green: 0.31, blue: 0.29)
    static let text = Color(red: 0.94, green: 0.93, blue: 0.88)
    static let secondary = Color(red: 0.70, green: 0.74, blue: 0.70)
    static let amber = Color(red: 0.91, green: 0.65, blue: 0.37)
}

struct DeckView: View {
    @Bindable var model: DeckModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                sourceDisplay
                comparison
                effects
                output
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(DeckTheme.background)
        .foregroundStyle(DeckTheme.text)
        .safeAreaInset(edge: .bottom, spacing: 0) { transport }
        .sheet(isPresented: $model.showSource) { SourceSheet(model: model) }
        .sheet(isPresented: $model.showExport) {
            if let url = model.exportURL { SaveAudioView(url: url) }
        }
        .alert("Could not complete the action", isPresented: Binding(
            get: { model.error != nil && !model.showSource },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { model.interruption($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { model.routeChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
            model.player.recoverAfterAudioChange()
        }
        .onChange(of: model.player.isPlaying) { model.updateNowPlaying() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SLOWROOM").font(.system(.title2, design: .monospaced).weight(.medium)).tracking(2)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("SLOWED + REVERB").font(.system(.caption2, design: .monospaced)).tracking(2).foregroundStyle(DeckTheme.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Load a link", systemImage: "link") { model.showSource = true }
                Button("Spotify account", systemImage: "person.crop.circle") {
                    model.showSpotifyAccount = true
                    model.showSource = true
                }
                Button("Save slowed WAV", systemImage: "square.and.arrow.down") { model.saveMix() }
                    .disabled(model.player.track == nil || model.busy)
                Button("Clear track", systemImage: "xmark", role: .destructive) { model.clearTrack() }
                    .disabled(model.player.track == nil || model.busy)
            } label: {
                Image(systemName: "ellipsis").font(.title3).frame(width: 44, height: 44)
                    .background(DeckTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Track options")
            .accessibilityIdentifier("trackOptions")
        }
    }

    private var sourceDisplay: some View {
        VStack(alignment: .leading, spacing: 16) {
            adaptiveRow {
                Label(sourceName, systemImage: "waveform")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(DeckTheme.secondary)
                if !typeSize.isAccessibilitySize { Spacer() }
                Text(model.player.isPlaying ? "PLAYING" : "READY")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(model.player.isPlaying ? DeckTheme.amber : DeckTheme.secondary)
                    .accessibilityIdentifier("playbackStatus")
            }
            if let track = model.player.track {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title).font(.title2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trackTitle")
                    if !track.author.isEmpty {
                        Text(track.author).font(.subheadline).foregroundStyle(DeckTheme.secondary)
                    }
                }
                WaveformView(peaks: track.waveform, fraction: currentPosition / max(1, track.duration))
                    .frame(height: 54).accessibilityHidden(true)
                VStack(spacing: 2) {
                    Slider(value: Binding(
                        get: { currentPosition },
                        set: { scrubPosition = $0 }
                    ), in: 0...max(1, track.duration), onEditingChanged: { editing in
                        if editing { scrubPosition = model.player.position }
                        else { model.player.seek(to: scrubPosition); model.updateNowPlaying() }
                        scrubbing = editing
                    }) { Text("Track position") }
                    .accessibilityIdentifier("seekSlider")
                    HStack {
                        Text(Self.time(currentPosition)).accessibilityIdentifier("currentPosition")
                        Spacer()
                        Text(Self.time(track.duration))
                    }
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(DeckTheme.secondary)
                }
                adaptiveRow {
                    if let source = track.sourceURL {
                        Link("Open source", destination: source).font(.caption).underline().frame(minHeight: 44)
                    } else {
                        Text("ON YOUR IPHONE").font(.system(.caption2, design: .monospaced))
                    }
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button("Replace", systemImage: "arrow.triangle.2.circlepath") { model.showSource = true }
                        .font(.subheadline).frame(minHeight: 44)
                        .disabled(model.busy)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Give it some space.").font(.title2.weight(.medium))
                    Text("Load a song, press play and shape the sound as you listen.")
                        .font(.body).foregroundStyle(DeckTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button { model.showSource = true } label: {
                    Label("Load a link", systemImage: "link").frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(.borderedProminent).foregroundStyle(DeckTheme.background)
                Button("Try the synth demo") { model.loadDemo() }
                    .font(.subheadline).frame(minHeight: 44).disabled(model.busy)
                    .accessibilityIdentifier("loadDemo")
            }
            if let stage = model.loadStage, !model.showSource {
                HStack { ProgressView(); Text(stage).font(.subheadline) }
            }
        }
        .padding(20)
        .background(DeckTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeckTheme.line, lineWidth: 1))
    }

    private var comparison: some View {
        Picker("Listen to", selection: Binding(
            get: { model.player.isOriginal },
            set: { model.player.compareOriginal($0); model.updateNowPlaying() }
        )) {
            Text("Original").tag(true)
            Text("Slowed + reverb").tag(false)
        }
        .pickerStyle(.segmented)
        .disabled(model.player.track == nil)
        .accessibilityIdentifier("comparisonPicker")
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: 22) {
            adaptiveRow {
                Text("PRESET").font(.system(.caption2, design: .monospaced)).foregroundStyle(DeckTheme.secondary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 2) }
                ForEach(EffectSettings.presets, id: \.name) { preset in
                    Button(preset.name) { model.apply(preset.settings) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(model.player.settings == preset.settings ? DeckTheme.background : DeckTheme.text)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                        .background(model.player.settings == preset.settings ? DeckTheme.amber : DeckTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("preset\(preset.name)")
                }
            }
            EffectSlider(
                title: "Speed", valueText: String(format: "%.2f", model.player.settings.speed) + "×",
                value: effect(\.speed), range: 0.5...1.25, step: 0.01,
                minimum: "0.50×", maximum: "1.25×", identifier: "speedSlider"
            )
            Toggle(isOn: Binding(
                get: { model.player.settings.preservePitch },
                set: { var settings = model.player.settings; settings.preservePitch = $0; model.apply(settings) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep original pitch").font(.subheadline)
                    Text(model.player.settings.preservePitch ? "Speed changes tempo only." : "Speed also lowers the pitch.")
                        .font(.caption).foregroundStyle(DeckTheme.secondary)
                }
            }
            .accessibilityIdentifier("preservePitchToggle")
            Divider().overlay(DeckTheme.line)
            EffectSlider(
                title: "Pitch offset", valueText: String(format: "%+.1f", model.player.settings.pitch) + " st",
                value: effect(\.pitch), range: -12...12, step: 0.5,
                minimum: "-12 st", maximum: "+12 st", identifier: "pitchSlider"
            )
            HStack {
                Text("Total pitch shift").font(.caption).foregroundStyle(DeckTheme.secondary)
                Spacer()
                Text(String(format: "%+.1f st", model.player.settings.totalPitch)).font(.system(.caption, design: .monospaced))
            }
            Divider().overlay(DeckTheme.line)
            EffectSlider(
                title: "Reverb", valueText: String(format: "%.0f%%", model.player.settings.reverb),
                value: effect(\.reverb), range: 0...80, step: 1,
                minimum: "DRY", maximum: "WET", identifier: "reverbSlider"
            )
            HStack {
                Text("Space").font(.subheadline)
                Spacer()
                Picker("Reverb space", selection: Binding(
                    get: { model.player.settings.room },
                    set: { var settings = model.player.settings; settings.room = $0; model.apply(settings) }
                )) {
                    ForEach(ReverbRoom.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(minHeight: 44)
            }
            if model.player.isOriginal {
                Label("Original is playing. Switch back to hear your settings.", systemImage: "ear")
                    .font(.caption).foregroundStyle(DeckTheme.amber)
            }
        }
    }

    private var output: some View {
        VStack(spacing: 18) {
            Divider().overlay(DeckTheme.line)
            EffectSlider(
                title: "Output", valueText: String(format: "%.0f%%", model.player.settings.volume * 100),
                value: effect(\.volume), range: 0...1, step: 0.01,
                minimum: "0", maximum: "100", identifier: "volumeSlider"
            )
            if let progress = model.exportProgress {
                VStack(spacing: 12) {
                    ProgressView("Rendering your mix", value: progress).font(.subheadline)
                    Button("Cancel render") { model.cancelExport() }.frame(minHeight: 44)
                }
            } else {
                Button { model.saveMix() } label: {
                    Label("Save slowed WAV", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).disabled(model.player.track == nil || model.busy)
                    .accessibilityIdentifier("exportButton")
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { model.player.seek(to: max(0, model.player.position - 10)); model.updateNowPlaying() } label: {
                Image(systemName: "gobackward.10").font(.title2).frame(width: 48, height: 48)
            }.accessibilityLabel("Back ten seconds")
            Button { model.togglePlayback() } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2).frame(maxWidth: 170, minHeight: 58)
                    .foregroundStyle(DeckTheme.background)
                    .background(DeckTheme.amber, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("playPauseButton")
            Button { model.player.isLooping.toggle() } label: {
                Image(systemName: model.player.isLooping ? "repeat.circle.fill" : "repeat")
                    .font(.title2).frame(width: 48, height: 48)
                    .foregroundStyle(model.player.isLooping ? DeckTheme.amber : DeckTheme.text)
            }
            .accessibilityLabel("Loop track")
            .accessibilityValue(model.player.isLooping ? "On" : "Off")
        }
        .disabled(model.player.track == nil)
        .padding(.horizontal, 28).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(DeckTheme.background)
        .overlay(alignment: .top) { Rectangle().fill(DeckTheme.line).frame(height: 1) }
    }

    private var sourceName: String {
        guard let track = model.player.track else { return "NO SOURCE" }
        if track.sourceURL?.host == "open.spotify.com" { return "SPOTIFY" }
        if track.sourceURL != nil { return "YOUTUBE" }
        return track.author == "Built-in synth demo" ? "SYNTH DEMO" : "LOCAL FILE"
    }

    private var currentPosition: Double { scrubbing ? scrubPosition : model.player.position }

    private var adaptiveRow: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    }

    private func effect(_ keyPath: WritableKeyPath<EffectSettings, Float>) -> Binding<Double> {
        Binding(get: { Double(model.player.settings[keyPath: keyPath]) }, set: { model.change(keyPath, to: Float($0)) })
    }

    static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct EffectSlider: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minimum: String
    let maximum: String
    let identifier: String

    var body: some View {
        VStack(spacing: 4) {
            valueLayout {
                Text(title).font(.body.weight(.medium))
                if !typeSize.isAccessibilitySize { Spacer(minLength: 10) }
                Text(valueText).font(.system(.title2, design: .monospaced).weight(.medium))
                    .foregroundStyle(DeckTheme.amber).monospacedDigit()
                    .accessibilityIdentifier(identifier + "Value")
            }
            Slider(value: $value, in: range, step: step) { Text(title) }
                .frame(minHeight: 44)
                .accessibilityValue(valueText)
                .accessibilityIdentifier(identifier)
            HStack { Text(minimum); Spacer(); Text(maximum) }
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(DeckTheme.secondary)
                .accessibilityHidden(true)
        }
    }

    private var valueLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }
}

private struct WaveformView: View {
    let peaks: [Float]
    let fraction: Double

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let width = size.width / Double(peaks.count)
            for (index, peak) in peaks.enumerated() {
                let height = max(2, size.height * Double(peak))
                let rect = CGRect(x: Double(index) * width, y: (size.height - height) / 2,
                                  width: max(1, width * 0.6), height: height)
                let played = Double(index) / Double(peaks.count) < fraction
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(played ? DeckTheme.amber : DeckTheme.secondary.opacity(0.55)))
            }
        }
    }
}

private struct SourceSheet: View {
    @Bindable var model: DeckModel
    @State private var showFiles = false
    @FocusState private var editingURL: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Spotify or YouTube link").font(.headline)
                        TextField("https://", text: $model.sourceText, axis: .vertical)
                            .lineLimit(2...4).keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().textContentType(.URL)
                            .focused($editingURL)
                            .padding(14).background(DeckTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("sourceURLField")
                        HStack {
                            PasteButton(payloadType: String.self) { values in
                                if let value = values.first { model.sourceText = value }
                            }
                            Spacer()
                            Button("Load source") { editingURL = false; model.loadLink() }
                                .buttonStyle(.borderedProminent).foregroundStyle(DeckTheme.background)
                                .frame(minHeight: 44).disabled(model.sourceText.isEmpty || model.busy)
                                .accessibilityIdentifier("loadSourceButton")
                        }
                        Text("Spotify and YouTube audio load directly onto this iPhone.")
                            .font(.subheadline).foregroundStyle(DeckTheme.secondary)
                        if let error = model.error {
                            Text(error).font(.subheadline).foregroundStyle(.red)
                                .accessibilityIdentifier("sourceError")
                        }
                        if let stage = model.loadStage {
                            HStack { ProgressView(); Text(stage).font(.subheadline) }
                            Button("Cancel loading") { model.cancelLoading() }.frame(minHeight: 44)
                        }
                    }
                    Divider().overlay(DeckTheme.line)
                    DisclosureGroup("Spotify account", isExpanded: $model.showSpotifyAccount) {
                        VStack(alignment: .leading, spacing: 14) {
                            if model.spotify.isSignedIn {
                                Label("Signed in on this iPhone", systemImage: "checkmark.circle")
                                    .font(.subheadline)
                                if model.spotify.playbackReady {
                                    Text("Spotify audio connection ready").font(.subheadline)
                                        .accessibilityIdentifier("spotifyConnectionReady")
                                }
                                Button("Check audio connection") { model.spotify.checkConnection() }
                                    .frame(minHeight: 44).disabled(model.busy)
                                    .accessibilityIdentifier("spotifyConnectionButton")
                                Button("Sign out", role: .destructive) { model.spotify.signOut() }
                                    .frame(minHeight: 44).disabled(model.busy)
                            } else {
                                Text("Use your Premium account to load the original Spotify recording.")
                                    .font(.subheadline).foregroundStyle(DeckTheme.secondary)
                                Text("Spotify may label this connection 'Spotify for Desktop'.")
                                    .font(.caption).foregroundStyle(DeckTheme.secondary)
                                Button("Sign in to Spotify") { model.spotify.signIn() }
                                    .buttonStyle(.borderedProminent).foregroundStyle(DeckTheme.background)
                                    .frame(minHeight: 44).disabled(model.spotify.isSigningIn)
                                    .accessibilityIdentifier("spotifySignInButton")
                            }
                            if let stage = model.spotify.stage {
                                HStack { ProgressView(); Text(stage).font(.subheadline) }
                                Button("Cancel sign-in") { model.spotify.cancelSignIn() }.frame(minHeight: 44)
                            }
                            if let error = model.spotify.error {
                                Text(error).font(.subheadline).foregroundStyle(.red)
                                    .accessibilityIdentifier("spotifySignInError")
                            }
                        }.padding(.top, 16)
                    }
                    Divider().overlay(DeckTheme.line)
                    Button("Import an audio or video file", systemImage: "folder") { showFiles = true }
                        .frame(minHeight: 44).disabled(model.busy)
                    Button("Try the synth demo", systemImage: "waveform") { model.loadDemo() }
                        .frame(minHeight: 44).disabled(model.busy)
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DeckTheme.background).foregroundStyle(DeckTheme.text)
            .navigationTitle("Load a track").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { model.cancelLoading(); model.error = nil; model.showSource = false }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio, .movie]) { result in
                switch result {
                case .success(let url): model.loadFile(url)
                case .failure(let error): model.error = error.localizedDescription
                }
            }
        }
    }
}

private struct SaveAudioView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
