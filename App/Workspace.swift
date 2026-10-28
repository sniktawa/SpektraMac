import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

/// The window: Import › Edit › Export in the toolbar's middle, and the step's own view below.
struct WorkspaceView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            switch library.step {
            case .importing: LibraryView()
            case .edit: ContentView()
            case .export: ExportView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                StepPicker()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(item: Bindable(library).groupsSheet) { GroupsSheetView(purpose: $0) }
        // Here rather than in Edit, so pasting edits and presets in Import can be undone too.
        .onChange(of: undoManager, initial: true) { _, undoManager in
            library.photos.undoManager = undoManager
        }
        // Here rather than in Edit, so what fails in Import or Export says so too.
        .alert(library.photos.failure?.title ?? "",
               isPresented: Binding { library.photos.failure != nil } set: { if !$0 { library.photos.failure = nil } },
               presenting: library.photos.failure) { _ in
        } message: { failure in
            Text(failure.message)
        }
    }
}

/// Import › Edit › Export, as the original Spektrafilm app has it.
private struct StepPicker: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkflowStep.allCases) { step in
                if step != .importing {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    library.go(to: step)
                } label: {
                    Label(step.rawValue, systemImage: step.systemImage)
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 84)
                }
                .buttonStyle(.bordered)
                .tint(library.step == step ? .accentColor : nil)
                .disabled(step == .edit && library.items.isEmpty)
                .keyboardShortcut(KeyEquivalent(Character("\(WorkflowStep.allCases.firstIndex(of: step)! + 1)")),
                                  modifiers: [.command, .control])
                .help("\(step.rawValue) (⌃⌘\(WorkflowStep.allCases.firstIndex(of: step)! + 1))")
            }
        }
    }
}

// MARK: - Import: the project's photos

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var isDropTargeted = false
    /// The photo a ⇧-click selects the run from: the last one clicked.
    @State private var selectionAnchor: LibraryItem.ID?
    @AppStorage("exportScope") private var exportScope = ExportView.Scope.edited.rawValue

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            projectBar
            Divider()
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView {
                        Label("No photos in this project", systemImage: "photo.stack")
                    } description: {
                        Text("Import photos or whole folders of scans, or drop them here.")
                    } actions: {
                        Button("Import Photos…", systemImage: "plus") { library.presentImport() }
                    }
                } else {
                    grid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await library.importPhotos(urls) }
                return true
            } isTargeted: { isDropTargeted = $0 }
            Divider()
            statusBar
        }
        .navigationTitle(library.projectName)
        .navigationSubtitle("\(library.items.count) photos")
    }

    private var projectBar: some View {
        @Bindable var library = library
        return HStack(spacing: 8) {
            Text(library.projectName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .padding(.trailing, 6)
            Button("New", systemImage: "doc.badge.plus") { library.newProject() }
            Button("Open", systemImage: "folder") { library.openProject() }
            Button("Save", systemImage: "square.and.arrow.down") { library.saveProject() }
            Button("Import Photos", systemImage: "plus") { library.presentImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Spacer()
            Picker("Filter", selection: $library.filter) {
                ForEach(LibraryModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Picker("Sort", selection: $library.sort) {
                ForEach(LibraryModel.Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Slider(value: $library.thumbnailSize, in: 110...360)
                .frame(width: 110)
                .help("Thumbnail size")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var grid: some View {
        let shown = library.shownItems
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: library.thumbnailSize), spacing: 14)], spacing: 14) {
                ForEach(shown) { item in
                    ThumbnailCell(item: item, size: library.thumbnailSize,
                                  isSelected: library.selection.contains(item.id))
                        // One gesture, not a double tap and a single one: the single one would wait out
                        // the double-click time, by which ⌘ or ⇧ may be let go.
                        .onTapGesture {
                            let event = NSApp.currentEvent
                            if event?.clickCount == 2 {
                                library.edit(item)
                            } else {
                                select(item, in: shown, modifiers: event?.modifierFlags ?? [])
                            }
                        }
                        .contextMenu { menu(for: item) }
                }
            }
            .padding(14)
        }
        .background(.black.opacity(0.03))
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers == .command else { return .ignored }
            library.selection = Set(shown.map(\.id))
            return .handled
        }
        .onKeyPress(.return) {
            guard let item = shown.first(where: { library.selection.contains($0.id) }) else { return .ignored }
            library.edit(item)
            return .handled
        }
        .onDeleteCommand { library.remove(library.selection) }
    }

    /// Click selects one, ⌘-click adds or removes, ⇧-click selects the run from the last one clicked.
    private func select(_ item: LibraryItem, in shown: [LibraryItem], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if library.selection.contains(item.id) { library.selection.remove(item.id) } else { library.selection.insert(item.id) }
            selectionAnchor = item.id
        } else if modifiers.contains(.shift),
                  let anchor = shown.firstIndex(where: { $0.id == selectionAnchor })
                      ?? shown.firstIndex(where: { library.selection.contains($0.id) }),
                  let index = shown.firstIndex(of: item) {
            library.selection.formUnion(shown[min(anchor, index)...max(anchor, index)].map(\.id))
        } else {
            library.selection = [item.id]
            selectionAnchor = item.id
        }
    }

    @ViewBuilder private func menu(for item: LibraryItem) -> some View {
        let ids = library.selection.contains(item.id) ? library.selection : [item.id]
        Button("Edit") { library.edit(item) }
        Button("Export \(ids.count == 1 ? "Photo" : "\(ids.count) Photos")…") {
            library.selection = ids
            exportScope = ExportView.Scope.selected.rawValue
            library.go(to: .export)
        }
        Button("Select All") { library.selection = Set(library.shownItems.map(\.id)) }
        Button("Show in Finder") { library.showInFinder(ids) }
        Divider()
        Button("Copy Edits") { library.selection = ids; library.copyEdits() }
            .disabled(ids.count != 1)
        Button("Paste Edits") { library.selection = ids; library.pasteEdits() }
            .disabled(library.copiedEdits == nil)
        Menu("Apply Preset") {
            ForEach(library.presets.presets) { preset in
                Button(preset.name) { library.selection = ids; library.applyPreset(preset) }
            }
        }
        .disabled(library.presets.presets.isEmpty)
        Divider()
        Button("Reset Settings") { library.resetSettings(ids) }
            .disabled(!library.items.contains { ids.contains($0.id) && $0.isEdited })
        Button("Remove from Project", role: .destructive) { library.remove(ids) }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(library.shownItems.count) images").fontWeight(.medium)
            Text("\(library.selection.count) selected").foregroundStyle(.secondary)
            Spacer()
            if library.isImporting { ProgressView().controlSize(.small) }
            Text(library.status).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// A photo in the grid or the filmstrip: its thumbnail (the edit's look once edited), its name, and
/// a mark if it has settings of its own.
struct ThumbnailCell: View {
    @Environment(LibraryModel.self) private var library
    let item: LibraryItem
    let size: Double
    let isSelected: Bool
    var showsName = true

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                if let image = library.thumbnails[item.id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size, height: size * (showsName ? 0.8 : 0.72))
            .overlay(alignment: .topTrailing) {
                if item.isEdited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2.weight(.bold))
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(8)
                        .help("Has its own settings")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            if showsName {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .frame(width: size)
        .contentShape(Rectangle())
        .onAppear { library.loadThumbnail(for: item) }
    }
}

// MARK: - Edit: the filmstrip under the photo

struct Filmstrip: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        let shown = library.shownItems
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(shown) { item in
                        ThumbnailCell(item: item, size: 96, isSelected: item.id == library.currentID, showsName: false)
                            .id(item.id)
                            .onTapGesture { library.edit(item) }
                            .help(item.name)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: library.currentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 84)
        .background(.bar)
    }
}

// MARK: - Export: the edited photos, rendered

struct ExportView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PhotoModel.self) private var photos

    enum Scope: String, CaseIterable, Identifiable {
        case selected = "Selected Photos", edited = "Edited Photos", all = "All Photos"
        var id: Self { self }
    }

    enum Format: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", tiff = "TIFF (16-bit)", png = "PNG (16-bit)"
        var id: Self { self }
        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .tiff: .tiff
            case .png: .png
            }
        }
    }

    @AppStorage("exportScope") private var scope = Scope.edited
    @AppStorage("exportFormat") private var format = Format.jpeg
    @AppStorage("exportAddsFilmName") private var addsFilmName = true
    /// The folder last exported to, kept between launches as a security-scoped bookmark.
    @AppStorage("exportFolder") private var folderBookmark: Data?
    @State private var folder: URL?
    @State private var result: String?
    @State private var exportedFolder: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                settings
                    .frame(width: 320)
                Divider()
                preview
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(library.projectName)
        .navigationSubtitle("Export")
        .onAppear {
            guard folder == nil, let folderBookmark else { return }
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: folderBookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
               url.startAccessingSecurityScopedResource() {
                folder = url
            }
        }
    }

    private var jobs: [LibraryItem] {
        switch scope {
        case .selected: library.shownItems.filter { library.selection.contains($0.id) }
        case .edited: library.shownItems.filter(\.isEdited)
        case .all: library.shownItems
        }
    }

    private var settings: some View {
        Form {
            Picker("Photos", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Format", selection: $format) {
                ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Add the film's name to file names", isOn: $addsFilmName)
            LabeledContent("Folder") {
                HStack {
                    Text(folder?.lastPathComponent ?? "None chosen")
                        .foregroundStyle(folder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Section {
                if let phase = photos.savePhase {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(phase).lineLimit(2)
                    }
                    Button("Cancel") { photos.cancel() }
                } else {
                    Button {
                        export()
                    } label: {
                        Label("Export \(jobs.count) Photo\(jobs.count == 1 ? "" : "s")", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(jobs.isEmpty)
                }
                if let result {
                    Text(result).foregroundStyle(.secondary)
                    if let exportedFolder {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exportedFolder]) }
                    }
                }
            } footer: {
                Text("Each photo renders at full resolution with its own settings. Photos you haven't edited use the film's default settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var preview: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(jobs) { item in
                    ThumbnailCell(item: item, size: 130, isSelected: false)
                }
            }
        }
        .overlay {
            if jobs.isEmpty {
                ContentUnavailableView("Nothing to export", systemImage: "photo.on.rectangle",
                                       description: Text(scope == .selected
                                                         ? "Select photos in Import: ⌘-click to add one, ⇧-click for a run, ⌘A for all."
                                                         : "Edit a photo first."))
            }
        }
    }

    /// Asks for the folder to export to, then exports if `exportAfter`.
    private func chooseFolder(exportAfter: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        Task {
            let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
            guard response == .OK, let url = panel.url else { return }
            folder = url
            folderBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            if exportAfter { export() }
        }
    }

    private func export() {
        guard let folder else { chooseFolder(exportAfter: true); return }
        let fallback = photos.startingControls()
        let list: [PhotoModel.ExportJob] = jobs.compactMap { item in
            guard let url = library.url(of: item) else { return nil }
            let controls = item.controlsPreset.flatMap { try? Controls(preset: $0) } ?? fallback
            let base = (item.name as NSString).deletingPathExtension
            let name = addsFilmName ? "\(base) – \(photos.filmName(of: controls))" : base
            return PhotoModel.ExportJob(url: url, controls: controls, name: name)
        }
        result = nil
        Task {
            let written = await photos.exportPhotos(list, to: folder, as: format.type)
            result = written == list.count
                ? "Exported \(written) photo\(written == 1 ? "" : "s") to \(folder.lastPathComponent)."
                : "Exported \(written) of \(list.count) to \(folder.lastPathComponent). The Log says why the rest failed."
            exportedFolder = written > 0 ? folder : nil
        }
    }
}
