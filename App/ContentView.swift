import Charts
import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PhotoModel.self) private var model
    @Environment(LibraryModel.self) private var library
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("showsSettings") private var showsSettings = true
    @SceneStorage("settingsCategory") private var category = SettingsCategory.film
    @FocusState private var isCanvasFocused: Bool

    var body: some View {
        @Bindable var model = model
        ImageCanvas()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !library.items.isEmpty { Filmstrip() }
            }
            // Focused from the start, as nothing else in the window takes focus on a click, so
            // Edit › Copy (⌘C) reaches it: the finished photo, as Share sends it.
            .focusable()
            .focusEffectDisabled()
            .focused($isCanvasFocused)
            .defaultFocus($isCanvasFocused, true)
            .copyable([model.finishedPhoto].compactMap { $0 })
            .navigationTitle(model.photo?.name ?? "SpektraMac")
            .navigationSubtitle(status)
            .toolbar {
                ToolbarItemGroup {
                    ShowPicker()
                }
                ToolbarItemGroup {
                    Button("Import Photos…", systemImage: "plus") { library.presentImport() }
                    Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                        .disabled(!model.canSave)
                    shareButton
                    Button("Log", systemImage: "list.bullet.rectangle") { openWindow(id: "log") }
                    Toggle("Adjust", systemImage: "slider.horizontal.3", isOn: $showsSettings)
                        .help("Show or hide the settings")
                }
            }
            // No toolbar background, so the inspector's glass is even to the top: macOS draws one for
            // each column, over the inspector a dark fade behind the tabs. The zoomed photo shows
            // under the toolbar's glass instead (``ImageCanvas``).
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // On the right over the photo, as Photos' Adjust panel: the photo fits beside it and
            // shows through the inspector's glass when zoomed or moved under it (``ImageCanvas``),
            // as the inspector lies over the canvas rather than beside it.
            .inspector(isPresented: $showsSettings) {
                VStack(spacing: 0) {
                    // In the panel rather than the inspector's part of the toolbar, which drops it
                    // into the toolbar's overflow menu when the window is narrow.
                    Picker("Settings", selection: $category) {
                        ForEach(SettingsCategory.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 15)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    Group {
                        if category == .presets {
                            PresetsPanel()
                        } else if category == .crop {
                            CropPanel()
                                .disabled(model.showsOriginal)
                        } else {
                            SettingsPanel(category: category)
                                // Greyed out while the canvas shows the original: they set the edit.
                                .disabled(model.showsOriginal)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .inspectorColumnWidth(290)
            }
            // For the View menu (``ViewCommands``).
            .onChange(of: category == .crop && showsSettings, initial: true) { _, cropping in
                model.isCropping = cropping
            }
            .focusedSceneValue(\.settingsCategory, $category)
            .focusedSceneValue(\.showsSettings, $showsSettings)
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                library.importAndEdit(urls)
                return true
            }
        .fileImporter(isPresented: $model.isImportingPreset, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.openPreset(url)
            case .failure(let error): model.importFailed(error)
            }
        }
    }

    /// Share: the finished photo, or a greyed-out button in its place without a photo, so the
    /// toolbar doesn't move as one opens.
    @ViewBuilder private var shareButton: some View {
        if let finished = model.finishedPhoto {
            ShareLink(item: finished, preview: SharePreview(finished.name))
        } else {
            Button("Share", systemImage: "square.and.arrow.up") {}
                .disabled(true)
        }
    }

    /// What the app is doing, else the last error (until a photo is opened), else what the canvas
    /// shows: under the window's title.
    private var status: String {
        if model.isLoading { return "Opening…" }
        if let phase = model.savePhase { return phase }
        if model.showsOriginal { return "Original" }
        if model.isRendering { return model.isRenderingFullResolution ? "Rendering full resolution…" : "Rendering…" }
        if let message = model.errorMessage { return message }
        // Without one, the canvas says so.
        guard let photo = model.photo else { return "" }
        if model.shownMode == .full {
            return "Full resolution, \(photo.width.formatted()) × \(photo.height.formatted())"
        } else if case .reduced? = model.shownMode, let image = model.displayImage {
            return "Screen size, \(image.width.formatted()) × \(image.height.formatted())"
        } else {
            return "Preview, \(photo.previewWidth.formatted()) × \(photo.previewHeight.formatted())"
        }
    }
}

extension FocusedValues {
    /// The settings tab the window shows, and whether it shows the settings, for the View menu.
    @Entry var settingsCategory: Binding<SettingsCategory>?
    @Entry var showsSettings: Binding<Bool>?
    /// What the View menu's zoom commands do to the canvas, while it has a photo.
    @Entry var canvasZoom: CanvasZoom?
}

/// The canvas's zoom commands, each nil where it can't zoom that way.
struct CanvasZoom {
    let zoomIn: (() -> Void)?
    let zoomOut: (() -> Void)?
    let fit: (() -> Void)?
}

/// Print | Film, in a view of its own reading only what it shows (``PhotoModel/showsFilm``): the
/// controls change at every step of a slider, and read here or in the window's body they laid out
/// the toolbar again each time.
private struct ShowPicker: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        Picker("Show", selection: Binding { model.showsFilm } set: { model.controls.scanFilm = $0 }) {
            Text("Print").tag(false)
            Text("Film").tag(true)
        }
        .pickerStyle(.segmented)
        // A slide has no print, so the switch is greyed out on Film: a segment of its own greyed
        // out (`selectionDisabled`) looks no different in macOS 26's toolbar.
        .disabled(model.showsOriginal || model.isSlideFilm)
        .help(model.isSlideFilm
              ? "A slide is viewed directly, so it has no print. Choose a negative film to see one printed."
              : "Print: the film printed on the paper. Film: the developed negative, or the slide itself.")
    }
}

// MARK: - Canvas

/// The photo fitted to the canvas below the toolbar and beside the settings panel. Pinching (or
/// scrolling with ⌥) zooms around the pointer, scrolling or dragging moves the zoomed photo, as in
/// Preview; clicking shows the original in place of the edit (and the edit again), and
/// double-clicking shows all of it again. The View menu zooms too (``CanvasZoom``). The canvas
/// reaches under the toolbar and the panel, so a zoomed photo shows through them, as in Photos.
private struct ImageCanvas: View {
    @Environment(PhotoModel.self) private var model
    @Environment(LibraryModel.self) private var library
    /// Magnification over the photo fitted to the canvas (1 shows all of it), and how far the
    /// zoomed photo is moved from the centre, in points.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    /// How much of the canvas the toolbar (top) and the settings panel (trailing) cover.
    @State private var insets = EdgeInsets()
    /// Where the pointer is over the canvas below the toolbar and beside the panel: scrolling moves
    /// the photo under it, or zooms around it.
    @State private var pointer: CGPoint?
    /// The offset when the drag began, and the pinch's magnification so far.
    @State private var dragStart: CGSize?
    @State private var pinched: CGFloat = 1
    @State private var scrollMonitor: Any?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Takes the canvas below the toolbar and beside the panel, whose geometry gives their sizes
        // (the safe area's insets); the canvas itself reaches under them.
        Color.clear
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                self.insets = insets
                offset = clamped(offset)
            }
            .overlay { canvas.ignoresSafeArea(.container, edges: [.top, .trailing]) }
            // Over the canvas below the toolbar and beside the panel, so centred there.
            .overlay {
                if model.displayImage == nil {
                    if let failure = model.engineFailure {
                        ContentUnavailableView("Metal is unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text("SpektraMac simulates film on the graphics processor, through Metal. \(failure)."))
                    } else if model.isLoading || (model.photo != nil && model.errorMessage == nil) {
                        // A photo opening, or rendering for the first time: seconds for a RAW file.
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        ContentUnavailableView {
                            Label("No photo", systemImage: "photo")
                        } description: {
                            Text("Drop a photo here or open one to simulate it on film.")
                        } actions: {
                            Button("Import Photos…") { library.presentImport() }
                        }
                    }
                }
            }
            // Saving's progress and Cancel, over the photo rather than in the toolbar, which would
            // move its other buttons to make room. The render is one pass on the GPU, with no
            // stages to count, so the spinner says only that it's working, and the text what.
            .overlay(alignment: .bottom) {
                if let phase = model.savePhase {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(phase)
                        Button("Cancel") { model.cancel() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect()
                    .padding(.bottom, 16)
                }
            }
    }

    private var canvas: some View {
        // A stack, not a group: without a photo, the canvas is still there to measure and to shade.
        ZStack {
            if let image = model.displayImage {
                // The reader takes the canvas's size and passes nothing back: a frame sized by the
                // photo would make that the window's minimum.
                GeometryReader { _ in
                    let fitted = fittedSize(in: visibleSize)
                    let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
                    framed(Image(model.showsOriginal ? model.original ?? image : image, scale: 1, label: Text(photoDescription))
                        .resizable()
                        .interpolation(.high)
                        .overlay { meteringOverlay }
                        .overlay { burnOverlay }, size: size)
                        .overlay {
                            if model.isCropping {
                                CropOverlay(size: size)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .position(x: visibleCentre.x + offset.width, y: visibleCentre.y + offset.height)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { drag in
                        let start = dragStart ?? offset
                        dragStart = start
                        offset = clamped(CGSize(width: start.width + drag.translation.width,
                                                height: start.height + drag.translation.height))
                    }
                    .onEnded { _ in dragStart = nil }, isEnabled: !model.isCropping)
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { pinch in
                        // Pinched shut, the magnification reaches 0, and 0 over 0 would make the
                        // zoom not a number, the photo gone: until it's above 0 again, no change.
                        guard pinch.magnification > 0 else { return }
                        zoom(by: pinch.magnification / pinched, at: pinch.startLocation)
                        pinched = pinch.magnification
                    }
                    .onEnded { _ in pinched = 1 }, isEnabled: !model.isCropping)
                // Each click of a double-click is a click too: it switches twice, so it ends on
                // the view it started from.
                .onTapGesture {
                    guard !model.isCropping else { return }
                    if model.original != nil {
                        model.showsOriginal.toggle()
                    }
                    if NSApp.currentEvent?.clickCount == 2 {
                        zoom = 1
                        offset = .zero
                    }
                }
                .pointerStyle(zoom > 1 ? (dragStart == nil ? .grabIdle : .grabActive) : nil)
                .onContinuousHover { phase in
                    switch phase {
                    // Not under the toolbar or the panel: they lie over the canvas, yet it's still
                    // told where the pointer is.
                    case .active(let location) where location.x < visibleSize.width && location.y >= insets.top:
                        pointer = location
                    case .active, .ended: pointer = nil
                    }
                }
                .onAppear {
                    // SwiftUI has no scroll-wheel events for a plain view, so AppKit's: over the
                    // photo, scrolling zooms instead of scrolling. A trackpad's momentum after
                    // the fingers lift is left out, so the zoom stops with them.
                    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        guard let pointer, !model.isCropping else { return event }
                        if event.momentumPhase.isEmpty {
                            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.15  // points, or wheel lines
                            zoom(by: exp(event.scrollingDeltaY * step), at: pointer)
                        }
                        return nil
                    }
                }
                .onDisappear {
                    if let scrollMonitor {
                        NSEvent.removeMonitor(scrollMonitor)
                    }
                    scrollMonitor = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(.black.opacity(0.05))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            canvasSize = size
            offset = clamped(offset)
        }
        .onChange(of: model.photo?.id) {
            zoom = 1
            offset = .zero
        }
        // The crop tool shows all of the photo; the framing changes its shape, so the zoom starts over.
        .onChange(of: model.isCropping) {
            zoom = 1
            offset = .zero
        }
        .onChange(of: model.framing.quarterTurns) {
            zoom = 1
            offset = .zero
        }
        .focusedSceneValue(\.canvasZoom, model.photo == nil ? nil : CanvasZoom(
            zoomIn: zoom < maxZoom && !model.isCropping ? { zoom(by: 2, at: visibleCentre) } : nil,
            zoomOut: zoom > 1 ? { zoom(by: 0.5, at: visibleCentre) } : nil,
            fit: zoom > 1 ? { zoom = 1; offset = .zero } : nil))
        .onChange(of: fittedLongSide, initial: true) { _, pixels in
            model.canvasLongSide = pixels
        }
        .onChange(of: zoom > 1, initial: true) { _, wants in
            model.wantsFullResolution = wants
        }
    }

    /// The canvas below the toolbar and beside the panel.
    private var visibleSize: CGSize {
        CGSize(width: max(0, canvasSize.width - insets.trailing), height: max(0, canvasSize.height - insets.top))
    }

    private var visibleCentre: CGPoint {
        CGPoint(x: visibleSize.width / 2, y: insets.top + visibleSize.height / 2)
    }

    /// While the Exposure slider is held on a mark: the region that mark meters, tinted.
    @ViewBuilder private var meteringOverlay: some View {
        if model.isAdjustingExposure, let photo = model.photo {
            ZStack {
                ForEach(model.marksAtExposure, id: \.self) { mark in
                    if let overlay = photo.meteringOverlays[mark] {
                        Color.pink
                            .mask { Image(decorative: overlay, scale: 1).resizable() }
                            .opacity(0.5)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// While a Burn slider is held: what burns, in place of the photo, white on black as strongly as
    /// it burns.
    @ViewBuilder private var burnOverlay: some View {
        if model.isAdjustingBurn, let mask = model.burnMask {
            Image(decorative: mask, scale: 1)
                .resizable()
                .background(.black)
                .allowsHitTesting(false)
        }
    }

    /// What VoiceOver reads for the photo: its name and what it shows.
    private var photoDescription: String {
        let name = model.photo?.name ?? "Photo"
        if model.showsOriginal, model.original != nil {
            return "\(name), the original"
        }
        return model.showsFilm ? "\(name) on \(model.filmName)" : "\(name) on \(model.filmName), printed on \(model.paperName)"
    }

    /// The photo's size scaled to fit `size`, with a margin: the photo's own shape, whichever
    /// render is shown, so swapping renders can't move it.
    private func fittedSize(in size: CGSize) -> CGSize {
        let shown = shownSize
        guard shown.width > 0, shown.height > 0 else { return .zero }
        let inset: CGFloat = model.isCropping ? 28 : 12
        let scale = max(0, min((size.width - 2 * inset) / shown.width, (size.height - 2 * inset) / shown.height))
        return CGSize(width: shown.width * scale, height: shown.height * scale)
    }

    /// The framing the canvas shows: all of the turned photo while cropping.
    private var shownFraming: Framing {
        var framing = model.framing
        if model.isCropping {
            framing.crop = Framing.whole
        }
        return framing
    }

    /// The photo's size in its pixels as the canvas frames it.
    private var shownSize: CGSize { shownFraming.croppedSize(of: model.photoSize) }

    /// `content`, the whole photo, turned, straightened and cropped as the canvas frames it, at `size`.
    private func framed(_ content: some View, size: CGSize) -> some View {
        let framing = shownFraming
        let photoSize = model.photoSize
        let turned = framing.turnedSize(of: photoSize)
        // Points per photo pixel.
        let scale = turned.width > 0 ? size.width / (framing.crop.width * turned.width) : 0
        return content
            .frame(width: photoSize.width * scale, height: photoSize.height * scale)
            .rotationEffect(.degrees(Double(framing.quarterTurns) * 90 + framing.straighten))
            .scaleEffect(framing.straightenScale(for: turned))
            .frame(width: turned.width * scale, height: turned.height * scale)
            .offset(x: (0.5 - framing.crop.midX) * turned.width * scale, y: (0.5 - framing.crop.midY) * turned.height * scale)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// The long side the whole photo renders at so what the canvas shows of it fills its screen
    /// pixels: more than the fitted size where it's cropped or straightened.
    private var fittedLongSide: Int {
        let fitted = fittedSize(in: visibleSize)
        let shown = shownSize, photoSize = model.photoSize
        let framing = shownFraming
        let longSide = max(fitted.width, fitted.height) * displayScale
        guard shown.width > 0 else { return Int(longSide.rounded(.up)) }
        let whole = longSide * max(photoSize.width, photoSize.height) / max(shown.width, shown.height)
            * framing.straightenScale(for: framing.turnedSize(of: photoSize))
        return Int(min(whole, max(photoSize.width, photoSize.height)).rounded(.up))
    }

    /// The most the photo zooms: 4 points per photo pixel.
    private var maxZoom: CGFloat {
        let fitted = fittedSize(in: visibleSize)
        guard model.photo != nil, fitted.width > 0 else { return 1 }
        return max(1, 4 * shownSize.width / fitted.width)
    }

    /// Zooms by `factor`, keeping the photo's point under `anchor` (canvas coordinates) where it
    /// is: from all of the photo to ``maxZoom``.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        guard fittedSize(in: visibleSize).width > 0 else { return }
        let newZoom = min(max(zoom * factor, 1), maxZoom)
        let applied = newZoom / zoom
        // The anchor's distance from the photo's centre scales with the zoom.
        let fromCentre = CGSize(width: anchor.x - visibleCentre.x, height: anchor.y - visibleCentre.y)
        zoom = newZoom
        offset = clamped(CGSize(width: fromCentre.width - (fromCentre.width - offset.width) * applied,
                                height: fromCentre.height - (fromCentre.height - offset.height) * applied))
    }

    /// `offset` limited so the zoomed photo fills the canvas below the toolbar and beside the panel
    /// where it's larger, and stays centred there where it's smaller.
    private func clamped(_ offset: CGSize) -> CGSize {
        let fitted = fittedSize(in: visibleSize)
        let slack = CGSize(width: max(0, (fitted.width * zoom - visibleSize.width) / 2),
                           height: max(0, (fitted.height * zoom - visibleSize.height) / 2))
        return CGSize(width: min(max(offset.width, -slack.width), slack.width),
                      height: min(max(offset.height, -slack.height), slack.height))
    }
}

// MARK: - Log

struct LogView: View {
    /// How much SpektraMac worked the Mac over one second (``LogView/sampleUsage()``).
    struct Usage: Identifiable {
        var id: Date { time }
        let time: Date
        /// The app's processor time, as a share of all the cores' time.
        let cpu: Double
        /// The GPU time of the engine's own command buffers, as a share of the second.
        let gpu: Double
    }

    @Environment(PhotoModel.self) private var model
    /// The last minute's, while the window is open.
    @State private var usage: [Usage] = []

    var body: some View {
        VStack(spacing: 0) {
            usageGraph
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.log) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.time, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
        }
        .task { await sampleUsage() }
    }

    /// The CPU and GPU use over the last minute, as lines; one element for VoiceOver, which reads
    /// the last second's.
    private var usageGraph: some View {
        let end = usage.last?.time ?? .now
        let percent = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))
        return Chart(usage) { second in
            LineMark(x: .value("Time", second.time), y: .value("Use", second.cpu))
                .foregroundStyle(by: .value("Processor", "CPU"))
            LineMark(x: .value("Time", second.time), y: .value("Use", second.gpu))
                .foregroundStyle(by: .value("Processor", "GPU"))
        }
        .chartXScale(domain: end.addingTimeInterval(-60)...end)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1]) {
                AxisGridLine()
                AxisValueLabel(format: percent)
            }
        }
        .frame(height: 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU and GPU use over the last minute")
        .accessibilityValue(usage.last.map { "CPU \($0.cpu.formatted(percent)), GPU \($0.gpu.formatted(percent))" } ?? "")
    }

    /// Adds a second's use to ``usage`` each second until the window closes, keeping a minute's.
    /// The CPU's is the process's processor time on all its threads (`CLOCK_PROCESS_CPUTIME_ID`);
    /// the GPU's, the engine's command buffers' (``PhotoModel/gpuSeconds``), as macOS has no
    /// public figure for one app's GPU use.
    private func sampleUsage() async {
        func cpuSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e9 }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        var last = (time: ContinuousClock.now, cpu: cpuSeconds(), gpu: model.gpuSeconds)
        while true {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let now = (time: ContinuousClock.now, cpu: cpuSeconds(), gpu: model.gpuSeconds)
            let seconds = (now.time - last.time) / .seconds(1)
            usage.append(Usage(time: .now, cpu: (now.cpu - last.cpu) / seconds / cores, gpu: (now.gpu - last.gpu) / seconds))
            let minuteAgo = Date.now.addingTimeInterval(-60)
            usage.removeAll { $0.time < minuteAgo }
            last = now
        }
    }
}
