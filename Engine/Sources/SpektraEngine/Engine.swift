import CoreGraphics
import CoreImage
import Dispatch
import Foundation
import Metal
import MetalPerformanceShaders
import UniformTypeIdentifiers

/// What the app's controls set. Everything else stays at Spektrafilm's defaults for the film and
/// paper. A preset is these values as JSON.
public struct Controls: Codable, Sendable, Hashable {
    /// Stock names (`profiles/<stock>.json`).
    public var film = "kodak_portra_400"
    public var paper = "kodak_portra_endura"
    /// Scan the developed film itself instead of a print of it (`io.scan_film`).
    public var scanFilm = false
    /// The exposure: `exposureMark`'s reading for the photo (``MeteringReadings``) plus
    /// `exposureOffsetEV` stops. A new photo opens at the same mark's own reading.
    public var exposureMark = MeteringMark.centreWeighted
    public var exposureOffsetEV = 0.0
    /// Stops the brightest highlights are raised by before they reach the film, rebuilding light
    /// the camera clipped (0 is off).
    public var highlightBoost = 0.0
    /// The enlarger's exposure time, relative to the one that prints a mid-grey neutral.
    public var printExposure = 1.0
    /// Enlarger filters, in Kodak CC units away from the film and paper's neutral ones.
    public var yFilterShift = 0.0
    public var mFilterShift = 0.0
    /// A flash of the bare enlarger light on the paper before the print, as a fraction of the
    /// clear film base's exposure: it darkens light tones more than white or the shadows.
    public var preflash = 0.0
    /// The preflash's own filters, in CC away from the print's neutral ones, which tint what it
    /// adds to the light tones (not Spektrafilm's controls, but its parameters).
    public var preflashYFilterShift = 0.0
    public var preflashMFilterShift = 0.0
    /// Burning the print's edges in (positive stops), or dodging them for a reverse vignette
    /// (negative), as a darkroom printer does with a hand or a card (not Spektrafilm's): `vignetteMidpoint`
    /// is how far out from the centre the change is half done, from 0 to the corners at 1, and
    /// `vignetteSoftness` how wide its fade is.
    public var vignette = false
    public var vignetteStops = 1.0
    public var vignetteMidpoint = 0.6
    public var vignetteSoftness = 0.6
    /// Burning in what's bright, such as a sky, as a darkroom printer does: extra enlarger exposure,
    /// in stops, where the film's exposure is over `burnThreshold` stops above mid-grey.
    public var burn = false
    public var burnStops = 1.0
    public var burnThreshold = 2.5
    /// The look of a print scanned on a flatbed (not Spektrafilm's): blacks lifted to
    /// `scanBlackLevel` (a fraction of white) and colour pushed into the shadows, of hue
    /// `scanShadowHue` in degrees, by `scanShadowAmount`, up through `scanShadowRange` of the tones.
    public var scanLook = false
    public var scanBlackLevel = 0.01
    public var scanShadowHue = 200.0
    public var scanShadowAmount = 0.3
    public var scanShadowRange = 0.5
    /// The paper's contrast, as a multiplier of its curves' gamma around mid-grey; and of its
    /// light tones' alone (its fastest sub-layer's) and its dark tones' (the others').
    public var printContrast = 1.0
    public var printHighlightContrast = 1.0
    public var printShadowContrast = 1.0
    /// Stray light over the print when it's viewed: its mean in percent of the light, its spread
    /// relative to that, and its blur in pixels.
    public var glare = true
    public var glareAmount = 0.03
    public var glareRoughness = 0.7
    public var glareSoftness = 0.5
    public var halation = true
    /// Multipliers over the film's halation preset (Spektrafilm's high-level halation scalars):
    /// the glow from light bouncing off the film base, and light spreading inside the emulsion
    /// (the scatter amount blends towards the scattered light, so 1 is all of it).
    public var halationAmount = 1.0
    public var halationSize = 1.0
    public var scatterAmount = 1.0
    public var scatterSize = 1.0
    /// The DIR couplers' inhibition between layers (saturation) and within each (edge
    /// contrast), as multipliers of the film's own.
    public var couplers = true
    public var couplerSaturation = 1.0
    public var couplerEdgeContrast = 1.0
    public var grain = true
    /// Area of one silver halide particle in µm², and the grain's final blur in pixels.
    public var grainSize = 0.2
    public var grainSoftness = 0.65
    /// A diffusion filter on the camera's lens (Pro-Mist and the like), as Spektrafilm takes it: on
    /// or off, its family, its strength in the stops filters are sold in, its glow's size as a
    /// multiplier of the family's, and warmth added to the family's halo warmth.
    public var cameraDiffusion = Parameters.DiffusionFilter()
    /// The same on the enlarger's lens, over the print.
    public var enlargerDiffusion = Parameters.DiffusionFilter()
    /// The photo's framing, applied to the render rather than in it (not Spektrafilm's): turned
    /// `rotation` quarter turns clockwise, straightened by `straighten` degrees clockwise, zoomed in
    /// so no corner shows, then cropped to `crop…`, fractions of the turned photo's width and height
    /// from its top left.
    public var rotation = 0
    public var straighten = 0.0
    public var cropX = 0.0
    public var cropY = 0.0
    public var cropWidth = 1.0
    public var cropHeight = 1.0

    public init() {}

    /// Reads a preset. Settings it has no value for, such as those added since it was saved, keep
    /// their defaults.
    public init(preset: Data) throws {
        let defaults = try JSONSerialization.jsonObject(with: Controls().preset())
        let stored = try JSONSerialization.jsonObject(with: preset)
        let merged = try JSONSerialization.data(withJSONObject: Self.merging(stored, over: defaults))
        self = try JSONDecoder().decode(Controls.self, from: merged)
    }

    /// `stored` over `defaults`, key by key in nested objects.
    private static func merging(_ stored: Any, over defaults: Any) -> Any {
        guard let stored = stored as? [String: Any], let defaults = defaults as? [String: Any] else { return stored }
        return defaults.merging(stored) { merging($1, over: $0) }
    }

    /// The controls as a preset: JSON, readable and with sorted keys so presets diff cleanly.
    public func preset() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Each number's range: what its slider spans, and what a preset is brought within
    /// (``clampedToRanges()``). Outside them the engine can stop or render black.
    public static let ranges: [WritableKeyPath<Controls, Double> & Sendable: ClosedRange<Double>] = {
        // The paper's contrasts: the tone graph's side points' whole way. By 3 they're at the
        // paper's black or white (past 4 the middle drifts); below 0.1 they barely move closer to its
        // mid-grey (measured on Portra Endura, 2383 and Crystal Archive). At 0 the engine stops.
        let contrast = 0.1...3.0
        let filterShift = -100.0...100.0
        // Filters are sold from 1/8 to 2. The size multiplies the glow's width, which a huge one
        // makes too wide to size its convolution by, stopping the engine.
        let diffusionStrength = 0.125...2.0, diffusionSize = 0.0...3.0, diffusionWarmth = -1.5...1.5
        return [
            // The Exposure slider's −4…+8 stops, from a mark at either end of them.
            \.exposureOffsetEV: -12...12,
            \.highlightBoost: 0...10,
            \.printExposure: 0...2,
            \.yFilterShift: filterShift,
            \.mFilterShift: filterShift,
            \.preflash: 0...0.05,
            \.preflashYFilterShift: filterShift,
            \.preflashMFilterShift: filterShift,
            \.vignetteStops: -3...3,
            \.vignetteMidpoint: 0.1...1,
            \.vignetteSoftness: 0.05...1,
            \.scanBlackLevel: 0...0.1,
            \.scanShadowHue: 0...360,
            \.scanShadowAmount: 0...1,
            \.scanShadowRange: 0.05...1,
            // The tone graph's burn line's whole way: the threshold stays within its −6…+6 stops.
            \.burnStops: 0...3,
            \.burnThreshold: 0...6,
            \.printContrast: contrast,
            \.printHighlightContrast: contrast,
            \.printShadowContrast: contrast,
            \.glareAmount: 0...1,
            \.glareRoughness: 0...1,
            \.glareSoftness: 0...3,
            \.halationAmount: 0...3,
            \.halationSize: 0...3,
            \.scatterAmount: 0...1,
            \.scatterSize: 0...3,
            // At most 1.5: much stronger inhibition (both at 2, say) breaks Spektrafilm's curves
            // corrected for it, greys and all, in Python as here.
            \.couplerSaturation: 0...1.5,
            \.couplerEdgeContrast: 0...1.5,
            // Not down to 0: the particle count per pixel divides by the area.
            \.grainSize: 0.05...2,
            \.grainSoftness: 0...2,
            \.cameraDiffusion.strength: diffusionStrength,
            \.cameraDiffusion.spatialScale: diffusionSize,
            \.cameraDiffusion.haloWarmth: diffusionWarmth,
            \.enlargerDiffusion.strength: diffusionStrength,
            \.enlargerDiffusion.spatialScale: diffusionSize,
            \.enlargerDiffusion.haloWarmth: diffusionWarmth,
            \.straighten: -45...45,
            \.cropX: 0...0.95,
            \.cropY: 0...0.95,
            \.cropWidth: 0.05...1,
            \.cropHeight: 0.05...1,
        ]
    }()

    /// `control`'s range (``ranges``): also for a key path made by appending, such as a diffusion
    /// filter's strength from the filter's.
    public static func range(_ control: WritableKeyPath<Controls, Double>) -> ClosedRange<Double> {
        guard let range = ranges.first(where: { $0.key == control })?.value else {
            preconditionFailure("No range for \(control)")
        }
        return range
    }

    /// The controls with every number brought within its range: for a preset, which can be edited
    /// by hand.
    public func clampedToRanges() -> Controls {
        var controls = self
        for (control, range) in Self.ranges {
            controls[keyPath: control] = min(max(controls[keyPath: control], range.lowerBound), range.upperBound)
        }
        return controls
    }
}

/// The app's rules for the settings: what each Reset button resets, what Undo is called, what
/// choosing a film sets, how a preset is made renderable, where the Exposure slider lands, and the
/// strips' frames. Here rather than in the app, so they're tested; the app keeps the state and
/// what it reads them from (the films, the saved defaults, the open photo's readings).
extension Controls {
    /// The settings' groups, as Photos groups its adjustments: each resets on its own.
    /// Also what copying edits and presets keep, by their raw values: `stocks` (the film, paper
    /// and Print | Film) and `crop` (the framing) have no Reset button of their own.
    public enum Adjustment: String, CaseIterable, Codable, Sendable {
        case stocks, exposure, cameraDiffusion, halation, couplers, grain, contrast, enlarger, vignette, burn, enlargerDiffusion,
             glare, scanLook, crop
    }

    /// These controls with `adjustment`'s from `defaults`: the film's saved defaults, or the app's own.
    public func resetting(_ adjustment: Adjustment, to defaults: Controls) -> Controls {
        var reset = self
        switch adjustment {
        case .stocks:
            reset.film = defaults.film
            reset.paper = defaults.paper
            reset.scanFilm = defaults.scanFilm
        case .exposure:
            reset.exposureMark = defaults.exposureMark
            reset.exposureOffsetEV = defaults.exposureOffsetEV
            reset.highlightBoost = defaults.highlightBoost
        case .cameraDiffusion:
            reset.cameraDiffusion = defaults.cameraDiffusion
        case .halation:
            reset.halation = defaults.halation
            reset.halationAmount = defaults.halationAmount
            reset.halationSize = defaults.halationSize
            reset.scatterAmount = defaults.scatterAmount
            reset.scatterSize = defaults.scatterSize
        case .couplers:
            reset.couplers = defaults.couplers
            reset.couplerSaturation = defaults.couplerSaturation
            reset.couplerEdgeContrast = defaults.couplerEdgeContrast
        case .grain:
            reset.grain = defaults.grain
            reset.grainSize = defaults.grainSize
            reset.grainSoftness = defaults.grainSoftness
        case .contrast:
            reset.printContrast = defaults.printContrast
            reset.printHighlightContrast = defaults.printHighlightContrast
            reset.printShadowContrast = defaults.printShadowContrast
        case .enlarger:
            reset.printExposure = defaults.printExposure
            reset.yFilterShift = defaults.yFilterShift
            reset.mFilterShift = defaults.mFilterShift
            reset.preflash = defaults.preflash
            reset.preflashYFilterShift = defaults.preflashYFilterShift
            reset.preflashMFilterShift = defaults.preflashMFilterShift
        case .vignette:
            reset.vignette = defaults.vignette
            reset.vignetteStops = defaults.vignetteStops
            reset.vignetteMidpoint = defaults.vignetteMidpoint
            reset.vignetteSoftness = defaults.vignetteSoftness
        case .burn:
            reset.burn = defaults.burn
            reset.burnStops = defaults.burnStops
            reset.burnThreshold = defaults.burnThreshold
        case .enlargerDiffusion:
            reset.enlargerDiffusion = defaults.enlargerDiffusion
        case .glare:
            reset.glare = defaults.glare
            reset.glareAmount = defaults.glareAmount
            reset.glareRoughness = defaults.glareRoughness
            reset.glareSoftness = defaults.glareSoftness
        case .scanLook:
            reset.scanLook = defaults.scanLook
            reset.scanBlackLevel = defaults.scanBlackLevel
            reset.scanShadowHue = defaults.scanShadowHue
            reset.scanShadowAmount = defaults.scanShadowAmount
            reset.scanShadowRange = defaults.scanShadowRange
        case .crop:
            reset.rotation = defaults.rotation
            reset.straighten = defaults.straighten
            reset.cropX = defaults.cropX
            reset.cropY = defaults.cropY
            reset.cropWidth = defaults.cropWidth
            reset.cropHeight = defaults.cropHeight
        }
        return reset
    }

    /// The settings group a change is in, as the panel names it, by the first control it changed:
    /// the change's Undo name.
    public static func groupName(changedFrom old: Controls, to new: Controls) -> String {
        let changed = zip(Mirror(reflecting: old).children, Mirror(reflecting: new).children)
            .first { "\($0.value)" != "\($1.value)" }?.0.label ?? ""
        return switch changed {
        case "film": "Film"
        case "paper": "Paper"
        case "scanFilm": "Print or Film"
        case "exposureMark", "exposureOffsetEV", "highlightBoost": "Exposure"
        case "printExposure", "yFilterShift", "mFilterShift": "Enlarger"
        case let name where name.hasPrefix("preflash"): "Enlarger"
        case let name where name.hasPrefix("vignette"): "Vignette"
        case let name where name.hasPrefix("scan") && name != "scanFilm": "Scanned Print"
        case "printContrast", "printHighlightContrast", "printShadowContrast": "Contrast"
        case "cameraDiffusion": "Lens Diffusion"
        case "enlargerDiffusion": "Enlarger Diffusion"
        case let name where name.hasPrefix("burn"): "Burn"
        case let name where name.hasPrefix("glare"): "Glare"
        case let name where name.hasPrefix("halation") || name.hasPrefix("scatter"): "Halation"
        case let name where name.hasPrefix("coupler"): "Couplers"
        case let name where name.hasPrefix("grain"): "Grain"
        case "rotation": "Rotate"
        case "straighten": "Straighten"
        case let name where name.hasPrefix("crop"): "Crop"
        default: "Settings"
        }
    }

    /// These controls with `film`, its target paper (if it has one) and slides viewed directly,
    /// as Spektrafilm's GUI does: what choosing a film without saved defaults sets. `films` are
    /// the films to choose from (``Engine/films``).
    public func choosing(film: String, from films: [ProfileInfo]) -> Controls {
        var controls = self
        controls.film = film
        guard let info = films.first(where: { $0.stock == film }) else { return controls }
        if let paper = info.targetPrint {
            controls.paper = paper
        }
        controls.scanFilm = info.type == .positive
        return controls
    }

    /// These controls read from a preset (or a film's saved defaults), which can be edited by hand,
    /// made what the engine can render: every number within its range, and a slide viewed
    /// directly, as the Print | Film switch has it. With the names of the controls that changed.
    public func checked(films: [ProfileInfo]) -> (controls: Controls, changed: [String]) {
        var checked = clampedToRanges()
        if films.first(where: { $0.stock == film })?.type == .positive {
            checked.scanFilm = true
        }
        let changed = zip(Mirror(reflecting: self).children, Mirror(reflecting: checked).children)
            .filter { "\($0.value)" != "\($1.value)" }
            .compactMap(\.0.label)
        return (checked, changed)
    }

    /// How close to a mark, in stops, the exposure lands on it (``settingExposure(_:readings:)``).
    public static let exposureSnap = 0.15

    /// The exposure these controls give a photo metered as `readings`, in stops over it as shot:
    /// their mark's reading plus their offset.
    public func exposureEV(readings: MeteringReadings) -> Double {
        readings.reading(resolving: exposureMark).ev + exposureOffsetEV
    }

    /// These controls with the exposure at `ev` stops over a photo metered as `readings`, as shot.
    /// Within ``exposureSnap`` of a mark, it lands on the mark; elsewhere it keeps the nearest mark
    /// and the offset from it, so the next photo opens as far from that mark's own reading.
    public func settingExposure(_ ev: Double, readings: MeteringReadings) -> Controls {
        let nearest = MeteringMark.allCases.compactMap { mark in readings.ev[mark.rawValue].map { (mark, $0) } }
            .min { abs($0.1 - ev) < abs($1.1 - ev) }!
        var controls = self
        controls.exposureMark = nearest.0
        controls.exposureOffsetEV = abs(ev - nearest.1) < Self.exposureSnap ? 0 : ev - nearest.1
        return controls
    }

    /// The Exposure slider's range for a photo metered as `readings` (nil with none open): −4…+8
    /// stops, widened to whole stops past any reading outside it. Not past the exposure: a drag
    /// held at the end would widen it, and the next step follow it.
    public static func exposureRange(readings: MeteringReadings?) -> ClosedRange<Double> {
        let evs = readings?.ev.compactMap { $0 } ?? []
        return min(-4, (evs.min() ?? 0).rounded(.down) - 1)...max(8, (evs.max() ?? 0).rounded(.up) + 1)
    }

    /// A control shown as Photos shows its main adjustments: the photo across the control's range,
    /// a frame each (the app's thumbnail strips).
    public enum Strip: CaseIterable, Sendable {
        case exposure, couplerSaturation, printExposure

        /// Whether this strip's control changes what `controls` show.
        public func applies(to controls: Controls) -> Bool {
            switch self {
            case .exposure: true
            case .couplerSaturation: controls.couplers
            case .printExposure: !controls.scanFilm
            }
        }
    }

    /// These controls with `strip`'s control at `value`: for the exposure, `value` stops over the
    /// photo as shot (metered as `readings`), from the controls' mark.
    public func setting(_ strip: Strip, to value: Double, readings: MeteringReadings) -> Controls {
        var controls = self
        switch strip {
        case .exposure:
            controls.exposureOffsetEV = value - readings.reading(resolving: exposureMark).ev
        case .couplerSaturation:
            controls.couplerSaturation = value
        case .printExposure:
            controls.printExposure = value
        }
        return controls
    }
}

/// A 3D colour lookup table: `size`³ RGB outputs for inputs evenly spaced over [0, 1], red
/// changing fastest, then green, then blue.
public struct LUT: Sendable {
    public let size: Int
    public let values: [Float]

    /// The table as a `.cube` file (Adobe's Cube LUT specification 1.0), titled `title`: the name
    /// apps such as LightCraft show for it. `comments` go first, as `#` lines.
    public func cube(title: String, comments: [String] = []) -> Data {
        var text = comments.map { "# \($0)\n" }.joined()
        text += "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\n"
        text += "LUT_3D_SIZE \(size)\n"
        for index in stride(from: 0, to: values.count, by: 3) {
            text += String(format: "%.6f %.6f %.6f\n", values[index], values[index + 1], values[index + 2])
        }
        return Data(text.utf8)
    }
}

/// What the Print tab's tone graph draws (``Engine/toneGraph(controls:)``), over the photo's tones:
/// the film's exposure in stops over mid-grey, the Exposure control's units.
public struct ToneGraph: Sendable {
    /// One grey of the ramp the curve is rendered from.
    public struct Point: Sendable {
        /// The film's exposure to the grey, per layer (red-, green- and blue-sensitive), in stops
        /// over mid-grey.
        public let film: SIMD3<Float>
        /// The paper's exposure to the negative of it, per layer, as log₁₀: 0 is a mid-grey
        /// negative's at a print exposure of 1. The contrasts scale the paper's response about 0
        /// (``printCurves(_:logExposure:morph:positive:)``), and the print exposure adds its log₁₀.
        public let paper: SIMD3<Float>
        /// The print's colour for it: display-encoded Display P3, 0–1.
        public let print: SIMD3<Float>
    }

    /// The tones the ramp and the histogram span, in stops over mid-grey.
    public static let stops: ClosedRange<Float> = -8...8
    /// The print's tone curve: a ramp of greys evenly spaced in stops across ``stops``.
    public let curve: [Point]
    /// How much of the photo is at each tone of the film's exposure, per layer: bins evenly spaced
    /// across ``stops``, each the fraction of the preview's pixels in it. Exposures outside the
    /// range count in the end bins.
    public let histogram: [SIMD3<Float>]
}

/// What a render is for.
public enum RenderMode: Sendable, Equatable {
    /// Each change while editing: Spektrafilm's preview mode (no blurs or grain), on the open
    /// photo's preview. Linear, in ``Engine/outputColorSpace``.
    case preview
    /// The open photo with every effect, scaled to `longSide` pixels on its long side: the
    /// finished look at the size the screen shows it (the whole photo, as `full`, if that's no
    /// smaller). Linear, in ``Engine/outputColorSpace``.
    case reduced(longSide: Int)
    /// The whole open photo with every effect. Linear, in ``Engine/outputColorSpace``.
    case full
    /// As `preview`, on an image of the open photo at most 256 px on its long side: the frames of
    /// the app's thumbnail strips.
    case thumbnail
    /// As `full`, encoded for a file in ``Engine/exportColorSpace`` (Spektrafilm's default output).
    case export
}

/// Runs the simulation for the app. A render waits on the GPU, so the actor runs on its own serial
/// queue rather than blocking a thread of the cooperative pool (Scanjet's scanner-actor pattern).
public actor Engine {
    private nonisolated let queue = DispatchSerialQueue(label: "SpektraEngine.Engine")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The films (`stage` filming) and papers (`stage` printing) to choose from, by name.
    public nonisolated let films: [ProfileInfo]
    public nonisolated let papers: [ProfileInfo]

    private let gpu: GPU
    /// The GPU time of the engine's own command buffers so far, readable while it renders.
    public nonisolated let gpuTime: GPUTime
    private let tables: Tables
    private let profiles: [String: Profile]
    private let neutralPrintFilters: [String: [String: [String: SIMD3<Double>]]]
    private let cache = SimulationCache()
    /// Core Image on the GPU's queue: it renders opened photos into their textures and renders
    /// to the screen.
    private let context: CIContext
    /// The last render's simulation, rebuilt when a render needs other parameters or profiles.
    private var simulation: Simulation?
    /// The photo renders work on (``open(_:)``).
    private var photo: Photo?
    /// GPU memory set aside for renders' intermediates (``GPU/reservedMemory(width:height:keeping:)``),
    /// which each render makes them from. For renders the size of the preview, the thumbnail or the
    /// screen: kept for every photo, the largest so far (0.5 GB at 1600 px), as new memory for each
    /// photo cost the first render after opening 150 ms more; until memory runs low
    /// (``releaseReservedMemory()``).
    private var screenMemory: (any MTLHeap)?
    /// For renders of the whole photo, where that's larger than its preview: set aside by the first
    /// (its pages become resident as that starts: 2 GB at 12 MP) and kept for the next zoom or save,
    /// until another photo opens or memory runs low (``releaseFullSizeMemory()``).
    private var fullSizeMemory: (any MTLHeap)?
    /// Says when memory runs low.
    private let memoryPressure: any DispatchSourceMemoryPressure
    /// The live preview's long side. Larger than Spektrafilm's `preview_max_size` (640), which is
    /// soft on a Retina display: about 20 ms per change on an M1 Pro, preview mode and display.
    private nonisolated let previewMaxSize = 1600
    /// The long side of the image thumbnails render from.
    private nonisolated let thumbnailMaxSize = 256

    /// The output colour space: Display P3, a Mac display's, rather than Spektrafilm's default sRGB,
    /// so the output gamut compression keeps the saturated colours a print has that sRGB lacks.
    static let outputSpace = "Display P3"
    /// The colour space of preview and full renders: linear ``outputSpace``, for the
    /// colour-managed display.
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    /// The colour space of export renders: ``outputSpace`` with its transfer function (sRGB's).
    public static let exportColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    /// The colour space LUTs take and give (``lut(controls:exposureEV:size:)``): sRGB with its
    /// transfer function.
    static let lutColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The input colour space: RGBImage's working space, linear.
    static let inputColorSpace = "ITU-R BT.2020"

    public init() throws {
        gpu = try GPU()
        gpuTime = gpu.time
        context = RGBImage.makeContext(commandQueue: gpu.queue)
        tables = try Tables.load()
        neutralPrintFilters = try Tables.loadNeutralPrintFilters()
        let profiles = try Profile.stocks().map(Profile.load)
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.info.stock, $0) })
        let infos = profiles.map(\.info).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        films = infos.filter { $0.stage == .filming }
        papers = infos.filter { $0.stage == .printing }
        let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        self.memoryPressure = memoryPressure
        memoryPressure.setEventHandler { [weak self] in
            Task { await self?.releaseReservedMemory() }
        }
        memoryPressure.activate()
    }

    /// Lets the memory set aside for renders of the whole photo go, with the steps kept from the
    /// last one, whose textures hold it. The next such render sets it aside again.
    private func releaseFullSizeMemory() {
        if gpu.heap === fullSizeMemory {
            gpu.heap = nil
        }
        fullSizeMemory = nil
        photo?.full.exposure = nil
        photo?.full.film = nil
    }

    /// When memory runs low: lets all the memory set aside for renders go, the screen's too, with
    /// the steps kept from each image's last render. The next render sets its memory aside again.
    private func releaseReservedMemory() {
        releaseFullSizeMemory()
        if gpu.heap === screenMemory {
            gpu.heap = nil
        }
        screenMemory = nil
        photo?.preview.exposure = nil
        photo?.preview.film = nil
        photo?.thumbnail?.exposure = nil
        photo?.thumbnail?.film = nil
        photo?.reduced.exposure = nil
        photo?.reduced.film = nil
    }

    /// The open photo on the GPU, at full size, as its preview and as its thumbnail.
    private struct Photo {
        var full: PhotoImage
        var preview: PhotoImage
        /// Made for the first thumbnail render rather than as the photo opens: the strips render
        /// once the photo is on screen.
        var thumbnail: PhotoImage?
        /// The last `reduced` render's image of the photo.
        var reduced: PhotoImage
        /// What Vision found in the photo, for metering the images made later.
        let regions: MeteringRegions
    }

    /// One image of the photo with the exposure each metering mark gives it (Spektrafilm meters
    /// each image on its own preview), and what the last render of it left to start from: the
    /// film's log exposure and the developed film. Renders only read these textures.
    private struct PhotoImage {
        let texture: any MTLTexture
        let metering: MeteringReadings
        var exposure: Step?
        var film: Step?

        /// The exposure `controls` give this image: their mark's reading for it plus their offset.
        func exposureEV(for controls: Controls) -> Double {
            controls.exposureEV(readings: metering)
        }
    }

    /// A step's result and what it was made from: the film, the parameters it reads and the
    /// exposure (a mark's reading for the photo plus an offset, so not a parameter).
    private struct Step {
        struct Key: Equatable {
            let film: String
            let parameters: Parameters
            let exposureEV: Double
        }
        let key: Key
        let texture: any MTLTexture

        /// The keys of the film's exposure and of the developed film for `controls`, rendered with
        /// `parameters` at `exposureEV`.
        static func keys(for controls: Controls, parameters: Parameters,
                         exposureEV: Double) -> (exposure: Key, film: Key) {
            (Key(film: controls.film, parameters: Engine.exposureParameters(parameters), exposureEV: exposureEV),
             Key(film: controls.film, parameters: Engine.filmParameters(parameters), exposureEV: exposureEV))
        }
    }

    /// What ``open(_:)`` found out about a photo.
    public struct OpenedPhoto: Sendable {
        public let width: Int
        public let height: Int
        public let previewWidth: Int
        public let previewHeight: Int
        /// The preview's metering readings, as the controls show them.
        public let metering: MeteringReadings
        /// Each mark's region, for the canvas to tint (``MeteringRegions/overlays(for:width:height:maxSize:)``).
        public let meteringOverlays: [MeteringMark: CGImage]
    }

    /// The most pixels on a side of a Metal texture, and of what Core Animation textures: the
    /// largest photo ``open(_:)`` takes, and the largest ``display(controls:mode:maxPixels:)`` makes.
    public static let maxSide = 16384

    /// A photo larger than ``maxSide`` on a side: its texture can't be made.
    public struct PhotoTooLargeError: LocalizedError {
        public let width: Int
        public let height: Int
        public var errorDescription: String? {
            "The photo is \(width.formatted()) × \(height.formatted()) px, and SpektraMac opens photos up to \(Engine.maxSide.formatted()) px on a side"
        }
    }

    /// Makes `image` (``RGBImage/decode(contentsOf:)``) the photo renders work on: Core Image
    /// renders it once into a texture, and its preview (at most ``previewMaxSize`` on the long side)
    /// from that on the GPU. Vision looks for the metering marks' regions in the preview, and each
    /// image is metered once at every mark, in place. Throws ``PhotoTooLargeError`` for a photo over
    /// ``maxSide`` on a side. A photo that fails to open leaves the open one open, to render on.
    public func open(_ image: CIImage) throws -> OpenedPhoto {
        let extent = image.extent.integral
        let (width, height) = (Int(extent.width), Int(extent.height))
        guard max(width, height) <= Self.maxSide else { throw PhotoTooLargeError(width: width, height: height) }
        // The memory set aside for renders of all of the previous photo goes; the photo itself stays
        // until this one has opened.
        releaseFullSizeMemory()
        let full = gpu.makeReadableTexture(width: width, height: height)
        try render(image, from: extent, into: full)
        let preview = try scaled(full, toLongSide: previewMaxSize)
        // Auto-exposure is metered the same way in every mode (input space, no CCTF decoding).
        let space = tables.colourSpaces[Self.inputColorSpace]!
        let previewLuminance = meteredLuminance(of: Pixels(preview), colourSpace: space, cctfDecoding: false)
        let centreWeighted = MeteringReadings(luminance: previewLuminance.y, width: previewLuminance.width,
                                              height: previewLuminance.height, regions: nil).reading(resolving: .centreWeighted)
        // The full image's luminance (about 40 ms at 12 MP, on the CPU) while Vision looks at the
        // preview: it needs no regions.
        nonisolated(unsafe) let fullPixels = Pixels(full)
        nonisolated(unsafe) var fullLuminance: (y: [Double], width: Int, height: Int)?
        let metering = DispatchGroup()
        if full !== preview {
            DispatchQueue.global(qos: .userInitiated).async(group: metering) {
                fullLuminance = meteredLuminance(of: fullPixels, colourSpace: space, cctfDecoding: false)
            }
        }
        let found = Result { try MeteringRegions(finding: visionView(of: preview, exposure: centreWeighted.ev)) }
        metering.wait()  // even if Vision failed: the metering reads `full`
        let regions = try found.get()
        let previewImage = PhotoImage(texture: preview, metering: MeteringReadings(
            luminance: previewLuminance.y, width: previewLuminance.width, height: previewLuminance.height, regions: regions))
        let fullImage = fullLuminance.map { luminance in
            PhotoImage(texture: full, metering: MeteringReadings(luminance: luminance.y, width: luminance.width,
                                                                 height: luminance.height, regions: regions))
        } ?? previewImage
        photo = Photo(full: fullImage, preview: previewImage, reduced: previewImage, regions: regions)
        return OpenedPhoto(width: width, height: height, previewWidth: preview.width, previewHeight: preview.height,
                           metering: previewImage.metering,
                           meteringOverlays: regions.overlays(for: previewImage.metering, width: width, height: height))
    }

    /// Loads the models Vision looks for the metering marks' regions with (about 0.2 s on an M1
    /// Pro), which the first ``open(_:)`` would otherwise wait for: call it at launch.
    public func loadVision() throws {
        try MeteringRegions.loadModels()
    }

    /// `full` scaled down to `longSide` pixels on its long side as Spektrafilm's preview is made
    /// (Lanczos), or `full` itself if it's no larger.
    private func scaled(_ full: any MTLTexture, toLongSide longSide: Int) throws -> any MTLTexture {
        guard max(full.width, full.height) > longSide else { return full }
        // Core Image puts a texture's first row at the bottom.
        let source = CIImage(mtlTexture: full, options: [.colorSpace: RGBImage.workingColorSpace])!
        let scaled = RGBImage.scaledDown(source.oriented(.downMirrored), maxPixels: longSide)
        let texture = gpu.makeReadableTexture(width: Int(scaled.extent.width), height: Int(scaled.extent.height))
        try render(scaled, from: scaled.extent, into: texture)
        return texture
    }

    /// `texture` as an image of the open photo, metered at every mark (in the input space, no
    /// CCTF decoding, as in every mode).
    private func metered(_ texture: any MTLTexture, regions: MeteringRegions) -> PhotoImage {
        let luminance = meteredLuminance(of: Pixels(texture), colourSpace: tables.colourSpaces[Self.inputColorSpace]!,
                                         cctfDecoding: false)
        return PhotoImage(texture: texture, metering: MeteringReadings(
            luminance: luminance.y, width: luminance.width, height: luminance.height, regions: regions))
    }

    /// What Vision looks at: `preview` exposed by Spektrafilm's meter, so a dim scene is readable, as 8-bit
    /// sRGB at most 1024 px on the long side.
    private func visionView(of preview: any MTLTexture, exposure: Double) throws -> CGImage {
        let scale = min(1, 1024 / Double(max(preview.width, preview.height)))
        // Core Image puts a texture's first row at the bottom.
        let view = CIImage(mtlTexture: preview, options: [.colorSpace: RGBImage.workingColorSpace])!
            .oriented(.downMirrored)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(view, from: view.extent.integral, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw DisplayError()
        }
        return image
    }

    /// Renders `region` of `image` into `texture`, top row first, in the working colour space.
    private func render(_ image: CIImage, from region: CGRect, into texture: any MTLTexture) throws {
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = RGBImage.workingColorSpace
        destination.isFlipped = true
        try context.startTask(toRender: image, from: region, to: destination, at: .zero).waitUntilCompleted()
    }

    /// The simulation of the open photo as `controls` set it: the scanned print, or the developed
    /// film itself. Throws `CancellationError` when the task is cancelled.
    public func render(controls: Controls, mode: RenderMode) throws -> RGBImage {
        let output = try renderTexture(controls: controls, mode: mode).output
        return RGBImage(width: output.width, height: output.height, pixels: gpu.download(output))
    }

    /// The photo rendered for a file of `type` (``RenderMode/export``) as the file stores it: 16
    /// bits per channel for TIFF and PNG, 8 for JPEG, in ``exportColorSpace``
    /// (``GPU/image(of:bits:colorSpace:)``). Throws `CancellationError` when the task is cancelled.
    public func export(controls: Controls, as type: UTType) throws -> CGImage {
        try gpu.image(of: renderTexture(controls: controls, mode: .export).output, bits: type.conforms(to: .jpeg) ? 8 : 16,
                      colorSpace: Self.exportColorSpace)
    }

    /// ``render(controls:mode:)`` for the screen: 8-bit Display P3, no larger than `maxPixels` on its
    /// long side. By default that's the most Core Animation can texture (``maxSide``), so the canvas
    /// zooms into the render's own pixels. Core Image scales larger ones down on the GPU, so only
    /// that comes back from it.
    public func display(controls: Controls, mode: RenderMode, maxPixels: Int = maxSide) throws -> CGImage {
        let output = try renderTexture(controls: controls, mode: mode).output
        // Core Image puts a texture's first row at the bottom.
        guard let image = CIImage(mtlTexture: output, options: [.colorSpace: Self.outputColorSpace]) else {
            throw DisplayError()
        }
        let scaled = RGBImage.scaledDown(image.oriented(.downMirrored), maxPixels: maxPixels)
        guard let display = context.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!) else {
            throw DisplayError()
        }
        return display
    }

    public struct DisplayError: LocalizedError {
        public var errorDescription: String? { "Core Image couldn't draw the render" }
    }

    /// Renders from the first step `controls` change since the last render of the same image: a
    /// new paper, enlarger setting or Print | Film choice prints and scans the developed film
    /// again; switching grain develops the film's exposure again; the rest starts over. The same
    /// kernels run as for a render from scratch, so the result is the same. Also returns the burn's
    /// mask, if it's on.
    ///
    /// The work is in functions of its own, so each one's copies of the photo and the parameters
    /// leave the stack before the next: a debug build keeps every temporary of a function on its
    /// stack at once, and the engine's queue has 512 KB.
    private func renderTexture(controls: Controls, mode: RenderMode) throws
        -> (output: any MTLTexture, burnMask: (any MTLTexture)?) {
        guard photo != nil else { preconditionFailure("Rendering before a photo is open") }
        let parameters = parameters(for: controls, mode: mode)
        let simulation: Simulation
        if let current = self.simulation, current.parameters == parameters,
           current.film.info.stock == controls.film, current.print.info.stock == controls.paper {
            simulation = current
        } else {
            simulation = try Simulation(parameters: parameters, film: profiles[controls.film]!,
                                        print: profiles[controls.paper]!, gpu: gpu, tables: tables, cache: cache)
            self.simulation = simulation
        }
        let image = try image(for: mode)
        setAsideMemory(for: image)
        // In place, so the steps these controls don't match are released before the render.
        return try render(&photo![keyPath: image], controls: controls, parameters: parameters, simulation: simulation)
    }

    /// The image of the photo `mode` renders, made first if it's a thumbnail or a reduced image not
    /// made yet.
    private func image(for mode: RenderMode) throws -> WritableKeyPath<Photo, PhotoImage> {
        // Read once: in a debug build each read of `photo` is a copy on the stack.
        let photo = self.photo!
        switch mode {
        case .preview:
            return \.preview
        case .thumbnail:
            if photo.thumbnail == nil {
                let thumbnail = try scaled(photo.full.texture, toLongSide: thumbnailMaxSize)
                self.photo!.thumbnail = thumbnail === photo.full.texture
                    ? photo.full : metered(thumbnail, regions: photo.regions)
            }
            return \.thumbnail!
        case .reduced(let longSide):
            let full = photo.full.texture
            guard longSide < max(full.width, full.height) else { return \.full }
            let last = photo.reduced.texture
            if max(last.width, last.height) != longSide {
                self.photo!.reduced = metered(try scaled(full, toLongSide: longSide), regions: photo.regions)
            }
            return \.reduced
        case .full, .export:
            return \.full
        }
    }

    /// Makes the render's intermediates from the memory set aside for renders of `image`'s size.
    private func setAsideMemory(for image: WritableKeyPath<Photo, PhotoImage>) {
        let source = photo![keyPath: image].texture
        if image == \Photo.full && source !== photo!.preview.texture {
            fullSizeMemory = gpu.reservedMemory(width: source.width, height: source.height, keeping: fullSizeMemory)
            gpu.heap = fullSizeMemory
        } else {
            // A render's textures and room for the steps kept of the preview, the screen-size image
            // and the thumbnail: with fewer, some of a slider step's textures are allocated fresh
            // (30 ms a step instead of 24 at 12 MP with ten, 26 with 14).
            screenMemory = gpu.reservedMemory(width: source.width, height: source.height,
                                              textures: GPU.reservedTextures + 6, keeping: screenMemory)
            gpu.heap = screenMemory
        }
    }

    /// Renders `image` from the first step `controls` change since its last render, and keeps its
    /// film exposure and developed film for the next.
    private func render(_ image: inout PhotoImage, controls: Controls, parameters: Parameters,
                        simulation: Simulation) throws -> (output: any MTLTexture, burnMask: (any MTLTexture)?) {
        let exposureEV = image.exposureEV(for: controls)
        let keys = Step.keys(for: controls, parameters: parameters, exposureEV: exposureEV)
        // What's still valid of the last render; the rest is released before this one.
        if image.exposure?.key != keys.exposure {
            image.exposure = nil
        }
        if image.film?.key != keys.film {
            image.film = nil
        }
        let (texture, keptExposure, keptFilm) = (image.texture, image.exposure?.texture, image.film?.texture)
        let (logExposure, cmyFilm, burnMask, output) = try gpu.run { encoder in
            let logExposure = keptExposure ?? simulation.encodeExpose(
                simulation.encodePreprocess(texture, autoExposureEV: exposureEV, on: encoder), on: encoder)
            let cmyFilm = keptFilm ?? simulation.encodeDevelop(logExposure, on: encoder)
            let burnMask = simulation.encodeBurnMask(logExposure, on: encoder)
            return (logExposure, cmyFilm, burnMask,
                    simulation.encodePrintAndScan(cmyFilm, burnMask: burnMask, on: encoder))
        }
        image.exposure = Step(key: keys.exposure, texture: logExposure)
        image.film = Step(key: keys.film, texture: cmyFilm)
        return (output, burnMask)
    }

    /// Where `controls`' burn falls on the photo's preview, for the canvas to show while a Burn
    /// slider is held: white, with how much of the burn each pixel gets as alpha. Nil with the
    /// burn off.
    public func burnMask(controls: Controls) throws -> CGImage? {
        guard let mask = try renderTexture(controls: controls, mode: .preview).burnMask else { return nil }
        // Core Image puts a texture's first row at the bottom. The mask (in red) becomes the alpha.
        let overlay = CIImage(mtlTexture: mask, options: [.colorSpace: NSNull()])!
            .oriented(.downMirrored)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
        guard let image = context.createCGImage(overlay, from: overlay.extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw DisplayError()
        }
        return image
    }

    /// A `size`³ 3D LUT of `controls`' look, for an app that applies one to display-encoded sRGB
    /// (LightCraft does, after its own edits): each sRGB colour of the lattice opened as a photo is
    /// (Core Image decodes it into the working space), exposed `exposureEV` stops over itself and
    /// rendered as an export. What depends on other pixels is left out
    /// (``Parameters/applyPerPixelMode()``). Doesn't touch the open photo. At most 128: the lattice
    /// renders as an image size² wide, and a texture is at most 16384.
    public func lut(controls: Controls, exposureEV: Double, size: Int) throws -> LUT {
        precondition((2...128).contains(size))
        var parameters = parameters(for: controls, mode: .export)
        parameters.applyPerPixelMode()
        parameters.io.outputColorSpace = "sRGB"
        let simulation = try Simulation(parameters: parameters, film: profiles[controls.film]!,
                                        print: profiles[controls.paper]!, gpu: gpu, tables: tables, cache: cache)
        // The lattice in LUT order, a row per blue level: red changes fastest, then green.
        let axis = (0..<size).map { Float($0) / Float(size - 1) }
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        for blue in axis {
            for green in axis {
                for red in axis {
                    rgba += [red, green, blue, 1]
                }
            }
        }
        let lattice = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: size * size * 16,
                              size: CGSize(width: size * size, height: size), format: .RGBAf,
                              colorSpace: Self.lutColorSpace)
        let input = gpu.makeReadableTexture(width: size * size, height: size)
        try render(lattice, from: lattice.extent, into: input)
        let output = try gpu.run { encoder in
            let exposed = simulation.encodePreprocess(input, autoExposureEV: exposureEV, on: encoder)
            return simulation.encodePrintAndScan(simulation.encodeDevelop(simulation.encodeExpose(exposed, on: encoder),
                                                                          on: encoder), on: encoder)
        }
        // A colour outside the colour model (NaN) is black, as in a saved photo.
        return LUT(size: size, values: gpu.download(output).map { $0.isNaN ? 0 : min(max($0, 0), 1) })
    }

    /// The open photo's ``ToneGraph`` as `controls` set it. The curve is the print's whatever the
    /// toolbar shows, with what a LUT holds (``Parameters/applyPerPixelMode()``): a ramp of greys
    /// rendered as ``lut(controls:exposureEV:size:)`` renders its lattice. The histogram is of the
    /// preview's film exposure, kept from its last render if that had these controls' exposure.
    public func toneGraph(controls: Controls) throws -> ToneGraph {
        guard photo != nil else { preconditionFailure("A tone graph before a photo is open") }
        if !previewHasExposure(of: controls) {
            _ = try renderTexture(controls: controls, mode: .preview)
        }
        return ToneGraph(curve: try toneCurve(controls: controls),
                         histogram: try histogram(of: photo!.preview.exposure!.texture))
    }

    /// Whether the preview's last render made its film exposure as `controls` set it, as it keys it.
    private func previewHasExposure(of controls: Controls) -> Bool {
        let preview = photo!.preview
        let keys = Step.keys(for: controls, parameters: parameters(for: controls, mode: .preview),
                             exposureEV: preview.exposureEV(for: controls))
        return preview.exposure?.key == keys.exposure
    }

    /// The last tone curve and what it was rendered from: the exposure doesn't change it.
    private var lastToneCurve: (parameters: Parameters, film: String, paper: String, curve: [ToneGraph.Point])?

    /// Stops per unit of log₁₀ exposure.
    private nonisolated static let stopsPerLog10 = log2(Float(10))

    /// ``ToneGraph/curve``: 256 greys from mid-grey (0.184, what auto-exposure brings the photo's
    /// mean to) × 2^``ToneGraph/stops``, in the input space, through the film, the paper and the scan.
    private func toneCurve(controls: Controls) throws -> [ToneGraph.Point] {
        let film = profiles[controls.film]!, print = profiles[controls.paper]!
        var parameters = parameters(for: controls, mode: .export)
        parameters.applyPerPixelMode()
        parameters.io.scanFilm = false
        if let last = lastToneCurve, last.parameters == parameters, last.film == controls.film,
           last.paper == controls.paper {
            return last.curve
        }
        let simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables,
                                        cache: cache)
        let count = 256, stops = ToneGraph.stops
        let ramp = (0..<count).flatMap { index in
            let tone = stops.lowerBound + Float(index) / Float(count - 1) * (stops.upperBound - stops.lowerBound)
            return [Float](repeating: 0.184 * exp2(tone), count: 3)
        }
        let input = gpu.upload(rgb: ramp, width: count, height: 1)
        // The greys are already exposed: no auto-exposure.
        let (filmExposure, paperExposure, output) = try gpu.run { encoder in
            let filmExposure = simulation.encodeExpose(input, on: encoder)
            let paperExposure = simulation.encodePrintExpose(simulation.encodeDevelop(filmExposure, on: encoder),
                                                             on: encoder)
            return (filmExposure, paperExposure,
                    simulation.encodeScan(simulation.encodePrintDevelop(paperExposure, on: encoder), on: encoder))
        }
        let (filmValues, paperValues, printValues) = (gpu.download(filmExposure), gpu.download(paperExposure),
                                                      gpu.download(output))
        func pixel(_ values: [Float], _ index: Int) -> SIMD3<Float> {
            SIMD3(values[3 * index], values[3 * index + 1], values[3 * index + 2])
        }
        let curve = (0..<count).map { index in
            let colour = pixel(printValues, index)
            // A colour outside the colour model (NaN) is black, as in a saved photo.
            return ToneGraph.Point(film: pixel(filmValues, index) * Self.stopsPerLog10, paper: pixel(paperValues, index),
                                   print: colour.replacing(with: 0, where: colour .!= colour)
                                       .clamped(lowerBound: .zero, upperBound: .one))
        }
        lastToneCurve = (parameters, controls.film, controls.paper, curve)
        return curve
    }

    /// ``ToneGraph/histogram`` of a film exposure: 256 bins, counted on the GPU
    /// (`MPSImageHistogram`, which clamps values outside its range into the end bins).
    private func histogram(of logExposure: any MTLTexture) throws -> [SIMD3<Float>] {
        let bins = 256, stops = ToneGraph.stops
        var info = MPSImageHistogramInfo(numberOfHistogramEntries: bins, histogramForAlpha: false,
                                         minPixelValue: SIMD4(repeating: stops.lowerBound / Self.stopsPerLog10),
                                         maxPixelValue: SIMD4(repeating: stops.upperBound / Self.stopsPerLog10))
        let histogram = MPSImageHistogram(device: gpu.device, histogramInfo: &info)
        let counts = gpu.device.makeBuffer(length: histogram.histogramSize(forSourceFormat: logExposure.pixelFormat),
                                           options: .storageModeShared)!
        try gpu.run { encoder in
            encoder.encodeCommands { histogram.encode(to: $0, sourceTexture: logExposure, histogram: counts, histogramOffset: 0) }
        }
        // A channel's bins, then the next channel's.
        let values = counts.contents().assumingMemoryBound(to: UInt32.self)
        let pixels = Float(logExposure.width * logExposure.height)
        return (0..<bins).map { bin in
            SIMD3(Float(values[bin]), Float(values[bins + bin]), Float(values[2 * bins + bin])) / pixels
        }
    }

    /// What the developed film depends on: every parameter but the printing and scanning ones.
    /// (Leaving out what's known not to matter, rather than picking what does, keeps a parameter
    /// ported later from being missed.)
    private static func filmParameters(_ parameters: Parameters) -> Parameters {
        var key = parameters
        let defaults = Parameters()
        key.enlarger = defaults.enlarger
        key.printRender = defaults.printRender
        key.scanner = defaults.scanner
        key.io.outputColorSpace = defaults.io.outputColorSpace
        key.io.outputCctfEncoding = defaults.io.outputCctfEncoding
        key.io.outputGamutCompress = defaults.io.outputGamutCompress
        key.io.scanFilm = defaults.io.scanFilm
        return key
    }

    /// What the film's log exposure depends on: the developed film's parameters but those of its
    /// development.
    private static func exposureParameters(_ parameters: Parameters) -> Parameters {
        var key = filmParameters(parameters)
        let defaults = Parameters()
        key.filmRender.densityCurveGamma = defaults.filmRender.densityCurveGamma
        key.filmRender.dirCouplers = defaults.filmRender.dirCouplers
        key.filmRender.grain = defaults.filmRender.grain
        return key
    }

    /// ``parameters(for:film:print:database:mode:)`` with `controls`' film and paper.
    private func parameters(for controls: Controls, mode: RenderMode) -> Parameters {
        Self.parameters(for: controls, film: profiles[controls.film]!, print: profiles[controls.paper]!,
                        database: neutralPrintFilters, mode: mode)
    }

    /// `controls` over Spektrafilm's defaults, in the app's colour spaces, digested as
    /// `digest_params` does it: neutral print filters, preview mode, then the film's specifics.
    static func parameters(for controls: Controls, film: Profile, print: Profile,
                           database: [String: [String: [String: SIMD3<Double>]]], mode: RenderMode) -> Parameters {
        var parameters = Parameters()
        parameters.io.inputColorSpace = inputColorSpace
        parameters.io.outputColorSpace = outputSpace
        parameters.io.outputCctfEncoding = mode == .export  // the display is colour-managed: linear
        parameters.io.scanFilm = controls.scanFilm
        parameters.enlarger.printExposure = controls.printExposure
        parameters.enlarger.yFilterShift = controls.yFilterShift
        parameters.enlarger.mFilterShift = controls.mFilterShift
        parameters.enlarger.preflashExposure = controls.preflash
        parameters.enlarger.preflashYFilterShift = controls.preflashYFilterShift
        parameters.enlarger.preflashMFilterShift = controls.preflashMFilterShift
        parameters.enlarger.vignette = controls.vignette && controls.vignetteStops != 0
            ? Parameters.Vignette(stops: controls.vignetteStops, midpoint: controls.vignetteMidpoint,
                                  softness: controls.vignetteSoftness) : nil
        parameters.scanner.look = controls.scanLook
            ? Parameters.ScanLook(blackLevel: controls.scanBlackLevel, shadowHue: controls.scanShadowHue,
                                  shadowAmount: controls.scanShadowAmount, shadowRange: controls.scanShadowRange) : nil
        parameters.enlarger.burn = controls.burn
            ? Parameters.Burn(stops: controls.burnStops, threshold: controls.burnThreshold) : nil
        // Off at 1: Python's default, which the morph at 1 renders identically.
        parameters.printRender.densityCurvesMorph.active = controls.printContrast != 1
            || controls.printHighlightContrast != 1 || controls.printShadowContrast != 1
        parameters.printRender.densityCurvesMorph.gammaFactor = controls.printContrast
        parameters.printRender.densityCurvesMorph.gammaFactorFast = controls.printHighlightContrast
        parameters.printRender.densityCurvesMorph.gammaFactorSlow = controls.printShadowContrast
        parameters.printRender.glare.active = controls.glare
        parameters.printRender.glare.percent = controls.glareAmount
        parameters.printRender.glare.roughness = controls.glareRoughness
        parameters.printRender.glare.blur = controls.glareSoftness
        parameters.filmRender.halation.boostEv = controls.highlightBoost
        parameters.filmRender.halation.active = controls.halation
        parameters.filmRender.halation.halationAmount = controls.halationAmount
        parameters.filmRender.halation.halationSpatialScale = controls.halationSize
        parameters.filmRender.halation.scatterAmount = controls.scatterAmount
        parameters.filmRender.halation.scatterSpatialScale = controls.scatterSize
        parameters.filmRender.dirCouplers.active = controls.couplers
        parameters.filmRender.dirCouplers.inhibitionInterlayer = controls.couplerSaturation
        parameters.filmRender.dirCouplers.inhibitionSamelayer = controls.couplerEdgeContrast
        parameters.filmRender.grain.active = controls.grain
        parameters.filmRender.grain.particleAreaUm2 = controls.grainSize
        parameters.filmRender.grain.blur = controls.grainSoftness
        parameters.camera.diffusionFilter = controls.cameraDiffusion
        parameters.enlarger.diffusionFilter = controls.enlargerDiffusion
        parameters.applyNeutralPrintFilters(film: film, print: print, database: database)
        if mode == .preview || mode == .thumbnail {
            parameters.applyPreviewMode()
        }
        parameters.applyFilmSpecifics(film)
        return parameters
    }
}
