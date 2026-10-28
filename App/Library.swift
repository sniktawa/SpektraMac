import AppKit
import Foundation
import ImageIO
import Observation
import SpektraEngine
import UniformTypeIdentifiers
import os

/// The window's three steps, as the toolbar shows them: Import (the project's photos), Edit (one
/// photo on film) and Export (the edited photos, rendered).
enum WorkflowStep: String, CaseIterable, Identifiable {
    case importing = "Import"
    case edit = "Edit"
    case export = "Export"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .importing: "square.and.arrow.down.on.square"
        case .edit: "slider.horizontal.3"
        case .export: "square.and.arrow.up"
        }
    }
}

/// A photo in a project: where it is (a security-scoped bookmark, so the sandboxed app can open it
/// again after a relaunch) and its own settings once it has been edited.
struct LibraryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var bookmark: Data
    var name: String
    /// Where it was when imported or last found, shown when the bookmark no longer resolves.
    var path: String
    var importDate: Date
    /// The photo's settings (``Controls/preset()``), once changed in Edit; nil carries over the last.
    var controlsPreset: Data?

    var isEdited: Bool { controlsPreset != nil }
}

/// A project as it's saved: a JSON file of its photos.
private struct ProjectFile: Codable {
    var version = 1
    var name: String
    var items: [LibraryItem]
}

/// The project's photos, their thumbnails and the window's step. Each photo keeps its own settings:
/// opening one in Edit applies them, and every change there is stored back (``PhotoModel/onControlsChanged``).
@MainActor
@Observable
final class LibraryModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", edited = "Edited", unedited = "Not Edited"
        var id: Self { self }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case importDate = "Import Date", name = "File Name"
        var id: Self { self }
    }

    nonisolated static let projectExtension = "spektramac"
    /// macOS declares no type for project files, so the panels get a dynamic one.
    static let projectType = UTType(filenameExtension: projectExtension, conformingTo: .json) ?? .json

    var step: WorkflowStep = .importing
    private(set) var projectName = "Default Project"
    /// Set only here, and by pasting edits and applying presets (Presets.swift).
    var items: [LibraryItem] = []
    var selection: Set<LibraryItem.ID> = []
    /// The photo open in Edit.
    private(set) var currentID: LibraryItem.ID?
    var filter: Filter = .all
    var sort: Sort = .importDate
    /// The thumbnails' size in the grid, in points.
    var thumbnailSize: Double = 180
    private(set) var thumbnails: [LibraryItem.ID: CGImage] = [:]
    /// What the library is doing, for the status bar.
    var status = ""
    private(set) var isImporting = false

    let photos: PhotoModel
    let presets = PresetLibrary()
    /// The edits Copy Edits took, for Paste.
    var copiedEdits: (controls: Controls, groups: Set<PhotoModel.Adjustment>)?
    /// The Copy Edits or Save Preset sheet, while it's up.
    var groupsSheet: GroupsSheet?
    /// Where the project is saved: the default project in the app's own folder until one is chosen.
    private var projectURL: URL
    @ObservationIgnored private var resolvedURLs: [LibraryItem.ID: URL] = [:]
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var loadingThumbnails: Set<LibraryItem.ID> = []
    private let logger = Logger(subsystem: "nainajnahO.SpektraMac", category: "library")

    private static let lastProjectKey = "lastProjectBookmark"
    nonisolated static let thumbnailPixels = 480

    init(photos: PhotoModel) {
        self.photos = photos
        projectURL = Self.defaultProjectURL
        if let data = UserDefaults.standard.data(forKey: Self.lastProjectKey), let url = Self.resolve(data) {
            projectURL = url
        }
        load(from: projectURL)
        photos.onControlsChanged = { [weak self] url, controls in self?.store(controls, for: url) }
        photos.onFinishedRender = { [weak self] url, image in self?.storeRenderedThumbnail(image, for: url) }
    }

    // MARK: Showing

    /// The photos the grid and the filmstrip show, filtered and sorted.
    var shownItems: [LibraryItem] {
        let filtered = switch filter {
        case .all: items
        case .edited: items.filter(\.isEdited)
        case .unedited: items.filter { !$0.isEdited }
        }
        return switch sort {
        case .importDate: filtered.sorted { ($0.importDate, $0.name) < ($1.importDate, $1.name) }
        case .name: filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var currentItem: LibraryItem? { items.first { $0.id == currentID } }

    /// Opens `item` in Edit with its own settings.
    func edit(_ item: LibraryItem) {
        guard let url = url(of: item) else {
            photos.failure = PhotoModel.Failure(title: "Couldn't find “\(item.name)”.",
                                               message: "It was at \(item.path). Reconnect the drive it's on, or import it again.")
            return
        }
        currentID = item.id
        selection = [item.id]
        let controls = item.controlsPreset.flatMap { try? Controls(preset: $0) } ?? photos.startingControls()
        // The next photo first, as photos are mostly stepped through forwards.
        let shown = shownItems
        let neighbours = shown.firstIndex(where: { $0.id == item.id }).map { index in
            [index + 1, index - 1].filter(shown.indices.contains).compactMap { self.url(of: shown[$0]) }
        } ?? []
        photos.open(url, controls: controls, placeholder: thumbnails[item.id], preloading: neighbours)
        step = .edit
    }

    /// Edit's next or previous photo in the shown order.
    func editNeighbour(_ offset: Int) {
        let shown = shownItems
        guard let index = shown.firstIndex(where: { $0.id == currentID }) else { return }
        let next = index + offset
        guard shown.indices.contains(next) else { return }
        edit(shown[next])
    }

    /// The step's button: Edit opens the selected photo if none is open yet.
    func go(to step: WorkflowStep) {
        if step == .edit, currentID == nil, let first = shownItems.first(where: { selection.contains($0.id) }) ?? shownItems.first {
            edit(first)
            return
        }
        self.step = step
    }

    // MARK: Importing

    /// Asks for photos or folders of them with the standard Open panel, which previews them
    /// (Quick Look with the space bar, thumbnails in its gallery view).
    func presentImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Photos"
        panel.prompt = "Import"
        panel.message = "Choose photos, or folders of them. Press the space bar to preview a photo."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .rawImage, .folder]
        Task {
            let response = if let window = NSApp.keyWindow {
                await panel.beginSheetModal(for: window)
            } else {
                await panel.begin()
            }
            guard response == .OK else { return }
            await importPhotos(panel.urls)
        }
    }

    /// Adds the photos at `urls` (and in folders among them) not already in the project, then opens
    /// the first in Edit if `edit`.
    func importPhotos(_ urls: [URL], edit openInEdit: Bool = false) async {
        isImporting = true
        status = "Importing…"
        defer { isImporting = false }
        let known = Set(items.map(\.path))
        let found = await Task.detached(priority: .userInitiated) { Self.photoFiles(in: urls) }.value
        var added: [LibraryItem] = []
        let now = Date()
        let roots = Set(found.map(\.1))
        // Held until the thumbnails are made: a folder's .thm files are only readable through it.
        let scopedRoots = roots.filter { $0.startAccessingSecurityScopedResource() }
        for (file, _) in found where !known.contains(file.path(percentEncoded: false)) {
            guard let bookmark = Self.bookmark(for: file) else {
                logger.error("Could not keep \(file.path(percentEncoded: false), privacy: .public)")
                continue
            }
            let item = LibraryItem(bookmark: bookmark, name: file.lastPathComponent,
                                   path: file.path(percentEncoded: false), importDate: now)
            added.append(item)
            resolvedURLs[item.id] = file
        }
        items.append(contentsOf: added)
        status = added.isEmpty ? "No new photos" : "Imported \(added.count) photo\(added.count == 1 ? "" : "s")"
        selection = Set(added.map(\.id))
        scheduleSave()
        let jobs = added.map { ($0.id, resolvedURLs[$0.id]!) }
        Task {
            await makeThumbnails(jobs)
            for root in scopedRoots { root.stopAccessingSecurityScopedResource() }
        }
        if openInEdit, let first = added.first ?? items.first(where: { found.first?.0.path(percentEncoded: false) == $0.path }) {
            edit(first)
        }
    }

    /// Photos dropped on the window or sent by Finder: imported, and the first opened in Edit.
    func importAndEdit(_ urls: [URL]) {
        Task { await importPhotos(urls, edit: true) }
    }

    func remove(_ ids: Set<LibraryItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        for id in ids {
            thumbnails[id] = nil
            resolvedURLs[id] = nil
            try? FileManager.default.removeItem(at: Self.thumbnailURL(for: id))
        }
        if let currentID, ids.contains(currentID) {
            self.currentID = nil
        }
        scheduleSave()
    }

    func showInFinder(_ ids: Set<LibraryItem.ID>) {
        let urls = items.filter { ids.contains($0.id) }.compactMap { url(of: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Forgets the photos' own settings: they take the last ones again when opened.
    func resetSettings(_ ids: Set<LibraryItem.ID>) {
        for index in items.indices where ids.contains(items[index].id) {
            items[index].controlsPreset = nil
        }
        scheduleSave()
    }

    /// Each image file in `urls`, looking inside folders (not packages or hidden files), with the
    /// URL the user chose that gives access to it.
    nonisolated private static func photoFiles(in urls: [URL]) -> [(URL, URL)] {
        var files: [(URL, URL)] = []
        for root in urls {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            if (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentTypeKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = walker?.nextObject() as? URL {
                    if isPhoto(file) { files.append((file, root)) }
                }
            } else if isPhoto(root) {
                files.append((root, root))
            }
        }
        return files.sorted { $0.0.path(percentEncoded: false).localizedStandardCompare($1.0.path(percentEncoded: false)) == .orderedAscending }
    }

    nonisolated private static func isPhoto(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .image) || type.conforms(to: .rawImage)
    }

    // MARK: Files

    /// The photo's file, resolved from its bookmark once and kept open to the app.
    func url(of item: LibraryItem) -> URL? {
        if let url = resolvedURLs[item.id] { return url }
        guard let url = Self.resolve(item.bookmark) else { return nil }
        resolvedURLs[item.id] = url
        return url
    }

    /// A bookmark the sandboxed app can open again after a relaunch; a plain one if the file can't
    /// have a security-scoped one (it's already reachable without).
    nonisolated private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    /// The file a bookmark points to, with access started for the rest of the session.
    nonisolated private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        return try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale)
    }

    /// The item the open photo's file belongs to.
    private func itemIndex(for url: URL) -> Int? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        if let id = resolvedURLs.first(where: { $0.value.standardizedFileURL.path(percentEncoded: false) == path })?.key {
            return items.firstIndex { $0.id == id }
        }
        return items.firstIndex { $0.path == path }
    }

    private func store(_ controls: Controls, for url: URL) {
        guard let index = itemIndex(for: url), let preset = try? controls.preset() else { return }
        items[index].controlsPreset = preset
        scheduleSave()
    }

    // MARK: Thumbnails

    /// Loads the thumbnails of `item` if it has none yet: the last render of its edit, else the photo.
    func loadThumbnail(for item: LibraryItem) {
        guard thumbnails[item.id] == nil, !loadingThumbnails.contains(item.id) else { return }
        loadingThumbnails.insert(item.id)
        let id = item.id
        let url = url(of: item)
        Task {
            let image = await Task.detached(priority: .utility) {
                Self.readThumbnail(for: id) ?? url.flatMap { Self.makeThumbnail(of: $0) }
            }.value
            loadingThumbnails.remove(id)
            guard let image else { return }
            thumbnails[id] = image
            if Self.readThumbnail(for: id) == nil {
                Self.writeThumbnail(image, for: id)
            }
        }
    }

    /// Thumbnails for newly imported photos: a scanner's small .thm at once where there is one, then
    /// the photo's own, two at a time (each reads the whole file, seconds for a TIFF on a NAS),
    /// pausing while a photo opens in Edit so it doesn't wait on them.
    private func makeThumbnails(_ jobs: [(LibraryItem.ID, URL)]) async {
        for (id, url) in jobs {
            if let quick = await Task.detached(priority: .userInitiated, operation: { Self.scannerThumbnail(of: url) }).value {
                thumbnails[id] = quick
            }
        }
        loadingThumbnails.formUnion(jobs.map(\.0))
        var pending = jobs[...]
        var running = 0
        await withTaskGroup(of: (LibraryItem.ID, CGImage?).self) { group in
            while !pending.isEmpty || running > 0 {
                while running < 2, !pending.isEmpty {
                    while photos.isLoading { try? await Task.sleep(for: .milliseconds(250)) }
                    let (id, url) = pending.removeFirst()
                    group.addTask(priority: .utility) { (id, Self.makeThumbnail(of: url)) }
                    running += 1
                }
                guard let (id, image) = await group.next() else { break }
                running -= 1
                loadingThumbnails.remove(id)
                if let image, items.contains(where: { $0.id == id }) {
                    thumbnails[id] = image
                    Task.detached(priority: .background) { Self.writeThumbnail(image, for: id) }
                }
            }
        }
        status = "Thumbnails ready"
    }

    /// The edit's screen-size render, reduced, as the photo's thumbnail.
    private func storeRenderedThumbnail(_ image: CGImage, for url: URL) {
        guard let index = itemIndex(for: url) else { return }
        let id = items[index].id
        Task {
            guard let small = await Task.detached(priority: .utility, operation: { Self.reduced(image) }).value else { return }
            thumbnails[id] = small
            Task.detached(priority: .background) { Self.writeThumbnail(small, for: id) }
        }
    }

    /// The small thumbnail a Noritsu scanner writes beside each scan (.thm), if it's there.
    nonisolated private static func scannerThumbnail(of url: URL) -> CGImage? {
        let thm = url.deletingPathExtension().appendingPathExtension("thm")
        guard let source = CGImageSourceCreateWithURL(thm as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A thumbnail of the photo from ImageIO: one embedded in the file, else from the image itself.
    nonisolated private static func makeThumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ] as CFDictionary)
    }

    nonisolated private static func reduced(_ image: CGImage) -> CGImage? {
        let scale = min(1, Double(thumbnailPixels) / Double(max(image.width, image.height)))
        let (width, height) = (max(1, Int(Double(image.width) * scale)), max(1, Int(Double(image.height) * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated private static var thumbnailFolder: URL {
        URL.cachesDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    nonisolated private static func thumbnailURL(for id: UUID) -> URL {
        thumbnailFolder.appending(path: "\(id.uuidString).jpg")
    }

    nonisolated private static func readThumbnail(for id: UUID) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(thumbnailURL(for: id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated private static func writeThumbnail(_ image: CGImage, for id: UUID) {
        try? FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(thumbnailURL(for: id) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: Projects

    nonisolated private static var defaultProjectURL: URL {
        URL.applicationSupportDirectory.appending(path: "Default Project.\(projectExtension)")
    }

    var isDefaultProject: Bool { projectURL == Self.defaultProjectURL }

    /// Starts an empty project in a file chosen with the Save panel, saving this one first.
    func newProject() {
        saveNow()
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = "Untitled Project.\(Self.projectExtension)"
        panel.canCreateDirectories = true
        present(panel) { url in
            self.switchProject(to: url, items: [], name: url.deletingPathExtension().lastPathComponent)
            self.saveNow()
        }
    }

    func openProject() {
        saveNow()
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.allowedContentTypes = [Self.projectType, .json]
        present(panel) { url in
            self.load(from: url)
            self.rememberProject(url)
        }
    }

    /// Saves the project, asking where the first time for the default project.
    func saveProject() {
        guard isDefaultProject else { saveNow(); status = "Saved"; return }
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = "\(projectName).\(Self.projectExtension)"
        panel.canCreateDirectories = true
        present(panel) { url in
            self.switchProject(to: url, items: self.items, name: url.deletingPathExtension().lastPathComponent)
            self.saveNow()
            self.status = "Saved"
        }
    }

    private func present(_ panel: NSSavePanel, then action: @escaping (URL) -> Void) {
        Task {
            let response = if let window = NSApp.keyWindow {
                await panel.beginSheetModal(for: window)
            } else {
                await panel.begin()
            }
            if response == .OK, let url = panel.url { action(url) }
        }
    }

    private func switchProject(to url: URL, items: [LibraryItem], name: String) {
        projectURL = url
        projectName = name
        self.items = items
        currentID = nil
        selection = []
        step = .importing
        rememberProject(url)
    }

    private func rememberProject(_ url: URL) {
        if url == Self.defaultProjectURL {
            UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
        } else if let bookmark = Self.bookmark(for: url) {
            UserDefaults.standard.set(bookmark, forKey: Self.lastProjectKey)
        }
    }

    private func load(from url: URL) {
        projectURL = url
        currentID = nil
        selection = []
        thumbnails = [:]
        resolvedURLs = [:]
        step = .importing
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(ProjectFile.self, from: Data(contentsOf: url))
            projectName = file.name
            items = file.items
            status = "\(file.name) opened"
        } catch CocoaError.fileReadNoSuchFile {
            projectName = url.deletingPathExtension().lastPathComponent
            items = []
            status = "\(projectName) ready"
        } catch {
            projectName = url.deletingPathExtension().lastPathComponent
            items = []
            status = "Couldn't read the project: \(error.localizedDescription)"
            logger.error("Could not read \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Saves a moment after the last change, so a slider's drag writes once.
    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            saveScheduled = false
            saveNow()
        }
    }

    func saveNow() {
        let file = ProjectFile(name: projectName, items: items)
        do {
            try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(file).write(to: projectURL, options: .atomic)
        } catch {
            status = "Couldn't save the project: \(error.localizedDescription)"
            logger.error("Could not save the project: \(error.localizedDescription, privacy: .public)")
        }
    }
}
