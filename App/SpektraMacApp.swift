import SpektraEngine
import SwiftUI

@main
struct SpektraMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: PhotoModel { delegate.model }
    private var library: LibraryModel { delegate.library }

    var body: some Scene {
        Window("SpektraMac", id: "main") {
            WorkspaceView()
                .environment(model)
                .environment(library)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            // Nothing here prints.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .newItem) {
                Button("Import Photos…", systemImage: "plus") { library.presentImport() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent", systemImage: "clock") {
                    ForEach(model.recentPhotos, id: \.self) { url in
                        Button(url.lastPathComponent) { library.importAndEdit([url]) }
                    }
                    Divider()
                    Button("Clear Menu") { model.clearRecentPhotos() }
                        .disabled(model.recentPhotos.isEmpty)
                }
                Divider()
                Button("New Project…") { library.newProject() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") { library.openProject() }
                Button("Save Project") { library.saveProject() }
                Divider()
                Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
                Button("Export LUT…", systemImage: "cube") { model.exportLUT() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportLUT)
                Button("Cancel", systemImage: "xmark.circle") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canCancel)
            }
            InspectorCommands()
            ViewCommands(model: model)
            CommandMenu("Photo") {
                Button("Previous Photo") { library.editNeighbour(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(library.step != .edit)
                Button("Next Photo") { library.editNeighbour(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(library.step != .edit)
            }
            // The user guide on GitHub: there's no help book.
            CommandGroup(replacing: .help) {
                Link("SpektraMac Help", destination: URL(string: "https://github.com/nainajnahO/SpektraMac/blob/main/docs/guide.md")!)
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandMenu("Preset") {
                Group {
                    Button("Open Preset…") { model.isImportingPreset = true }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                    Button("Save Preset…") { model.savePreset() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Divider()
                    Button("Make Default for \(model.filmName)") { model.makeDefaultForFilm() }
                    Button("Restore Factory Defaults") { model.restoreFactoryDefaults() }
                }
                .disabled(!model.canUsePresets)
            }
        }

        // A window of its own: the settings have the main window's inspector.
        Window("Log", id: "log") {
            LogView()
                .environment(model)
        }
        .defaultSize(width: 420, height: 480)
        // Window › Log, as the toolbar's Log button.
        .keyboardShortcut("l", modifiers: [.command, .option])
    }
}

/// The View menu's commands for what the toolbar and the canvas do: Print or Film, the settings'
/// tabs, zooming and the original. (Hiding the settings is ``InspectorCommands``'.)
struct ViewCommands: Commands {
    let model: PhotoModel
    @FocusedValue(\.settingsCategory) private var category
    @FocusedValue(\.showsSettings) private var showsSettings
    @FocusedValue(\.canvasZoom) private var canvasZoom

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            // Choosing the one showing changes nothing.
            Toggle("Print", isOn: Binding { !model.showsFilm } set: { _ in
                if model.showsFilm { model.controls.scanFilm = false }
            })
                .keyboardShortcut("1")
                .disabled(model.isSlideFilm || model.showsOriginal)
            Toggle("Film", isOn: Binding { model.showsFilm } set: { _ in
                if !model.showsFilm { model.controls.scanFilm = true }
            })
                .keyboardShortcut("2")
                .disabled(model.showsOriginal)
            Divider()
            ForEach(Array(SettingsCategory.allCases.enumerated()), id: \.element) { index, tab in
                // Choosing a tab shows the settings, if they're hidden.
                Toggle("\(tab.rawValue) Settings", isOn: Binding { showsSettings?.wrappedValue == true && category?.wrappedValue == tab } set: { _ in
                    category?.wrappedValue = tab
                    showsSettings?.wrappedValue = true
                })
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                .disabled(category == nil)
            }
            Divider()
            Button("Zoom In") { canvasZoom?.zoomIn?() }
                .keyboardShortcut("+")
                .disabled(canvasZoom?.zoomIn == nil)
            Button("Zoom Out") { canvasZoom?.zoomOut?() }
                .keyboardShortcut("-")
                .disabled(canvasZoom?.zoomOut == nil)
            Button("Zoom to Fit") { canvasZoom?.fit?() }
                .keyboardShortcut("0")
                .disabled(canvasZoom?.fit == nil)
            Divider()
            // As a click on the photo. Photos shows the original while M is held; a menu command
            // switches.
            Toggle("Show Original", isOn: Binding { model.showsOriginal } set: { model.showsOriginal = $0 })
                .keyboardShortcut("m", modifiers: [])
                .disabled(model.original == nil)
            Divider()
        }
    }
}

/// Owns the model, so the app can ask before quitting during a save, and keep the settings for the
/// next launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PhotoModel()
    lazy var library = LibraryModel(photos: model)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let phase = model.savePhase else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while saving?"
        alert.informativeText = "\(phase) If you quit now, the photo isn't saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    /// Photos sent by Finder's Open With and the Dock icon (the app's document types), all at once:
    /// imported, and the first opened in Edit.
    func application(_ application: NSApplication, open urls: [URL]) {
        library.importAndEdit(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.storeSettings()
        library.saveNow()
    }
}
