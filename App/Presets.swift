import AppKit
import OSLog
import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

extension PhotoModel.Adjustment {
    /// The group's name, as the panel heads it.
    var title: String {
        switch self {
        case .stocks: "Film & Paper"
        case .exposure: "Exposure"
        case .cameraDiffusion: "Lens Diffusion"
        case .halation: "Halation"
        case .couplers: "Couplers"
        case .grain: "Grain"
        case .contrast: "Contrast"
        case .enlarger: "Enlarger & Preflash"
        case .vignette: "Vignette"
        case .burn: "Burn"
        case .enlargerDiffusion: "Enlarger Diffusion"
        case .glare: "Glare"
        case .scanLook: "Scanned Print"
        case .crop: "Crop & Rotate"
        }
    }
}

/// A preset in the app's Presets folder, as Lightroom keeps its own: the controls as JSON
/// (``Controls/preset()``), plus which groups it sets (`includes`). A preset saved elsewhere, or
/// by an older version, sets them all.
struct SavedPreset: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The saved presets, and the edits copied from one photo to paste on others.
@MainActor
@Observable
final class PresetLibrary {
    typealias Group = PhotoModel.Adjustment

    private(set) var presets: [SavedPreset] = []

    static let folder = URL.applicationSupportDirectory.appending(path: "Presets", directoryHint: .isDirectory)
    private static let includesKey = "includes"
    private let logger = Logger(subsystem: "nainajnahO.SpektraMac", category: "presets")

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil,
                                                                 options: .skipsHiddenFiles)) ?? []
        presets = files.filter { $0.pathExtension == "json" }.map(SavedPreset.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves `controls`' `groups` as a preset named `name`, replacing one of that name.
    func save(_ controls: Controls, groups: Set<Group>, name: String) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var json = try JSONSerialization.jsonObject(with: controls.preset()) as? [String: Any] ?? [:]
        json[Self.includesKey] = Group.allCases.filter(groups.contains).map(\.rawValue)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url(named: name), options: .atomic)
        reload()
    }

    /// A preset's controls, and the groups it sets.
    func load(_ preset: SavedPreset) throws -> (controls: Controls, groups: Set<Group>) {
        try Self.read(Data(contentsOf: preset.url))
    }

    static func read(_ data: Data) throws -> (controls: Controls, groups: Set<Group>) {
        let controls = try Controls(preset: data)
        let includes = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[includesKey] as? [String]
        // A preset saved before presets said what they set has every group but the framing, which
        // is each photo's.
        let groups = includes.map { Set($0.compactMap(Group.init(rawValue:))) } ?? Set(Group.allCases).subtracting([.crop])
        return (controls, groups)
    }

    func rename(_ preset: SavedPreset, to name: String) throws {
        let destination = url(named: name)
        guard destination != preset.url else { return }
        try FileManager.default.moveItem(at: preset.url, to: destination)
        reload()
    }

    /// Moves the preset to the Trash, where it can be put back.
    func delete(_ preset: SavedPreset) {
        do {
            try FileManager.default.trashItem(at: preset.url, resultingItemURL: nil)
        } catch {
            logger.error("Couldn't move \(preset.name, privacy: .public) to the Trash: \(error.localizedDescription, privacy: .public)")
        }
        reload()
    }

    /// Copies preset files chosen in an Open panel into the folder.
    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose presets to add."
        guard panel.runModal() == .OK else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for url in panel.urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), (try? Controls(preset: data)) != nil else { continue }
            try? data.write(to: self.url(named: url.deletingPathExtension().lastPathComponent), options: .atomic)
        }
        reload()
    }

    func showInFinder(_ preset: SavedPreset? = nil) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([preset?.url ?? Self.folder])
    }

    private func url(named name: String) -> URL {
        let safe = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return Self.folder.appending(path: "\(safe).json")
    }
}

// MARK: - Copying, pasting and applying edits

extension LibraryModel {
    typealias Group = PhotoModel.Adjustment

    /// The groups Copy Edits copies and Save Preset saves, as last chosen.
    var copyGroups: Set<Group> {
        get { Self.storedGroups("copyGroups") ?? Set(Group.allCases).subtracting([.crop]) }
        set { Self.storeGroups(newValue, as: "copyGroups") }
    }

    var presetGroups: Set<Group> {
        get { Self.storedGroups("presetGroups") ?? Set(Group.allCases).subtracting([.exposure, .crop]) }
        set { Self.storeGroups(newValue, as: "presetGroups") }
    }

    private static func storedGroups(_ key: String) -> Set<Group>? {
        UserDefaults.standard.stringArray(forKey: key).map { Set($0.compactMap(Group.init(rawValue:))) }
    }

    private static func storeGroups(_ groups: Set<Group>, as key: String) {
        UserDefaults.standard.set(groups.map(\.rawValue), forKey: key)
    }

    /// The photo whose edits Copy Edits copies: the one in Edit, else the only one selected.
    private var copySourceControls: Controls? {
        if step == .edit, photos.photo != nil { return photos.controls }
        guard selection.count == 1, let item = items.first(where: { selection.contains($0.id) }) else { return nil }
        return controls(of: item)
    }

    var canCopyEdits: Bool { copySourceControls != nil }

    /// The photos a paste or a preset changes: the one in Edit, else those selected.
    private var pasteTargets: Set<LibraryItem.ID> {
        if step == .edit { return currentID.map { [$0] } ?? [] }
        return selection
    }

    var canPasteEdits: Bool { copiedEdits != nil && !pasteTargets.isEmpty }
    var canApplyPreset: Bool { !pasteTargets.isEmpty || (step == .edit && photos.photo != nil) }

    func copyEdits(_ groups: Set<Group>? = nil) {
        guard let source = copySourceControls else { return }
        let groups = groups ?? copyGroups
        copiedEdits = (source, groups)
        status = "Copied \(groups.count == Group.allCases.count ? "all edits" : groups.sorted { $0.title < $1.title }.map(\.title).formatted())"
    }

    func pasteEdits() {
        guard let copiedEdits else { return }
        apply(copiedEdits.controls, groups: copiedEdits.groups, named: "Paste Edits")
    }

    func applyPreset(_ preset: SavedPreset) {
        defer { presets.reload() }
        do {
            let (controls, groups) = try presets.load(preset)
            apply(controls, groups: groups, named: "Apply Preset “\(preset.name)”")
        } catch {
            photos.failure = PhotoModel.Failure(title: "Couldn't apply the preset “\(preset.name)”.",
                                               message: error.localizedDescription)
        }
    }

    /// `source`'s `groups` over each target photo's own settings: the open one through its controls,
    /// so its render and its undo follow; the rest as stored settings, with one undo step for them.
    private func apply(_ source: Controls, groups: Set<Group>, named name: String) {
        let source = photos.checkedControls(source)
        let targets = pasteTargets
        let open = currentID.flatMap { id in photos.photo != nil && (targets.contains(id) || step == .edit) ? id : nil }
        if open != nil {
            photos.apply(PhotoModel.copying(groups, from: source, into: photos.controls), named: name)
        }
        var before: [LibraryItem.ID: Data?] = [:]
        for index in items.indices where targets.contains(items[index].id) && items[index].id != open {
            before[items[index].id] = items[index].controlsPreset
            let merged = PhotoModel.copying(groups, from: source, into: controls(of: items[index]))
            items[index].controlsPreset = try? merged.preset()
        }
        guard !before.isEmpty else { return }
        scheduleSave()
        status = "\(name) on \(before.count) photo\(before.count == 1 ? "" : "s")"
        photos.undoManager?.registerUndo(withTarget: self) { library in
            library.restore(before, named: name)
        }
        photos.undoManager?.setActionName(name)
    }

    /// Puts photos' stored settings back as they were, registering Redo.
    private func restore(_ presets: [LibraryItem.ID: Data?], named name: String) {
        var current: [LibraryItem.ID: Data?] = [:]
        for index in items.indices {
            guard let preset = presets[items[index].id] else { continue }
            current[items[index].id] = items[index].controlsPreset
            items[index].controlsPreset = preset
        }
        scheduleSave()
        photos.undoManager?.registerUndo(withTarget: self) { library in library.restore(current, named: name) }
        photos.undoManager?.setActionName(name)
    }

    /// A photo's settings: its own, else those it would open with (``PhotoModel/startingControls()``).
    private func controls(of item: LibraryItem) -> Controls {
        if item.id == currentID, photos.photo != nil { return photos.controls }
        return item.controlsPreset.flatMap { try? Controls(preset: $0) } ?? photos.startingControls()
    }
}

// MARK: - Views

/// The Presets tab: the saved presets, applied with a click, and the ways to make and copy them.
struct PresetsPanel: View {
    @Environment(LibraryModel.self) private var library
    @State private var renaming: SavedPreset?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Save Preset…", systemImage: "plus") { library.groupsSheet = .savePreset }
                    .disabled(library.photos.photo == nil)
                Spacer()
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Import Presets…") { library.presets.importPresets() }
                    Button("Show Presets Folder") { library.presets.showInFinder() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                Button("Copy Edits…") { library.groupsSheet = .copy }
                    .disabled(!library.canCopyEdits)
                Button("Paste") { library.pasteEdits() }
                    .disabled(!library.canPasteEdits)
            }
            .controlSize(.small)
            .padding(.horizontal, 15)
            .padding(.bottom, 8)

            Divider()

            if library.presets.presets.isEmpty {
                ContentUnavailableView("No Presets", systemImage: "square.stack.3d.up",
                                       description: Text("Save the settings of a photo you like as a preset, then apply it to others with a click."))
                    .frame(maxHeight: .infinity)
            } else {
                List(library.presets.presets) { preset in
                    Button {
                        library.applyPreset(preset)
                    } label: {
                        Label(preset.name, systemImage: "camera.filters")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!library.canApplyPreset)
                    .help("Apply “\(preset.name)” to \(library.step == .edit ? "this photo" : "the selected photos")")
                    .contextMenu {
                        Button("Apply") { library.applyPreset(preset) }
                        Button("Update with Current Settings") { library.updatePreset(preset) }
                            .disabled(library.photos.photo == nil)
                        Button("Rename…") { newName = preset.name; renaming = preset }
                        Button("Show in Finder") { library.presets.showInFinder(preset) }
                        Divider()
                        Button("Move to Trash") { library.presets.delete(preset) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { library.presets.reload() }
        .alert("Rename Preset", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming, !newName.isEmpty { try? library.presets.rename(renaming, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

extension LibraryModel {
    /// Saves the open photo's settings over `preset`, keeping the groups it sets.
    func updatePreset(_ preset: SavedPreset) {
        let groups = (try? presets.load(preset).groups) ?? presetGroups
        savePreset(named: preset.name, groups: groups)
    }

    func savePreset(named name: String, groups: Set<Group>) {
        do {
            try presets.save(photos.controls, groups: groups, name: name)
            status = "Saved preset “\(name)”"
        } catch {
            photos.failure = PhotoModel.Failure(title: "Couldn't save the preset “\(name)”.", message: error.localizedDescription)
        }
    }
}

/// What the groups sheet is choosing groups for.
enum GroupsSheet: Identifiable {
    case copy, savePreset
    var id: Self { self }
}

/// Lightroom's Copy Settings and New Preset dialogs: which groups of settings to take, with a name
/// for a preset.
struct GroupsSheetView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let purpose: GroupsSheet
    @State private var groups: Set<PhotoModel.Adjustment> = []
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(purpose == .copy ? "Copy Edits" : "New Preset").font(.headline)
            if purpose == .savePreset {
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            Text(purpose == .copy ? "Edits to copy:" : "Settings the preset sets:")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      spacing: 6) {
                ForEach(PhotoModel.Adjustment.allCases, id: \.self) { group in
                    Toggle(group.title, isOn: Binding { groups.contains(group) } set: { on in
                        if on { groups.insert(group) } else { groups.remove(group) }
                    })
                }
            }
            HStack {
                Button("Check All") { groups = Set(PhotoModel.Adjustment.allCases) }
                Button("Check None") { groups = [] }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(purpose == .copy ? "Copy" : "Save") {
                    switch purpose {
                    case .copy:
                        library.copyGroups = groups
                        library.copyEdits(groups)
                    case .savePreset:
                        library.presetGroups = groups
                        library.savePreset(named: name, groups: groups)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groups.isEmpty || (purpose == .savePreset && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            groups = purpose == .copy ? library.copyGroups : library.presetGroups
            if purpose == .savePreset { name = library.photos.filmName }
        }
    }
}
