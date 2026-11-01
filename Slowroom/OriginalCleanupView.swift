import SlowroomCore
import SwiftUI
import UniformTypeIdentifiers

struct OriginalCleanupView: View {
    @Bindable var model: DeckModel
    @State private var showFolder = false
    @State private var showFiles = false

    var body: some View {
        NavigationStack {
            Form {
                if let result = model.cleanupResult {
                    Section {
                        Text("\(result.deleted.count) originals deleted").font(.title2.weight(.medium))
                            .accessibilityIdentifier("cleanupResultCount")
                        LabeledContent("Original data removed", value: LibraryView.size(result.deletedBytes))
                        Text("Your Slowroom library copies are still available.")
                        if result.cancelled { Text("Stopped before all originals were removed.") }
                    }
                    if !result.issues.isEmpty { issues(result.issues) }
                } else if let plan = model.cleanupPlan {
                    Section {
                        Text("\(plan.candidates.count) matched originals").font(.title2.weight(.medium))
                            .accessibilityIdentifier("cleanupMatchedCount")
                        LabeledContent("Original file size", value: LibraryView.size(plan.bytes))
                        Text("Each original matches an import record and has a verified copy in your library.")
                        if plan.skippedCount > 0 { Text("\(plan.skippedCount) other files will be kept.").foregroundStyle(.secondary) }
                    }
                    if !plan.candidates.isEmpty {
                        Section {
                            Button("Delete matched originals", role: .destructive) { model.deleteMatchedOriginals() }
                                .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("deleteMatchedOriginals")
                        } footer: { Text("Deletes these files from the selected location. Deletion may be permanent. Your library copies remain.") }
                        Section {
                            DisclosureGroup("Review matched files") {
                                ForEach(plan.candidates) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name)
                                        Text(LibraryView.size(item.bytes)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !plan.issues.isEmpty { issues(plan.issues) }
                } else {
                    Section {
                        Text("Choose the folder or files you imported. Slowroom will find originals that have verified library copies.")
                        Text("Nothing is deleted during this check.").foregroundStyle(.secondary)
                    }
                }
                if let stage = model.cleanupStage {
                    Section {
                        HStack { ProgressView(); Text(stage).font(.subheadline) }
                        Button("Cancel") { model.cancelOriginalCleanup() }.frame(minHeight: 44)
                    }
                } else {
                    Section {
                        Button("Choose original folder", systemImage: "folder") { showFolder = true }
                            .frame(minHeight: 44).accessibilityIdentifier("chooseOriginalFolder")
                        Button("Choose original files", systemImage: "doc.on.doc") { showFiles = true }
                            .frame(minHeight: 44)
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--uitesting")
                            && ProcessInfo.processInfo.arguments.contains("--seed-library") {
                            Button("Use test originals") {
                                model.findOriginals([model.libraryDirectory.deletingLastPathComponent().appendingPathComponent("fixtures")])
                            }.accessibilityIdentifier("findTestOriginals")
                        }
                        #endif
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Delete originals").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showOriginalCleanup = false }.disabled(model.cleanupStage != nil)
                }
            }
            .interactiveDismissDisabled(model.cleanupStage != nil)
            .fileImporter(isPresented: $showFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { receive($0) }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { receive($0) }
        }
    }

    private func issues(_ messages: [String]) -> some View {
        Section("Kept or could not check") {
            ForEach(Array(messages.enumerated()), id: \.offset) { Text($0.element).font(.subheadline) }
        }
    }

    private func receive(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): model.findOriginals(urls)
        case .failure(let error): model.error = error.localizedDescription
        }
    }
}
