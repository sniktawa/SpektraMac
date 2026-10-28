import AppKit
import CoreTransferable
import Foundation
import ImageIO
import Observation
import SpektraEngine
import UniformTypeIdentifiers
import os

@MainActor
@Observable
final class PhotoModel {
    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
    }

    /// The open photo (on the engine's GPU): its file name, size and preview size, and what the
    /// metering marks found in it.
    struct Photo: Identifiable {
        let id = UUID()
        /// The file it was opened from, which the library knows it by.
        let url: URL
        let name: String
        let width: Int
        let height: Int
        let previewWidth: Int
        let previewHeight: Int
        let metering: MeteringReadings
        /// The region each mark meters, white with the weight as alpha.
        let meteringOverlays: [MeteringMark: CGImage]
    }
    /// A new photo empties the kept renders and the strips, and renders at once, showing its edit.
    private(set) var photo: Photo? {
        didSet {
            finishedRenders.removeAllObjects()
            strips = [:]
            stripControls = nil
            original = nil
            showsOriginal = false
            lastFinishedRender = nil
            cropAspect = .free
            scheduleRender()
        }
    }
    /// The open photo as macOS shows it, upright and at full size (``loadOriginal(of:)``): what a
    /// click on the canvas shows in place of the edit.
    private(set) var original: CGImage?
    /// The canvas shows ``original`` in place of the edit, and the settings are greyed out.
    var showsOriginal = false
    /// The photo's EXIF, GPS and IPTC records, for saved renderings.
    @ObservationIgnored private var metadata: PhotoMetadata?
    /// What the sidebar and the Print | Film switch set; every change re-renders the preview, and
    /// can be undone (``registerUndo(from:)``), a drag or a menu's choice in one step.
    var controls = Controls() {
        didSet {
            showsFilm = controls.scanFilm
            framing = controls.framing
            isSlideFilm = films.first { $0.stock == controls.film }?.type == .positive
            // The framing is the canvas's to show, not the engine's to render: the thumbnail follows it.
            if controls.unframed != oldValue.unframed {
                scheduleRender()
            } else if controls.framing != oldValue.framing {
                scheduleFramedThumbnail()
            }
            if controlsBeforeChange == nil && controls != oldValue {
                registerUndo(from: oldValue)
            }
            if controls != oldValue, !isApplyingPhotoControls, let photo {
                onControlsChanged?(photo.url, controls)
            }
        }
    }
    /// Told the open photo's new controls at each change, so the library keeps each photo's own.
    @ObservationIgnored var onControlsChanged: ((URL, Controls) -> Void)?
    /// While a photo's own settings, or the app's last ones, are applied: not a change to report.
    @ObservationIgnored private var isApplyingPhotoControls = false
    /// Told each finished screen-size render of the open photo, for the library's thumbnails.
    @ObservationIgnored var onFinishedRender: ((URL, CGImage) -> Void)?
    /// The open photo's last finished screen-size render, unframed: framed again for the thumbnail
    /// when only the framing changes.
    @ObservationIgnored private var lastFinishedRender: CGImage?
    @ObservationIgnored private var framedThumbnailTask: Task<Void, Never>?
    /// What the toolbar's Print | Film switch shows, as the controls have it: apart from them, so
    /// the switch isn't laid out again at every step of a slider (setting an observed property to
    /// the value it has notifies no one).
    private(set) var showsFilm = false
    /// How the canvas frames the photo, as the controls have it: apart from them for the same reason.
    private(set) var framing = Framing()
    /// A slide is viewed, never printed: every paper is negative-working, so a printed slide
    /// comes out as a negative image.
    private(set) var isSlideFilm = false
    /// The film. Choosing one applies the defaults made for it, if any; otherwise it picks the
    /// paper the film is meant to be printed on and, as Spektrafilm's GUI does, views slides
    /// directly instead of printing them, keeping the other controls.
    var film: String {
        get { controls.film }
        set { controls = controls(choosing: newValue) }
    }
    /// What choosing `film` sets the controls to (``film``).
    func controls(choosing film: String) -> Controls {
        var chosen = savedDefaults(for: film) ?? controls.choosing(film: film, from: films)
        chosen.framing = controls.framing
        return chosen
    }
    var filmName: String { filmName(of: controls) }
    func filmName(of controls: Controls) -> String { films.first { $0.stock == controls.film }?.name ?? controls.film }
    var paperName: String { papers.first { $0.stock == controls.paper }?.name ?? controls.paper }
    var films: [ProfileInfo] { engine?.films ?? [] }
    var papers: [ProfileInfo] { engine?.papers ?? [] }
    /// The exposure the slider shows, in stops over the photo as shot (``Controls/exposureEV(readings:)``).
    /// Set near a mark, it lands on the mark (``Controls/settingExposure(_:readings:)``).
    var exposureEV: Double {
        get { photo.map { controls.exposureEV(readings: $0.metering) } ?? controls.exposureOffsetEV }
        set {
            guard let photo else { return }
            controls = controls.settingExposure(newValue, readings: photo.metering)
        }
    }
    /// The exposure's range (``Controls/exposureRange(readings:)``).
    var exposureRange: ClosedRange<Double> {
        Controls.exposureRange(readings: photo?.metering)
    }
    /// The marks the exposure is on: those whose reading for this photo rounds to it.
    var marksAtExposure: [MeteringMark] {
        guard let photo else { return [] }
        let exposure = exposureEV
        return MeteringMark.allCases.filter { mark in
            photo.metering.ev[mark.rawValue].map { abs($0 - exposure) < 0.05 } ?? false
        }
    }
    /// While the Exposure slider is held: the canvas then tints the region the mark it's on meters.
    var isAdjustingExposure = false
    /// While a Burn slider is held: the canvas then shows what burns (``burnMask``).
    var isAdjustingBurn = false {
        didSet {
            guard isAdjustingBurn != oldValue else { return }
            if isAdjustingBurn {
                updateBurnMask()
            } else {
                burnMask = nil
            }
        }
    }
    /// Where the burn falls on the preview while a Burn slider is held (``Engine/burnMask(controls:)``).
    private(set) var burnMask: CGImage?
    /// While a slider is held: its next step would cancel the blurs and grain, so they render
    /// once it's let go.
    var isAdjusting = false {
        didSet {
            guard isAdjusting != oldValue else { return }
            if isAdjusting {
                beginChange()
            } else {
                endChange()
                if awaitsRelease {
                    render(from: .reduced)
                }
            }
        }
    }
    /// The preview is on screen, and the blurs and grain wait for the slider to be let go.
    private var awaitsRelease = false
    /// Display-sized rendering of the last simulation.
    private(set) var displayImage: CGImage?
    /// The Print tab's tone graph and the controls it was made for, with each preview.
    private(set) var toneGraph: (graph: ToneGraph, controls: Controls)?
    /// The render `displayImage` comes from.
    private(set) var shownMode: RenderMode?
    /// The photo's long side fitted on the canvas, in screen pixels: what renders are reduced to
    /// until the canvas may show more. A new size renders a reduced render on screen again, or one
    /// still rendering at the old size.
    var canvasLongSide = 0 {
        didSet {
            let rendersReduced = isRendering && !isRenderingFullResolution
            if canvasLongSide != oldValue && (awaitsFullResolution || rendersReduced) {
                render(from: .resized)
            }
        }
    }
    /// Whether the canvas shows the photo larger than it fits: it's zoomed in. Only then does the
    /// whole photo render, if it's larger than the canvas shows it. Until it's on screen, the
    /// zoomed photo is the screen-size render enlarged: about 0.3 s at 12 MP, 0.5–0.9 s at 24 MP
    /// on an M1 Pro.
    var wantsFullResolution = false {
        didSet {
            if wantsFullResolution && awaitsFullResolution {
                render(from: .full)
            }
        }
    }
    /// The reduced render is on screen and the controls haven't changed since.
    private var awaitsFullResolution = false
    /// A preview is rendering: a change meanwhile waits for it to show, then renders.
    private var isPreviewing = false
    private(set) var isLoading = false
    /// A render with the blurs and grain is running. Not a preview: at each step of a slider,
    /// "Rendering…" would flicker under the window's title, laying out the toolbar each time.
    private(set) var isRendering = false
    private(set) var isRenderingFullResolution = false
    /// What saving is doing, while it runs.
    private(set) var savePhase: String?
    private(set) var errorMessage: String?
    /// Something the user asked for that failed (opening, saving, exporting, presets), for the
    /// window's alert, until it's dismissed.
    struct Failure {
        let title: String
        let message: String
    }
    var failure: Failure?
    /// Why there's no engine: Metal is unavailable. The empty canvas says so.
    private(set) var engineFailure: String?
    private(set) var log: [LogEntry] = []
    /// Drives the Open Preset panel (`fileImporter`); its menu item sets it.
    var isImportingPreset = false

    /// Made in the background as the app starts, so the window shows at once: about 0.1 s,
    /// 0.5 s on the first launch after a build, as Metal compiles the shaders. The Film and Paper
    /// menus fill, and photos open, once it's here.
    private var engine: Engine?
    /// The GPU time of the engine's own work so far, in seconds, for the Log's graph.
    var gpuSeconds: Double { engine?.gpuTime.seconds ?? 0 }
    /// The engine being made, which opening a photo waits for: one dropped as the app starts opens
    /// once it's here.
    private let makingEngine: Task<Engine, any Error>
    private let logger = Logger(subsystem: "nainajnahO.SpektraMac", category: "model")
    private var renderTask: Task<Void, Never>?
    /// Finished renders at the canvas's size for the open photo, by the controls they show: going
    /// back to controls shown before (hovering back to a stock, a slider back at a value) shows
    /// them at once, as do the choices a menu renders ahead (``preload(_:)``). Not
    /// full-resolution ones (96 MB at 24 MP). `NSCache` drops the oldest past
    /// 512 MB, and all of them when memory runs low.
    private let finishedRenders: NSCache<RenderKey, CGImage> = {
        let cache = NSCache<RenderKey, CGImage>()
        cache.totalCostLimit = 512 << 20
        return cache
    }()
    private var renderScheduled = false
    private var saveTask: Task<Void, Never>?

    init() {
        let making = Task.detached(priority: .userInitiated) { try Engine() }
        makingEngine = making
        Task {
            do {
                engine = try await making.value
            } catch {
                engineFailure = error.localizedDescription
                note("⚠️ Metal is unavailable: \(error.localizedDescription)")
                return
            }
            // The settings the app quit with, else the starting film's saved defaults, as choosing it
            // applies them: the reset buttons go back to them. Once the films are here, to check them
            // against, and so the Print | Film switch knows a slide.
            if let start = lastSettings() ?? savedDefaults(for: controls.film) {
                // Where the app starts, not an edit to undo.
                undoManager?.disableUndoRegistration()
                isApplyingPhotoControls = true
                controls = start
                isApplyingPhotoControls = false
                undoManager?.enableUndoRegistration()
            }
            // On the engine's queue, so the first photo opened doesn't wait for it.
            do {
                try await engine?.loadVision()
            } catch {
                fail("Could not load Vision", error)
            }
        }
    }

    // MARK: Opening

    /// How many opens have started: the newest one's photo is the one that shows (``open(_:)``).
    @ObservationIgnored private var opensStarted = 0
    /// The photos opened lately, newest first, for File › Open Recent: AppKit's list of recent
    /// documents, which keeps them between launches, with access to them, and fills the Dock
    /// icon's menu.
    private(set) var recentPhotos = NSDocumentController.shared.recentDocumentURLs

    func clearRecentPhotos() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentPhotos = []
    }

    /// Opens the photo at `url`. Photos chosen while others open show in the order chosen: an
    /// earlier one still decoding is dropped (a 16-bit TIFF can take seconds, a JPEG chosen after it
    /// a moment), and one the engine is already opening shows until the later one replaces it.
    /// "Opening…" stays until the newest is done. An opened photo goes to the top of
    /// ``recentPhotos``.
    func open(_ url: URL, controls photoControls: Controls? = nil, placeholder: CGImage? = nil,
              preloading neighbours: [URL] = []) {
        // Files from the Open panel and Open Recent are security-scoped; dropped files and those
        // sent by Finder or the Dock are already accessible.
        let scoped = url.startAccessingSecurityScopedResource()
        opensStarted += 1
        let generation = opensStarted
        isLoading = true
        errorMessage = nil
        // The library's thumbnail until the photo renders, rather than the last photo.
        if let placeholder {
            stopRendering()
            displayImage = placeholder
        }
        // Read before the neighbours are dropped, so stepping back and forth reuses them.
        let preloaded = decodedPhotos[url] != nil
        let decoding = decodedPhotos[url] ?? Self.decoding(url)
        // This photo's too, so stepping back to it doesn't read it again.
        decodedPhotos = decodedPhotos.filter { neighbours.contains($0.key) || $0.key == url }
        decodedPhotos[url] = decoding
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            defer {
                if generation == opensStarted {
                    isLoading = false
                }
            }
            let start = ContinuousClock.now
            do {
                let engine = try await makingEngine.value
                let (image, metadata) = try await decoding.value
                guard generation == opensStarted else { return }
                // The engine opens the photo once it's done rendering the last one: stop that.
                stopRendering()
                stripTask?.cancel()
                stripTask = nil
                stopPreloading()
                let opened: Engine.OpenedPhoto
                do {
                    opened = try await engine.open(image)
                } catch {
                    // The engine keeps the open photo: its renders, stopped above, start again.
                    scheduleRender()
                    throw error
                }
                self.metadata = metadata
                // The photo's own settings, if the library has them (or what an unedited one starts
                // with); otherwise the last ones carry over. Undo stays with the photo it was done on.
                undoManager?.removeAllActions()
                if let photoControls, knowsStocks(of: photoControls) {
                    undoManager?.disableUndoRegistration()
                    isApplyingPhotoControls = true
                    controls = checked(photoControls)
                    isApplyingPhotoControls = false
                    undoManager?.enableUndoRegistration()
                }
                photo = Photo(url: url, name: url.lastPathComponent, width: opened.width, height: opened.height,
                              previewWidth: opened.previewWidth, previewHeight: opened.previewHeight,
                              metering: opened.metering, meteringOverlays: opened.meteringOverlays)
                let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
                note("Opened \(url.lastPathComponent) (\(opened.width) × \(opened.height)) in \(elapsed)\(preloaded ? ", preloaded" : "")")
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                recentPhotos = NSDocumentController.shared.recentDocumentURLs
                preload(neighbours)
                // After the next photo, so stepping on quickly doesn't wait on reading this one again.
                loadOriginal(of: url, after: neighbours.first.flatMap { decodedPhotos[$0] })
            } catch {
                // Read again next time: the drive may be back.
                decodedPhotos[url] = nil
                // A photo chosen since says how it went instead.
                guard generation == opensStarted else { return }
                fail("Couldn't open “\(url.lastPathComponent)”", error, alert: true)
            }
        }
    }

    /// Photos decoded ahead of being opened (``preload(_:)``), and the one being opened.
    @ObservationIgnored private var decodedPhotos: [URL: Task<(CIImage, PhotoMetadata?), Error>] = [:]

    /// Decodes `url` in the background, after `previous` if given: the slow part of opening a large
    /// TIFF from a network drive. At the priority of opening a photo, as each is one the user is
    /// about to step to (a lower one took several times as long).
    private static func decoding(_ url: URL, after previous: Task<(CIImage, PhotoMetadata?), Error>? = nil)
        -> Task<(CIImage, PhotoMetadata?), Error> {
        Task.detached(priority: .userInitiated) {
            _ = try? await previous?.value
            return (try RGBImage.decode(contentsOf: url), PhotoMetadata(contentsOf: url))
        }
    }

    /// Starts decoding the photos next to the one just opened, one after the other in the order
    /// given, so stepping to one opens it without reading its file. Keeps only these and the open one.
    private func preload(_ neighbours: [URL]) {
        let open = photo?.url
        decodedPhotos = decodedPhotos.filter { neighbours.contains($0.key) || $0.key == open }
        var previous: Task<(CIImage, PhotoMetadata?), Error>?
        for url in neighbours where decodedPhotos[url] == nil {
            let task = Self.decoding(url, after: previous)
            decodedPhotos[url] = task
            previous = task
        }
    }

    /// Reads `url` into ``original`` for the photo just opened, unless another opens meanwhile:
    /// after the photo shows, so it opens no later for it (0.05–0.45 s for 12–24 MP JPEG, HEIC and
    /// DNG files on an M1 Pro).
    private func loadOriginal(of url: URL, after preloading: Task<(CIImage, PhotoMetadata?), Error>? = nil) {
        let id = photo?.id
        // Files from the Open panel are security-scoped, and the opening task stops its access.
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            _ = try? await preloading?.value
            guard photo?.id == id else { return }
            do {
                let image = try await Task.detached(priority: .utility) { try Self.decodeOriginal(contentsOf: url) }.value
                if photo?.id == id {
                    original = image
                }
            } catch {
                fail("Could not read the original of \(url.lastPathComponent)", error)
            }
        }
    }

    /// `url` as macOS shows it, upright and at full size: ImageIO's decoding, as Preview's, so a
    /// RAW file has its default look rather than the engine's linear development.
    nonisolated private static func decodeOriginal(contentsOf url: URL) throws -> CGImage {
        // A thumbnail made from the image with no size limit: ImageIO's way to have it upright.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        return image
    }

    func importFailed(_ error: Error) {
        fail("Couldn't open the file", error, alert: true)
    }

    // MARK: Rendering

    /// How long the canvas's size stays still before the photo renders at it: a window being
    /// resized changes it at every frame.
    private static let resizeDelay = Duration.milliseconds(500)

    /// Renders once per main-actor turn, however many settings changed in it.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            renderScheduled = false
            render()
        }
    }

    /// Where a render starts: a change to the controls at the quick preview, a slider let go at the
    /// reduced render, a new canvas size there once it has been still for `resizeDelay`,
    /// ``wantsFullResolution`` at the whole photo.
    private enum RenderStart { case preview, reduced, resized, full }

    /// Renders the preview, then with the blurs and grain the preview leaves out, once the slider
    /// is let go if one is held (``isAdjusting``): at the size the canvas shows the photo, and the
    /// whole photo once ``wantsFullResolution``, or at once where the canvas shows it no smaller.
    /// A change cancels it, except a preview, which shows and then renders the newest controls.
    /// Controls with a kept finished render (``finishedRenders``) show it instead, at once.
    private func render(from start: RenderStart = .preview) {
        // A preview in flight shows, then renders the newest controls: cancelling it at each step
        // of a slider would leave none on screen until the slider pauses.
        guard start != .preview || !isPreviewing else { return }
        stopRendering()
        if start == .preview {
            stripTask?.cancel()
            stripTask = nil
        }
        guard let photo, let engine else {
            displayImage = nil
            return
        }
        isRendering = start == .reduced || start == .full
        isPreviewing = start == .preview
        renderTask = Task {
            var controls = self.controls.unframed
            do {
                // Whether a kept finished render is on screen.
                var isFinished = false
                if start == .preview {
                    repeat {
                        controls = self.controls.unframed
                        isFinished = showKept(controls, photo: photo)
                        if !isFinished {
                            try await show(controls: controls, mode: .preview, engine: engine, photo: photo)
                        }
                        // With each preview, so the graph follows a slider or its own handles as
                        // they move.
                        toneGraph = (try await engine.toneGraph(controls: controls), controls)
                    } while controls != self.controls.unframed
                    isPreviewing = false
                    if isAdjusting && !isFinished {
                        awaitsRelease = true
                        return
                    }
                }
                if start == .resized {
                    try await Task.sleep(for: Self.resizeDelay)
                }
                // The canvas's size once things are still.
                let longSide = reducedLongSide(of: photo)
                let reduces = start != .full && longSide < max(photo.width, photo.height)
                if reduces && !isFinished {
                    isRendering = true
                    try await show(controls: controls, mode: .reduced(longSide: longSide), engine: engine, photo: photo)
                }
                if reduces && !wantsFullResolution {
                    awaitsFullResolution = true
                } else {
                    isRendering = true
                    isRenderingFullResolution = true
                    try await show(controls: controls, mode: .full, engine: engine, photo: photo)
                }
                renderStrips(photo: photo, engine: engine)
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render", error)
            }
            isPreviewing = false
            isRendering = false
            isRenderingFullResolution = false
        }
    }

    /// Stops the render under way, and what waits on one: a slider's release, or zooming in for the
    /// whole photo.
    private func stopRendering() {
        renderTask?.cancel()
        isPreviewing = false
        isRendering = false
        isRenderingFullResolution = false
        awaitsFullResolution = false
        awaitsRelease = false
    }

    /// The long side renders are reduced to: the canvas's (the preview's before it has a size).
    private func reducedLongSide(of photo: Photo) -> Int {
        canvasLongSide > 0 ? canvasLongSide : max(photo.previewWidth, photo.previewHeight)
    }

    /// Puts the kept finished render of `controls` on screen, if there is one.
    private func showKept(_ controls: Controls, photo: Photo) -> Bool {
        let longSide = reducedLongSide(of: photo)
        guard let image = finishedRenders.object(forKey: RenderKey(controls: controls, longSide: longSide)) else {
            return false
        }
        displayImage = image
        shownMode = .reduced(longSide: longSide)
        note("Showed the kept screen size (\(image.width) × \(image.height))")
        return true
    }

    /// Renders the photo and puts it on screen, unless a newer change has made it stale.
    private func show(controls: Controls, mode: RenderMode, engine: Engine, photo: Photo) async throws {
        let start = ContinuousClock.now
        let display = try await engine.display(controls: controls, mode: mode)
        try Task.checkCancellation()
        displayImage = display
        shownMode = mode
        if mode == .preview && isAdjustingBurn {
            burnMask = try await engine.burnMask(controls: controls)
        }
        if case .reduced(let longSide) = mode {
            finishedRenders.setObject(display, forKey: RenderKey(controls: controls, longSide: longSide),
                                      cost: display.bytesPerRow * display.height)
            lastFinishedRender = display
            onFinishedRender?(photo.url, self.controls.framing.apply(to: display))
        }
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
        let size = mode == .full ? "\(photo.width) × \(photo.height)" : "\(display.width) × \(display.height)"
        let name = switch mode {
        case .preview: "preview"
        case .thumbnail: "thumbnail"
        case .reduced: "screen size"
        case .full, .export: "full resolution"
        }
        note("Rendered \(name) (\(size)) in \(elapsed)")
    }

    /// Shows what burns as a Burn slider is taken hold of, before it moves (the previews it renders
    /// then show it from ``show(controls:mode:engine:photo:)``).
    private func updateBurnMask() {
        guard let engine, photo != nil else { return }
        let controls = controls
        Task {
            do {
                let mask = try await engine.burnMask(controls: controls)
                if isAdjustingBurn {
                    burnMask = mask
                }
            } catch {
                fail("Could not show what burns", error)
            }
        }
    }

    /// What a kept render shows: `NSCache` wants an object key.
    private nonisolated final class RenderKey: NSObject {
        let controls: Controls
        let longSide: Int

        init(controls: Controls, longSide: Int) {
            (self.controls, self.longSide) = (controls.unframed, longSide)
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? RenderKey else { return false }
            return controls == other.controls && longSide == other.longSide
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(controls)
            hasher.combine(longSide)
            return hasher.finalize()
        }
    }

    // MARK: Thumbnail strips

    /// Each strip (``Controls/Strip``) has this many frames, rendered in preview mode on a small
    /// image of the photo (``RenderMode/thumbnail``). Halation, grain and glare barely show at that
    /// size, so they have none.
    static let framesPerStrip = 5
    /// Each strip's frames, left to right. A strip whose control changes nothing the controls show
    /// (a print setting while the film shows, say) has none.
    private(set) var strips: [Controls.Strip: [CGImage]] = [:]
    /// The controls the strips were made for.
    @ObservationIgnored private var stripControls: Controls?
    /// Makes the strips for the controls; a change to them stops it (``render(from:)``).
    @ObservationIgnored private var stripTask: Task<Void, Never>?

    /// The range a strip's control spans.
    func range(of strip: Controls.Strip) -> ClosedRange<Double> {
        switch strip {
        case .exposure: exposureRange
        case .couplerSaturation: Controls.range(\.couplerSaturation)
        case .printExposure: Controls.range(\.printExposure)
        }
    }

    /// Renders the strips for the controls, unless they show them or are being made for them. Each
    /// frame is a render of its own, so a change's preview waits on one frame at most; each strip
    /// shows once all its frames are done.
    private func renderStrips(photo: Photo, engine: Engine) {
        let controls = controls.unframed
        guard controls != stripControls, stripTask == nil else { return }
        stripTask = Task {
            let start = ContinuousClock.now
            var count = 0
            do {
                for strip in Controls.Strip.allCases {
                    guard strip.applies(to: controls) else {
                        strips[strip] = nil
                        continue
                    }
                    let span = range(of: strip)
                    var frames: [CGImage] = []
                    for frame in 0..<Self.framesPerStrip {
                        // The value at the middle of the frame.
                        let value = span.lowerBound
                            + (Double(frame) + 0.5) / Double(Self.framesPerStrip) * (span.upperBound - span.lowerBound)
                        frames.append(try await engine.display(
                            controls: controls.setting(strip, to: value, readings: photo.metering), mode: .thumbnail))
                        try Task.checkCancellation()
                    }
                    strips[strip] = frames
                    count += frames.count
                }
                stripControls = controls
                stripTask = nil
                let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
                note("Rendered \(count) thumbnails in \(elapsed)")
            } catch {
                guard !Task.isCancelled else { return }
                stripTask = nil
                fail("Could not render the thumbnails", error)
            }
        }
    }

    // MARK: Choices rendered ahead

    /// Renders what a menu offers, while it's open (``preload(_:)``).
    @ObservationIgnored private var preloadTask: Task<Void, Never>?

    /// Renders each of `choices` (what choosing each stock or filter of a menu sets the controls
    /// to, in order) with every effect at the canvas's size into the kept renders, so the menu
    /// shows a choice finished the moment the pointer is on it (``showKept(_:photo:)``). One render
    /// at a time, as the strips are made: a choice the pointer reaches before its turn waits on one
    /// render at most. As many as fill half the kept renders' memory, so they can't push each
    /// other out.
    func preload(_ choices: [Controls]) {
        stopPreloading()
        guard let photo, let engine else { return }
        let longSide = reducedLongSide(of: photo)
        let scale = min(1, Double(longSide) / Double(max(photo.width, photo.height)))
        // At least 1 px a side, as renders are: a canvas narrowed to a sliver fits a panorama 0 px tall.
        let bytes = max(1, Int(Double(photo.width) * scale)) * max(1, Int(Double(photo.height) * scale)) * 4
        let keys = choices.prefix(finishedRenders.totalCostLimit / 2 / bytes)
            .map { RenderKey(controls: $0, longSide: longSide) }
        preloadTask = Task {
            let start = ContinuousClock.now
            var count = 0
            do {
                for key in keys where finishedRenders.object(forKey: key) == nil {
                    let display = try await engine.display(controls: key.controls, mode: .reduced(longSide: longSide))
                    try Task.checkCancellation()
                    finishedRenders.setObject(display, forKey: key, cost: display.bytesPerRow * display.height)
                    count += 1
                }
                if count > 0 {
                    let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
                    note("Rendered \(count) choices ahead in \(elapsed)")
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render the choices ahead", error)
            }
        }
    }

    /// Stops ``preload(_:)``; what it has rendered stays kept.
    func stopPreloading() {
        preloadTask?.cancel()
        preloadTask = nil
    }

    // MARK: Saving and cancelling

    var canSave: Bool { photo != nil && engine != nil && savePhase == nil }
    var canCancel: Bool { savePhase != nil }

    /// Shows `panel` as a sheet on the key window (the photo's, unless the Log is in front), or on
    /// its own if no window is, and gives the place chosen.
    private func destination(from panel: NSSavePanel) async -> URL? {
        let response = if let window = NSApp.keyWindow {
            await panel.beginSheetModal(for: window)
        } else {
            await panel.begin()
        }
        return response == .OK ? panel.url : nil
    }

    /// Renders the photo at full resolution, encoded in Display P3, and writes it where the Save panel says:
    /// 16-bit TIFF or PNG, or JPEG, as its format menu sets the name's extension. The suggested name
    /// has the film in it, so saving can't replace a JPEG original by accident.
    func save() {
        guard let photo, let engine else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .tiff, .png]
        panel.showsContentTypes = true
        panel.nameFieldStringValue = "\((photo.name as NSString).deletingPathExtension) – \(filmName).jpg"
        panel.canCreateDirectories = true
        Task {
            guard let url = await destination(from: panel) else { return }
            let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
            let (controls, metadata, record) = (controls, metadata, editRecord)
            savePhase = "Rendering \(url.lastPathComponent) at full resolution…"
            saveTask = Task {
                defer { savePhase = nil; saveTask = nil }
                let start = ContinuousClock.now
                do {
                    let image = try await Self.framed(engine.export(controls: controls, as: type), by: controls)
                    try Task.checkCancellation()
                    savePhase = "Writing \(url.lastPathComponent)…"
                    try await Task.detached(priority: .userInitiated) {
                        try image.write(to: url, as: type, metadata: metadata, record: record)
                    }.value
                    let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))
                    note("Saved \(url.lastPathComponent) in \(elapsed)")
                } catch is CancellationError {
                    note("Cancelled saving \(url.lastPathComponent)")
                } catch {
                    fail("Couldn't save “\(url.lastPathComponent)”", error, alert: true)
                }
            }
        }
    }

    /// A photo for ``exportPhotos(_:to:as:)``: its file, its settings and the name to save it as.
    struct ExportJob {
        let url: URL
        let controls: Controls
        let name: String
    }

    /// Renders each job at full resolution and writes it into `folder` as `type`, one at a time on
    /// the engine, which holds one photo: the open photo opens again after. Cancel stops it after
    /// the photo rendering. Returns how many were written.
    func exportPhotos(_ jobs: [ExportJob], to folder: URL, as type: UTType) async -> Int {
        guard let engine, savePhase == nil else { return 0 }
        let reopen = photo.map { ($0.url, controls) }
        stopRendering()
        stripTask?.cancel()
        stripTask = nil
        stopPreloading()
        var written = 0
        let task = Task {
            let folderScoped = folder.startAccessingSecurityScopedResource()
            defer { if folderScoped { folder.stopAccessingSecurityScopedResource() } }
            let ext = type.preferredFilenameExtension ?? "jpg"
            for (index, job) in jobs.enumerated() {
                if Task.isCancelled { break }
                savePhase = "Exporting \(index + 1) of \(jobs.count): \(job.name)…"
                let scoped = job.url.startAccessingSecurityScopedResource()
                defer { if scoped { job.url.stopAccessingSecurityScopedResource() } }
                do {
                    let (image, metadata) = try await Task.detached(priority: .userInitiated) {
                        (try RGBImage.decode(contentsOf: job.url), PhotoMetadata(contentsOf: job.url))
                    }.value
                    _ = try await engine.open(image)
                    let rendered = try await Self.framed(engine.export(controls: checked(job.controls), as: type),
                                                         by: job.controls)
                    let record = editRecord(for: job.controls)
                    let destination = Self.unusedURL(in: folder, name: job.name, extension: ext)
                    try await Task.detached(priority: .userInitiated) {
                        try rendered.write(to: destination, as: type, metadata: metadata, record: record)
                    }.value
                    written += 1
                    note("Exported \(destination.lastPathComponent)")
                } catch is CancellationError {
                    break
                } catch {
                    fail("Couldn't export “\(job.url.lastPathComponent)”", error)
                }
            }
        }
        saveTask = task
        await task.value
        savePhase = nil
        saveTask = nil
        if let (url, controls) = reopen {
            open(url, controls: controls)
        }
        return written
    }

    /// `image`, a full-resolution render, turned and cropped as `controls` frame it, off the main actor.
    private static func framed(_ image: CGImage, by controls: Controls) async -> CGImage {
        let framing = controls.framing.checked
        guard !framing.isIdentity else { return image }
        return await Task.detached(priority: .userInitiated) { framing.apply(to: image) }.value
    }

    /// `name.ext` in `folder`, or `name 2.ext` and so on if that's taken.
    nonisolated private static func unusedURL(in folder: URL, name: String, extension ext: String) -> URL {
        var candidate = folder.appending(path: "\(name).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(name) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Stops a save; the GPU stops at its next memory flush.
    func cancel() {
        saveTask?.cancel()
    }

    /// The finished photo, for Share and Copy, while a photo is open.
    var finishedPhoto: FinishedPhoto? {
        photo.map { FinishedPhoto(model: self, name: ($0.name as NSString).deletingPathExtension) }
    }

    /// The finished photo as a JPEG named `name`, as Save writes one, in a folder of its own in the
    /// temporary folder: what Share and Copy send (``FinishedPhoto``).
    func finishedFile(named name: String) async throws -> URL {
        let engine = try await makingEngine.value
        let (controls, metadata, record) = (controls, metadata, editRecord)
        let start = ContinuousClock.now
        let image = try await Self.framed(engine.export(controls: controls, as: .jpeg), by: controls)
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "\(name).jpg")
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.write(to: url, as: .jpeg, metadata: metadata, record: record)
        }.value
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))
        note("Rendered \(url.lastPathComponent) to share in \(elapsed)")
        return url
    }

    /// What a saved photo records of its edit: the film and paper (or the film, scanned), the
    /// exposure as the slider shows it and the adjustments switched on, by their sidebar names.
    private var editRecord: EditRecord { editRecord(for: controls) }

    private func editRecord(for controls: Controls) -> EditRecord {
        let filmName = films.first { $0.stock == controls.film }?.name ?? controls.film
        let paperName = papers.first { $0.stock == controls.paper }?.name ?? controls.paper
        func diffusion(_ filter: Parameters.DiffusionFilter.Family, _ strength: Double, on lens: String) -> String {
            "\(filter.name) \(strength.formatted(.number.precision(.fractionLength(0...3)))) on the \(lens)"
        }
        var summary = [controls.scanFilm ? "\(filmName), scanned" : "\(filmName) printed on \(paperName)"]
        if controls == self.controls {
            summary.append("\(exposureText) EV")
        }
        if controls.cameraDiffusion.active {
            summary.append(diffusion(controls.cameraDiffusion.filterFamily, controls.cameraDiffusion.strength, on: "lens"))
        }
        if controls.halation { summary.append("halation") }
        if controls.couplers { summary.append("couplers") }
        if controls.grain { summary.append("grain") }
        if !controls.scanFilm {
            if controls.burn { summary.append("burn") }
            if controls.enlargerDiffusion.active {
                summary.append(diffusion(controls.enlargerDiffusion.filterFamily, controls.enlargerDiffusion.strength,
                                         on: "enlarger"))
            }
            if controls.glare { summary.append("glare") }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return EditRecord(software: "SpektraMac \(version)", summary: summary.joined(separator: " · "),
                          keywords: (controls.scanFilm ? [filmName] : [filmName, paperName]) + ["SpektraMac"],
                          controls: controls)
    }

    /// The exposure as the slider shows it, signed, to a tenth of a stop.
    private var exposureText: String {
        exposureEV.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
    }

    // MARK: LUTs

    var canExportLUT: Bool { engine != nil }
    /// Spektrafilm's LUT tool's default size: trilinear interpolation between its entries is
    /// within ΔE2000 0.56 of exact (Portra 400 → Portra Endura), a 1 MB file.
    private static let lutSize = 33
    /// macOS declares no type for `.cube` files, so the Save panel gets a dynamic one.
    private static let cubeType = UTType(filenameExtension: "cube", conformingTo: .text)!

    /// Writes the controls' look as a `.cube` LUT for LightCraft, which applies one to its
    /// display-encoded sRGB, exposed as the exposure slider shows (``Engine/lut(controls:exposureEV:size:)``).
    /// Its title, the name LightCraft shows, is the file's.
    func exportLUT() {
        guard let engine else { return }
        let stops = exposureText
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.cubeType]
        panel.nameFieldStringValue = controls.scanFilm ? filmName : "\(filmName) – \(paperName)"
        panel.message = "The LUT carries this exposure (\(stops) EV) and every setting a LUT can hold. Grain, halation, glare, the burn, highlight boost and the sharper edges of the couplers' Edge contrast depend on neighbouring pixels or the whole photo, so they're left out."
        panel.canCreateDirectories = true
        Task {
            guard let url = await destination(from: panel) else { return }
            let (controls, exposureEV) = (controls, exposureEV)
            let comments = [
                "Made with SpektraMac from Spektrafilm by Andrea Volpato (https://github.com/andreavolpato/spektrafilm).",
                "Film and paper data: CC BY-SA 4.0.",
                controls.scanFilm ? "Film: \(filmName), scanned" : "Film: \(filmName), printed on \(paperName)",
                "Exposure: \(stops) EV",
                "Input and output: sRGB, encoded",
            ]
            do {
                let lut = try await engine.lut(controls: controls, exposureEV: exposureEV, size: Self.lutSize)
                try lut.cube(title: url.deletingPathExtension().lastPathComponent, comments: comments)
                    .write(to: url, options: .atomic)
                note("Exported LUT \(url.lastPathComponent) at \(stops) EV")
            } catch {
                fail("Couldn't export the LUT", error, alert: true)
            }
        }
    }

    // MARK: Presets

    var canUsePresets: Bool { engine != nil }

    func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(filmName).json"
        panel.canCreateDirectories = true
        Task {
            guard let url = await destination(from: panel) else { return }
            do {
                try controls.preset().write(to: url, options: .atomic)
                note("Saved preset \(url.lastPathComponent)")
            } catch {
                fail("Couldn't save the preset", error, alert: true)
            }
        }
    }

    func openPreset(_ url: URL) {
        // Files from the Open panel are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let preset = try Controls(preset: Data(contentsOf: url))
            guard knowsStocks(of: preset) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown film or paper (\(preset.film), \(preset.paper))",
                ])
            }
            actionName = "Open Preset"
            var opened = checked(preset, from: url.lastPathComponent)
            opened.framing = controls.framing
            controls = opened
            actionName = nil
            note("Opened preset \(url.lastPathComponent)")
        } catch {
            fail("Couldn't open the preset", error, alert: true)
        }
    }

    /// Whether `controls`' film and paper are among those the app has.
    private func knowsStocks(of controls: Controls) -> Bool {
        films.contains { $0.stock == controls.film } && papers.contains { $0.stock == controls.paper }
    }

    private static let lastSettingsKey = "lastSettings"

    /// Keeps the controls for the next launch, which starts with them (``lastSettings()``): the app
    /// calls it as it quits.
    func storeSettings() {
        do {
            try UserDefaults.standard.set(controls.preset(), forKey: Self.lastSettingsKey)
        } catch {
            logger.error("Could not keep the settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The settings the app last quit with, checked as a preset is; none if their film or paper is
    /// gone.
    private func lastSettings() -> Controls? {
        guard let preset = UserDefaults.standard.data(forKey: Self.lastSettingsKey) else { return nil }
        do {
            let settings = try Controls(preset: preset)
            return knowsStocks(of: settings) ? checked(settings, from: "the last settings") : nil
        } catch {
            fail("Ignored the last settings", error)
            return nil
        }
    }

    /// Makes the current controls what choosing this film applies from now on.
    func makeDefaultForFilm() {
        do {
            // Not the framing: it's this photo's.
            try UserDefaults.standard.set(controls.unframed.preset(), forKey: Self.defaultsKey(controls.film))
            note("Made these settings the default for \(filmName)")
        } catch {
            fail("Couldn't make these settings the default for \(filmName)", error, alert: true)
        }
    }

    /// Forgets the film's saved defaults and returns every control to the app's own.
    /// Undo brings the saved defaults back with the controls.
    func restoreFactoryDefaults() {
        setSavedDefaults(nil, for: controls.film)
        actionName = "Restore Factory Defaults"
        var factory = Controls().choosing(film: controls.film, from: films)
        factory.framing = controls.framing
        controls = factory
        actionName = nil
        // The defaults' undo, in the same step, has the name even if the controls were already these.
        undoManager?.setActionName("Restore Factory Defaults")
        note("Restored the factory defaults for \(filmName)")
    }

    /// Stores `preset` as `film`'s saved defaults, or forgets them for nil; Undo puts back what was.
    private func setSavedDefaults(_ preset: Data?, for film: String) {
        let key = Self.defaultsKey(film)
        let previous = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.set(preset, forKey: key)
        undoManager?.registerUndo(withTarget: self) { model in
            model.setSavedDefaults(previous, for: film)
        }
    }

    private static func defaultsKey(_ film: String) -> String { "filmDefaults.\(film)" }

    /// What a photo not edited yet opens with: the film and paper in use, and the rest from the
    /// film's saved defaults or the app's own, rather than the last photo's edit.
    func startingControls() -> Controls {
        var start = UserDefaults.standard.data(forKey: Self.defaultsKey(controls.film))
            .flatMap { try? Controls(preset: $0) } ?? Controls()
        start.film = controls.film
        start.paper = controls.paper
        start.scanFilm = controls.scanFilm
        start.framing = Framing()
        return checked(start)
    }

    private func savedDefaults(for film: String) -> Controls? {
        guard let preset = UserDefaults.standard.data(forKey: Self.defaultsKey(film)) else { return nil }
        do {
            return checked(try Controls(preset: preset), from: "the saved defaults for \(film)")
        } catch {
            fail("Ignored the saved defaults for \(film)", error)
            return nil
        }
    }

    /// `controls` read from a preset (or a film's saved defaults) made what the app can render
    /// (``Controls/checked(films:)``). Says in the log what it changed, if `source` names the preset.
    private func checked(_ controls: Controls, from source: String? = nil) -> Controls {
        var (checked, changed) = controls.checked(films: films)
        checked.framing = checked.framing.checked
        if let source, !changed.isEmpty {
            note("Changed \(changed.formatted(.list(type: .and))) from \(source) to what SpektraMac can render")
        }
        return checked
    }

    // MARK: Undo

    /// The window's undo manager, which Edit › Undo and Redo use (``ContentView`` sets it). Undo goes
    /// back through the settings whichever photo is open, as they carry over from one to the next.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The controls as a drag or an open menu found them: what they change undoes in one step once
    /// it ends (``endChange()``).
    @ObservationIgnored private var controlsBeforeChange: Controls?
    /// The next undo step's name, for a change named by what made it rather than what it changed.
    @ObservationIgnored private var actionName: String?

    /// Holds the changes to the controls a drag or an open menu makes, to undo in one step.
    func beginChange() {
        if controlsBeforeChange == nil {
            controlsBeforeChange = controls
        }
    }

    /// Ends what ``beginChange()`` began: if the controls changed, one undo step sets them back.
    func endChange() {
        guard let before = controlsBeforeChange else { return }
        controlsBeforeChange = nil
        if controls != before {
            registerUndo(from: before)
        }
    }

    /// Lets Undo set the controls back to `previous`, named after the settings group the change was
    /// in unless ``actionName`` names it. Undoing sets the controls, which registers Redo, as named.
    private func registerUndo(from previous: Controls) {
        guard let undoManager else { return }
        let name = actionName ?? Controls.groupName(changedFrom: previous, to: controls)
        undoManager.registerUndo(withTarget: self) { model in
            model.actionName = name
            model.controls = previous
            model.actionName = nil
        }
        undoManager.setActionName(name)
    }

    // MARK: Framing

    /// The Crop tab is open: the canvas shows the whole turned photo, the crop drawn over it.
    var isCropping = false
    /// The shape the crop is held to, and whether upright, so its long side is its height.
    private(set) var cropAspect = CropAspect.free
    private(set) var cropIsPortrait = false

    /// The open photo's size in pixels, as it was shot.
    var photoSize: CGSize { photo.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    /// Turns the photo a quarter, its crop with it, and the crop's shape.
    func rotate(clockwise: Bool) {
        controls.framing = controls.framing.turned(clockwise: clockwise)
        if cropAspect.ratio(photo: photoSize) != nil {
            cropIsPortrait.toggle()
        }
    }

    /// Straight, uncropped and as shot, in one undo step.
    func resetFraming() {
        actionName = "Reset Crop"
        controls.framing = Framing()
        actionName = nil
        cropAspect = .free
    }

    /// The crop's shape as a ratio of its fractions of the turned photo (width over height): what
    /// the crop tool holds it to, nil if it's free.
    var cropFractionRatio: CGFloat? {
        guard let ratio = cropAspect.ratio(photo: photoSize) else { return nil }
        let turned = controls.framing.turnedSize(of: photoSize)
        guard turned.width > 0 else { return nil }
        return (cropIsPortrait ? 1 / ratio : ratio) * turned.height / turned.width
    }

    /// Picks `aspect` for the crop, upright if the crop is now taller than wide.
    func chooseCropAspect(_ aspect: CropAspect) {
        let size = controls.framing.croppedSize(of: photoSize)
        if aspect == .original {
            // The photo's own shape, as it's turned.
            let turned = controls.framing.turnedSize(of: photoSize)
            cropIsPortrait = turned.height > turned.width
        } else if cropAspect == .free || cropAspect == .original {
            cropIsPortrait = size.height > size.width
        }
        cropAspect = aspect
        fitCropToAspect()
    }

    /// Swaps the crop's shape between wide and tall.
    func toggleCropOrientation() {
        cropIsPortrait.toggle()
        fitCropToAspect()
    }

    /// The largest crop of the chosen shape within the photo, around the crop's centre.
    private func fitCropToAspect() {
        guard let ratio = cropFractionRatio else { return }
        var width = min(1, ratio), height = width / ratio
        if height > 1 { (width, height) = (ratio, 1) }
        let crop = controls.framing.crop
        let x = min(max(crop.midX - width / 2, 0), 1 - width)
        let y = min(max(crop.midY - height / 2, 0), 1 - height)
        let fitted = CGRect(x: x, y: y, width: width, height: height)
        if fitted != crop {
            controls.framing.crop = fitted
        }
    }

    /// Frames the last render again for the library's thumbnail, once the framing pauses.
    private func scheduleFramedThumbnail() {
        framedThumbnailTask?.cancel()
        guard let render = lastFinishedRender, let url = photo?.url else { return }
        framedThumbnailTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, photo?.url == url else { return }
            let framing = controls.framing
            let framed = await Task.detached(priority: .utility) { framing.apply(to: render) }.value
            guard !Task.isCancelled else { return }
            onFinishedRender?(url, framed)
        }
    }

    // MARK: Adjustments

    /// The settings' groups (``Controls/Adjustment``), as Photos groups its adjustments.
    typealias Adjustment = Controls.Adjustment

    /// Whether `adjustment`'s controls are what choosing the film applies.
    func isAtDefaults(_ adjustment: Controls.Adjustment) -> Bool {
        controls == controls.resetting(adjustment, to: resetDefaults(for: controls.film))
    }

    /// Returns `adjustment`'s controls to what choosing the film applies.
    func reset(_ adjustment: Controls.Adjustment) {
        controls = controls.resetting(adjustment, to: resetDefaults(for: controls.film))
    }

    /// What a Reset button returns its controls to: the film's saved defaults, or the app's own.
    /// Saved defaults that can't be read were reported when the film was chosen, so here they're
    /// the app's own.
    private func resetDefaults(for film: String) -> Controls {
        UserDefaults.standard.data(forKey: Self.defaultsKey(film))
            .flatMap { try? Controls(preset: $0) }.map { checked($0) } ?? Controls()
    }

    /// `target` with `groups`' controls from `source`: pasting edits or a preset that keeps only
    /// some groups.
    static func copying(_ groups: Set<Adjustment>, from source: Controls, into target: Controls) -> Controls {
        groups.reduce(target) { $0.resetting($1, to: source) }
    }

    /// Sets the controls to `new` (checked as a preset is), as one undo step named `name`.
    func apply(_ new: Controls, named name: String) {
        actionName = name
        controls = checked(new)
        actionName = nil
    }

    /// `controls` brought within the app's ranges and stocks, as a preset is when opened.
    func checkedControls(_ controls: Controls) -> Controls { checked(controls) }

    // MARK: Helpers

    /// The most entries ``log`` keeps: each step of a slider adds one, and the Log window lays them
    /// all out at each. Console keeps every message (``logger``).
    private static let logLimit = 1000

    private func note(_ message: String) {
        log.append(LogEntry(message: message))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
        logger.notice("\(message, privacy: .public)")
    }

    /// Shows `error` under the window's title and logs it; for something the user asked for, also
    /// in an alert (`alert`), titled with `context`.
    private func fail(_ context: String, _ error: Error, alert: Bool = false) {
        errorMessage = "\(context): \(error.localizedDescription)"
        note("⚠️ \(errorMessage ?? context)")
        if alert {
            failure = Failure(title: "\(context).", message: error.localizedDescription)
        }
    }
}

/// The finished photo as Share and Copy send it: a JPEG at full resolution, as Save
/// writes one, rendered only when what receives it asks (``PhotoModel/finishedFile(named:)``).
nonisolated struct FinishedPhoto: Transferable {
    let model: PhotoModel
    /// The file's name, without its extension: the photo's.
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { photo in
            SentTransferredFile(try await photo.model.finishedFile(named: photo.name))
        }
        .suggestedFileName { "\($0.name).jpg" }
    }
}
