import AVFoundation
import SlowroomCore
import SwiftUI
import UniformTypeIdentifiers

struct SlowroomRootView: View {
    @Bindable var model: DeckModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            DeckView(model: model)
                .tabItem { Label("Deck", systemImage: "slider.horizontal.3") }.tag(0)
            LibraryView(model: model)
                .tabItem { Label("Library", systemImage: "music.note.list") }.tag(1)
        }
        .sheet(isPresented: $model.showSource) { SourceSheet(model: model) }
        .sheet(isPresented: $model.showExport) {
            if let url = model.exportURL { SaveAudioView(url: url) }
        }
        .sheet(isPresented: $model.showLibraryImport) { LibraryImportView(model: model) }
        .sheet(isPresented: $model.showOriginalCleanup) { OriginalCleanupView(model: model) }
        .sheet(isPresented: Binding(get: { model.libraryReport != nil }, set: { if !$0 { model.libraryReport = nil } })) {
            if let report = model.libraryReport { ImportReportView(report: report) { model.libraryReport = nil } }
        }
        .alert("Could not complete the action", isPresented: Binding(
            get: { model.error != nil && !model.showSource && !model.showLibraryImport && !model.showOriginalCleanup },
            set: { if !$0 { model.error = nil } }
        )) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { model.interruption($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { model.routeChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
            model.player.recoverAfterAudioChange()
        }
        .onChange(of: model.player.isPlaying) { model.updateNowPlaying() }
    }
}

struct LibraryView: View {
    @Bindable var model: DeckModel
    @State private var search = ""
    @State private var collection: LibraryKind?
    @State private var sort = "Recently added"
    @State private var editing: SlowroomCore.LibraryItem?

    private var tracks: [SlowroomCore.LibraryItem] {
        model.libraryItems.filter {
            (collection == nil || $0.kind == collection) && (search.isEmpty
                || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search))
        }.sorted {
            if sort == "Title" { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if sort == "Largest files" { return $0.storedBytes > $1.storedBytes }
            return $0.addedAt > $1.addedAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(model.libraryItems.count) TRACKS · \(Self.size(model.libraryItems.reduce(0) { $0 + $1.storedBytes }))")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(DeckTheme.secondary)
                        Picker("Collection", selection: $collection) {
                            Text("All").tag(nil as LibraryKind?)
                            Text("Mixes").tag(LibraryKind.mix as LibraryKind?)
                            Text("Sources").tag(LibraryKind.source as LibraryKind?)
                        }.pickerStyle(.segmented)
                        if let stage = model.libraryStage {
                            HStack { ProgressView(); Text(stage).font(.subheadline) }
                            Button("Cancel import") { model.cancelLibraryImport() }
                        }
                        if let notice = model.libraryNotice {
                            Text(notice).font(.subheadline).foregroundStyle(DeckTheme.accent)
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(DeckTheme.background).listRowSeparator(.hidden)
                if tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.libraryItems.isEmpty ? "Your own listening room." : "No matching tracks.")
                            .font(.title2.weight(.medium))
                        Text("Import your saved mixes from Files. Tap a track to play it as saved, or open it in the deck to make a new version.")
                            .foregroundStyle(DeckTheme.secondary)
                        Button("Import from Files", systemImage: "folder.badge.plus") { model.showLibraryImport = true }
                            .buttonStyle(.borderedProminent).foregroundStyle(DeckTheme.background)
                            .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("importLibraryButton")
                    }.padding(.vertical, 20).listRowBackground(DeckTheme.background).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(tracks) { item in
                            HStack(spacing: 12) {
                                Button { model.playLibrary(item, queue: tracks) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: model.currentLibraryID == item.id && model.player.isPlaying ? "waveform" : "play.fill")
                                            .font(.body).foregroundStyle(DeckTheme.accent).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.title).font(.body.weight(.medium)).foregroundStyle(DeckTheme.text)
                                                .lineLimit(2)
                                            Text(item.artist.isEmpty ? item.kind.rawValue : item.artist)
                                                .font(.subheadline).foregroundStyle(DeckTheme.secondary).lineLimit(1)
                                            Text("\(DeckView.time(item.duration)) · \(Self.size(item.storedBytes)) · \(URL(fileURLWithPath: item.relativePath).pathExtension.uppercased())")
                                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(DeckTheme.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.busy)
                                    .accessibilityIdentifier("libraryTrack_" + item.title)
                                Menu {
                                    Button("Open in deck", systemImage: "slider.horizontal.3") { model.playLibrary(item, edit: true) }
                                    Button("Rename", systemImage: "pencil") { editing = item }
                                    ShareLink(item: model.libraryDirectory.appendingPathComponent(item.relativePath)) {
                                        Label("Share audio", systemImage: "square.and.arrow.up")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                                }.disabled(model.busy).accessibilityLabel("Options for " + item.title)
                            }.listRowBackground(DeckTheme.background).listRowSeparatorTint(DeckTheme.line)
                        }
                    } header: {
                        HStack {
                            Text(collection?.rawValue ?? "All tracks")
                            Spacer()
                            Menu {
                                Picker("Sort tracks", selection: $sort) {
                                    Text("Recently added").tag("Recently added")
                                    Text("Title").tag("Title")
                                    Text("Largest files").tag("Largest files")
                                }
                            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }.textCase(nil)
                        }
                    }
                }
                Section {
                    Text("Files > On My iPhone > Slowroom > Slowroom Library")
                        .font(.caption).foregroundStyle(DeckTheme.secondary)
                    Text("Import keeps originals in place. Library options can remove verified originals. Use Rename to correct track names.")
                        .font(.caption).foregroundStyle(DeckTheme.secondary)
                }.listRowBackground(DeckTheme.background).listRowSeparator(.hidden)
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(DeckTheme.background)
            .foregroundStyle(DeckTheme.text)
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Title or artist")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Delete imported originals", systemImage: "trash") {
                            model.error = nil
                            model.showOriginalCleanup = true
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .disabled(model.busy || model.libraryItems.isEmpty)
                        .accessibilityLabel("Library options").accessibilityIdentifier("libraryOptions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import", systemImage: "plus") { model.showLibraryImport = true }.disabled(model.busy)
                        .accessibilityIdentifier("libraryImportToolbar")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.player.track != nil { LibraryTransport(model: model) }
            }
            .sheet(item: $editing) { item in RenameTrackView(model: model, item: item) }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct LibraryTransport: View {
    @Bindable var model: DeckModel
    @State private var scrubbing = false
    @State private var position: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.player.track?.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                        .accessibilityIdentifier("libraryNowPlayingTitle")
                    Text(model.player.isOriginal ? "AS SAVED · 1.00×" : "DECK EFFECTS ON")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(DeckTheme.accent)
                        .accessibilityIdentifier("libraryPlaybackMode")
                }
                Spacer()
                Button("Deck") { model.selectedTab = 0 }.frame(minHeight: 44)
            }
            Slider(value: Binding(get: { scrubbing ? position : model.player.position }, set: { position = $0 }),
                   in: 0...max(1, model.player.duration), onEditingChanged: { editing in
                if editing { position = model.player.position }
                else { model.player.seek(to: position); model.updateNowPlaying() }
                scrubbing = editing
            }) { Text("Track position") }.accessibilityIdentifier("librarySeekSlider")
            HStack {
                Text(DeckView.time(model.player.position)).font(.system(.caption, design: .monospaced))
                    .accessibilityIdentifier("libraryPosition")
                Spacer()
                Button { model.previousTrack() } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous track")
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 58, height: 44).background(DeckTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(DeckTheme.background)
                }.accessibilityLabel(model.player.isPlaying ? "Pause" : "Play").accessibilityIdentifier("libraryPlayPause")
                Button { model.advanceQueue() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                    .disabled(!model.hasNextTrack).accessibilityLabel("Next track").accessibilityIdentifier("libraryNext")
                Spacer()
                Text(DeckView.time(model.player.duration)).font(.system(.caption, design: .monospaced))
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(DeckTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(DeckTheme.line).frame(height: 1) }
            .foregroundStyle(DeckTheme.text)
    }
}

private struct LibraryImportView: View {
    @Bindable var model: DeckModel
    @State private var kind: LibraryKind = .mix
    @State private var optimize = true
    @State private var showFiles = false
    @State private var showFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Save into") {
                    Picker("Collection", selection: $kind) {
                        ForEach(LibraryKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("Choose Slowed + Reverb for mixes you have already made. Every library track plays as saved.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Reduce lossless file sizes", isOn: $optimize)
                    Text("WAV, AIFF, FLAC and ALAC are converted to AAC in M4A: 256 kb/s for stereo, 128 kb/s for mono. Existing MP3 and AAC files keep their encoding. Audio is checked before the copy is added.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } footer: { Text("Your original files stay where they are. Conversion takes place on this iPhone.") }
                Section {
                    Button("Choose audio files", systemImage: "music.note") { showFiles = true }
                        .frame(minHeight: 44).accessibilityIdentifier("chooseLibraryFiles")
                    Button("Choose a folder", systemImage: "folder") { showFolder = true }
                        .frame(minHeight: 44).accessibilityIdentifier("chooseLibraryFolder")
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Import to library").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.showLibraryImport = false } } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
                receive(result)
            }
            .fileImporter(isPresented: $showFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                receive(result)
            }
        }
    }

    private func receive(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): model.importLibrary(urls, kind: kind, optimize: optimize)
        case .failure(let error): model.error = error.localizedDescription
        }
    }
}

private struct ImportReportView: View {
    let report: LibraryImportReport
    let close: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(report.added.count) tracks added").font(.title2.weight(.medium))
                    if !report.added.isEmpty {
                        LabeledContent("Original files", value: LibraryView.size(report.originalBytes))
                        LabeledContent("Library copies", value: LibraryView.size(report.storedBytes))
                        LabeledContent("Space saved in copies", value: LibraryView.size(max(0, report.originalBytes - report.storedBytes)))
                    }
                    if report.duplicates > 0 { Text("\(report.duplicates) duplicate files skipped.") }
                    if report.cancelled { Text("Import stopped. Completed tracks are available in the library.") }
                    Text("Original files have not been moved or deleted.").foregroundStyle(.secondary)
                }
                if !report.failures.isEmpty {
                    Section("Could not import") { ForEach(Array(report.failures.enumerated()), id: \.offset) { Text($0.element) } }
                }
                Section("Added files") {
                    ForEach(report.added) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(URL(fileURLWithPath: item.relativePath).lastPathComponent)
                            Text("\(LibraryView.size(item.originalBytes)) → \(LibraryView.size(item.storedBytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("Import complete").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
    }
}

private struct RenameTrackView: View {
    @Bindable var model: DeckModel
    let item: SlowroomCore.LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var saving = false

    init(model: DeckModel, item: SlowroomCore.LibraryItem) {
        self.model = model
        self.item = item
        _title = State(initialValue: item.title)
        _artist = State(initialValue: item.artist)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("renameTitle")
                TextField("Artist", text: $artist).accessibilityIdentifier("renameArtist")
                Text("Updates the library entry and its filename in Files.").foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Rename track").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saving = true
                            Task {
                                if await model.renameLibrary(item, title: title, artist: artist) { dismiss() }
                                saving = false
                            }
                        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    }
                }
        }
    }
}
