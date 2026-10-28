import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// Spektrafilm's `SimulationPipeline`: the stages between the pipeline taps
/// (`rgb_in → rgb_pre → log_e_film → cmy_film → log_e_print → cmy_print → rgb_out`), encoded on
/// the GPU.
/// Holds GPU resources (the film's LUT texture), so it is not Sendable: the Engine actor owns one.
public struct Simulation {
    /// Seed of the stochastic kernels: fixed, so rendering the same image again draws the same noise.
    static let seed: UInt32 = 20260515

    public let parameters: Parameters
    public let film: Profile
    /// The paper (or print film). Required like in Python, unused when scanning the film directly.
    public let print: Profile
    let gpu: GPU
    let tables: Tables
    let inputColourSpace: Tables.ColourSpace
    /// The film's tc LUT (192 × 192, texel (j, i) = entry (i, j)), built once per film and
    /// parameter set.
    let filmingLUT: any MTLTexture
    /// Input RGB (linear) → XYZ adapted to the film's reference white with CAT16.
    let inputToXYZ: simd_double3x3
    /// The film's density curves shifted so each channel starts at 0 (FilmingStage.develop).
    let filmCurves: [SIMD3<Double>]
    /// The curves before DIR couplers act, such that development with couplers reproduces
    /// `filmCurves` on a uniform grey (`compute_density_curves_before_dir_couplers`).
    let filmCurvesBeforeCouplers: [SIMD3<Double>]
    /// Per spectral band, film dye densities (xyz) and base density (w); bands where the film
    /// data is missing transmit nothing and are left out.
    let printFilmBands: [SIMD4<Float>]
    /// Per band, enlarger light × the paper's sensitivity, matching `printFilmBands`.
    let printPaperBands: [SIMD4<Float>]
    /// Mid-grey normalisation of the print exposure (`_compute_exposure_factor_midgray`).
    let printExposureFactor: Double
    /// Raw paper exposure from the preflash (zero without one).
    let preflashRaw: SIMD3<Double>
    /// The paper's density curves the print develops on (`apply_print_curves_morph`).
    let printDevelopCurves: [SIMD3<Double>]
    /// Per band, the scanned profile's dye and base densities (the print, or the film when
    /// scanning film), and the scan illuminant × CMFs normalised to Y = 1 for the illuminant.
    let scanDyeBands: [SIMD4<Float>]
    let scanCMFBands: [SIMD4<Float>]
    /// Scan XYZ → output RGB: CAT02 from the scan illuminant's white, then the space's matrix.
    let scanToOutput: simd_double3x3
    /// The scan illuminant's XYZ, Y = 1: what glare adds, scaled by its random field.
    let scanWhite: SIMD3<Double>
    /// The output gamut compression and its C_max table on the GPU; nil when it's off.
    let outputCompression: (model: OutputGamutCompression, maxChroma: any MTLBuffer)?
    let outputColourSpace: Tables.ColourSpace
    /// The pixel format of the filming steps' intermediates (see ``init(parameters:film:print:gpu:tables:cache:intermediateFormat:)``).
    let intermediateFormat: MTLPixelFormat

    public struct UnknownColourSpace: LocalizedError {
        public let name: String
        public var errorDescription: String? { "Unknown colour space \(name)" }
    }

    /// `cache` keeps the costliest tables for the next simulation built with it.
    ///
    /// `intermediateFormat` is the pixel format of the filming steps' intermediates: half floats by
    /// default. Their blurs and blends are most of a full render's memory traffic, which halves:
    /// 376 ms instead of 497 for 24 MP on an M1 Pro. The steps' results, log exposure and density,
    /// stay full floats, as do printing and scanning: half floats' steps on a log scale (up to
    /// 0.002) grow visible through the print, and would coarsen 16-bit exports' gradations.
    /// Renders move by about a level (8-bit) at most; grain draws differently but alike. Full
    /// floats (`.rgba32Float`) track Python's f64 to its parity tests' limits.
    public init(parameters: Parameters, film: Profile, print: Profile, gpu: GPU, tables: Tables,
                cache: SimulationCache = SimulationCache(), intermediateFormat: MTLPixelFormat = .rgba16Float) throws {
        guard let inputColourSpace = tables.colourSpaces[parameters.io.inputColorSpace] else {
            throw UnknownColourSpace(name: parameters.io.inputColorSpace)
        }
        self.parameters = parameters
        self.film = film
        self.print = print
        self.gpu = gpu
        self.tables = tables
        self.inputColourSpace = inputColourSpace
        self.intermediateFormat = intermediateFormat

        let lutKey = SimulationCache.FilmingLUTKey(
            film: film.info.stock, adaptationWindow: parameters.settings.applyHanatos2025AdaptationWindow,
            inputGamutCompress: parameters.io.inputGamutCompress)
        let (lut, size): ([SIMD3<Double>], Int)
        if let cached = cache.filmingLUTs[lutKey] {
            (lut, size, filmingLUT) = (cached.values, cached.texture.width, cached.texture)
        } else {
            let spectra = try cache.spectra ?? Tables.loadSpectraLUT()
            cache.spectra = spectra
            lut = filmingTCLUT(film: film, parameters: parameters, tables: tables, spectra: spectra)
            size = spectra.shape[0]
            filmingLUT = gpu.upload(rgb: lut.flatMap { [Float($0.x), Float($0.y), Float($0.z)] }, width: size, height: size)
            cache.filmingLUTs[lutKey] = (lut, filmingLUT)
        }

        let minimum = film.data.densityCurves.reduce(SIMD3(repeating: Double.infinity)) { pointwiseMin($0, $1) }
        filmCurves = film.data.densityCurves.map { $0 - minimum }
        filmCurvesBeforeCouplers = curvesBeforeCouplers(
            filmCurves, logExposure: film.data.logExposure,
            couplers: parameters.filmRender.dirCouplers.matrix, positive: film.info.type == .positive)

        let white = tables.chromaticity(of: tables.illuminants[film.info.referenceIlluminant]!)
        func toFilmXYZ(_ space: Tables.ColourSpace) -> simd_double3x3 {
            vonKries(from: space.whitepoint, to: white, transform: tables.chromaticAdaptation["CAT16"]!)
                * simd_double3x3(rows: space.rgbToXYZ)
        }
        inputToXYZ = toFilmXYZ(inputColourSpace)

        // Printing constants (PrintingStage._film_cmy_to_print_log_raw).
        let sensitivity = print.data.sensitivity
        let lamp = tables.illuminants[parameters.enlarger.illuminant]!
        let light = enlargerLight(lamp, filters: parameters.enlarger.printFilters, dichroics: tables.dichroicFilters)
        // Bands where a profile's density data is missing transmit nothing (density_to_light).
        func validBands(_ profile: Profile) -> [Int] {
            profile.data.channelDensity.indices.filter { band in
                let density = profile.data.channelDensity[band]
                return !(density.x.isNaN || density.y.isNaN || density.z.isNaN || profile.data.baseDensity[band].isNaN)
            }
        }
        let valid = validBands(film)
        printFilmBands = valid.map { band in
            let density = SIMD3<Float>(film.data.channelDensity[band])
            return SIMD4(density, Float(film.data.baseDensity[band]))
        }
        printPaperBands = valid.map { SIMD4(SIMD3<Float>(light[$0] * sensitivity[$0]), 0) }

        // Raw paper exposure of a film density spectrum: Σ_λ 10^−D(λ) · light(λ) · sensitivity(λ),
        // NaN light counting as none (density_to_light).
        func paperRaw(_ spectrum: [Double], light: [Double]) -> SIMD3<Double> {
            (0..<spectrum.count).reduce(SIMD3<Double>.zero) { sum, band in
                let transmitted = pow(10, -spectrum[band]) * light[band]
                return transmitted.isNaN ? sum : sum + transmitted * sensitivity[band]
            }
        }
        // The film density spectrum of an sRGB grey, developed on the stock curves
        // (FilmingStage._simple_rgb_to_density_spectral).
        let srgbToFilmXYZ = toFilmXYZ(tables.colourSpaces["sRGB"]!)
        let gamma = parameters.filmRender.densityCurveGamma
        let exposureAxis = film.data.logExposure.map { $0 / gamma }
        func densitySpectrum(grey: Double) -> [Double] {
            let raw = hanatos2025Raw(SIMD3(repeating: grey), toXYZ: srgbToFilmXYZ, lut: lut, size: size)
            var cmy = SIMD3<Double>.zero
            for channel in 0..<3 {
                cmy[channel] = interp(log10(raw[channel] + 1e-10), exposureAxis,
                                      film.data.densityCurves.map { $0[channel] })
            }
            return zip(film.data.channelDensity, film.data.baseDensity).map { (cmy * $0).sum() + $1 }
        }
        // 1 / geometric mean of the paper's raw exposure to a negative of that grey.
        func midgrayFactor(_ spectrum: [Double]) -> Double {
            let raw = pointwiseMax(paperRaw(spectrum, light: light), SIMD3(repeating: 1e-10))
            return 1 / exp((log(raw.x) + log(raw.y) + log(raw.z)) / 3)
        }
        let enlarger = parameters.enlarger
        let factor = midgrayFactor(densitySpectrum(grey: 0.184))
        let compensated = enlarger.printExposureCompensation
            ? midgrayFactor(densitySpectrum(grey: 0.184 * pow(2, parameters.camera.exposureCompensationEv))) : 1
        printExposureFactor = switch (enlarger.normalizePrintExposure, enlarger.printExposureCompensation) {
        case (true, true): compensated
        case (true, false): factor
        case (false, true): compensated / factor
        case (false, false): 1
        }

        printDevelopCurves = printCurves(print.data.densityCurvesModel, logExposure: print.data.logExposure,
                                         morph: parameters.printRender.densityCurvesMorph,
                                         positive: print.info.type == .positive)

        // Scanning constants (ScanningStage._return_callable_cmy_to_log_xyz, _density_to_rgb).
        let scanned = parameters.io.scanFilm ? film : print
        guard let outputSpace = tables.colourSpaces[parameters.io.outputColorSpace] else {
            throw UnknownColourSpace(name: parameters.io.outputColorSpace)
        }
        let scanLight = tables.illuminants[scanned.info.viewingIlluminant]!
        let normalization = zip(scanLight, tables.cmfs).reduce(0) { $0 + $1.0 * $1.1.y }
        let scanBands = validBands(scanned)
        scanDyeBands = scanBands.map { SIMD4(SIMD3<Float>(scanned.data.channelDensity[$0]), Float(scanned.data.baseDensity[$0])) }
        scanCMFBands = scanBands.map { SIMD4(SIMD3<Float>(scanLight[$0] * tables.cmfs[$0] / normalization), 0) }
        scanWhite = zip(scanLight, tables.cmfs).reduce(SIMD3<Double>.zero) { $0 + $1.0 * $1.1 } / normalization
        outputColourSpace = outputSpace
        scanToOutput = simd_double3x3(rows: outputSpace.xyzToRGB)
            * vonKries(from: SIMD2(scanWhite.x, scanWhite.y) / scanWhite.sum(), to: outputSpace.whitepoint,
                       transform: tables.chromaticAdaptation["CAT02"]!)
        let compressionKey = SimulationCache.OutputCompressionKey(
            space: parameters.io.outputColorSpace, spec: parameters.io.outputGamutCompress)
        if parameters.io.outputGamutCompress.algorithm == "off" {
            outputCompression = nil
        } else if let cached = cache.outputCompressions[compressionKey] {
            outputCompression = cached
        } else {
            let compression = OutputGamutCompression(spec: parameters.io.outputGamutCompress, space: outputSpace,
                                                     cat16: tables.chromaticAdaptation["CAT16"]!)
            let table = compression.maxChroma.map(Float.init)
            let buffer = gpu.device.makeBuffer(bytes: table, length: table.count * MemoryLayout<Float>.stride,
                                               options: .storageModeShared)!
            outputCompression = (compression, buffer)
            cache.outputCompressions[compressionKey] = (compression, buffer)
        }

        if enlarger.preflashExposure > 0 {
            let preflashLight = enlargerLight(lamp, filters: enlarger.preflashFilters, dichroics: tables.dichroicFilters)
            preflashRaw = paperRaw(film.data.baseDensity, light: preflashLight) * enlarger.preflashExposure
        } else {
            preflashRaw = .zero
        }
    }

    private func intermediate(width: Int, height: Int) -> any MTLTexture {
        gpu.makeTexture(width: width, height: height, pixelFormat: intermediateFormat)
    }

    /// `rgb_in → rgb_pre`: applies auto-exposure, `autoExposureEV` measured on the same image
    /// (``autoExposureEV(of:colourSpace:cctfDecoding:)`` in this simulation's input space). (Python's
    /// preprocess also crops and upscales; both are off by default and not ported.) Only reads
    /// `input`, which the engine keeps across renders.
    public func encodePreprocess(_ input: any MTLTexture, autoExposureEV: Double,
                                 on encoder: Encoder) -> any MTLTexture {
        guard parameters.camera.autoExposure else { return input }
        let output = intermediate(width: input.width, height: input.height)
        gpu.encodeScale(on: encoder, input: input, output: output, by: pow(2, autoExposureEV))
        return output
    }

    /// `rgb_in → rgb_pre` for an image not yet on the GPU: uploads and measures it.
    public func encodePreprocess(_ image: RGBImage, on encoder: Encoder) -> any MTLTexture {
        let ev = parameters.camera.autoExposure
            ? autoExposureEV(of: image, colourSpace: inputColourSpace, cctfDecoding: parameters.io.inputCctfDecoding) : 0
        return encodePreprocess(gpu.upload(rgb: image.pixels, width: image.width, height: image.height),
                                autoExposureEV: ev, on: encoder)
    }

    /// `rgb_pre → log_e_film` (FilmingStage.expose): the film's raw exposure through the
    /// hanatos2025 tc LUT, × 2^exposure compensation, highlight boost, the camera's diffusion
    /// filter, lens blur, scatter and halation, as log10.
    ///
    /// The scanner's black/white correction factor is 1 unless those corrections are on (not
    /// ported yet; off by default).
    public func encodeExpose(_ rgb: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        // `light` holds the current result; each step that can works on it in place.
        var light = intermediate(width: rgb.width, height: rgb.height)
        var matrix = simd_float3x3(inputToXYZ)
        var transfer = parameters.io.inputCctfDecoding ? inputColourSpace.transferIndex : 0
        var gamma = Float(inputColourSpace.gamma ?? 1)
        var exposure = Float(pow(2, parameters.camera.exposureCompensationEv))
        gpu.encode("hanatos2025_raw", on: encoder, textures: [rgb, light, filmingLUT], grid: light.size) {
            $0.setBytes(&matrix, length: MemoryLayout<simd_float3x3>.size, index: 0)
            $0.setBytes(&transfer, length: 4, index: 1)
            $0.setBytes(&gamma, length: 4, index: 2)
            $0.setBytes(&exposure, length: 4, index: 3)
        }
        let halation = parameters.filmRender.halation
        let pixelSizeUm = pixelSizeUm(of: rgb)
        if halation.boostEv > 0 {
            light = gpu.encodeBoostHighlights(on: encoder, input: light, boostEv: halation.boostEv,
                                              boostRange: halation.boostRange, protectEv: halation.protectEv)
        }
        light = gpu.encodeDiffusionFilter(on: encoder, input: light, filter: parameters.camera.diffusionFilter,
                                          pixelSizeUm: pixelSizeUm)
        if parameters.camera.lensBlurUm > 0 {
            gpu.encodeGaussianBlur(on: encoder, input: light, output: light,
                                   sigma: SIMD3(repeating: parameters.camera.lensBlurUm / pixelSizeUm))
        }
        if halation.active {
            light = gpu.encodeHalation(on: encoder, input: light, halation: halation, pixelSizeUm: pixelSizeUm)
        }
        // The result, on a log scale: full floats.
        let logExposure = gpu.makeTexture(width: light.width, height: light.height)
        gpu.encodeLogExposure(on: encoder, input: light, output: logExposure)
        return logExposure
    }

    /// `log_e_film → cmy_film` (FilmingStage.develop): log exposure → CMY dye density through the
    /// film's characteristic curves (normalised to start at 0, exposure axis ÷ density_curve_gamma),
    /// with DIR couplers: the silver formed releases inhibitors (matrix: donor layer → receiving
    /// layer) that diffuse (Gaussian + exponential tail) and lower each layer's effective exposure,
    /// which is then developed again on the pre-coupler curves.
    /// Then grain (``encodeGrain(_:pixelSizeUm:on:)``) when it's on.
    public func encodeDevelop(_ logExposure: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        let density = encodeDevelopDensity(logExposure, on: encoder)
        guard parameters.filmRender.grain.active else { return density }
        return encodeGrain(density, pixelSizeUm: pixelSizeUm(of: logExposure), on: encoder)
    }

    private func encodeDevelopDensity(_ logExposure: any MTLTexture,
                                      on encoder: Encoder) -> any MTLTexture {
        let (width, height) = (logExposure.width, logExposure.height)
        let gamma = parameters.filmRender.densityCurveGamma
        let axis = film.data.logExposure.map { SIMD3(repeating: $0 / gamma) }
        // The result, on a log scale: full floats.
        let density = gpu.makeTexture(width: width, height: height)
        gpu.encodeInterpolate(on: encoder, input: logExposure, output: density, axis: axis, values: filmCurves)
        let couplers = parameters.filmRender.dirCouplers
        guard couplers.active else { return density }

        // Exposure correction Σ_k silver_k · M[k, m]: silver is the density for negatives and
        // d_max − density for positives (inhibitors act at silver development).
        // Rows of Mᵀ are M's columns (simd subscripts are columns).
        let matrix = couplers.matrix
        let rows = [matrix[0], matrix[1], matrix[2]]
        let correction = intermediate(width: width, height: height)
        if film.info.type == .positive {
            let densityMax = filmCurves.reduce(SIMD3(repeating: -Double.infinity)) { pointwiseMax($0, $1) }
            gpu.encodeMatrix(on: encoder, input: density, output: correction, rows: rows.map { -$0 },
                             offset: matrix.transpose * densityMax)
        } else {
            gpu.encodeMatrix(on: encoder, input: density, output: correction, rows: rows)
        }

        if couplers.diffusionSizeUm > 0 {
            // The diffused correction, its Gaussian core and exponential tail blended, replaces it.
            let pixelSizeUm = pixelSizeUm(of: logExposure)
            let (core, tail) = (intermediate(width: width, height: height), intermediate(width: width, height: height))
            gpu.encodeGaussianBlur(on: encoder, input: correction, output: core,
                                   sigma: SIMD3(repeating: couplers.diffusionSizeUm / pixelSizeUm))
            gpu.encodeExponentialBlur(on: encoder, input: correction, output: tail,
                                      decay: SIMD3(repeating: couplers.diffusionTailUm / pixelSizeUm))
            let tailWeight = SIMD3(repeating: couplers.diffusionTailWeight)
            gpu.encodeWeightedSum(on: encoder, core, times: 1 - tailWeight, plus: tail, times: tailWeight, output: correction)
        }
        // The corrected exposure into the density's texture (full floats: it's a log exposure),
        // developed there.
        gpu.encodeWeightedSum(on: encoder, logExposure, times: SIMD3(repeating: 1),
                              plus: correction, times: SIMD3(repeating: -1), output: density)
        gpu.encodeInterpolate(on: encoder, input: density, output: density, axis: axis, values: filmCurvesBeforeCouplers)
        return density
    }
}

extension Simulation {
    /// `apply_grain`, sub-layer model: each channel's density is split over the film's three
    /// sensitivity sub-layers through their density curves, and each sub-layer develops as a random
    /// count of particles (`layer_particle_model`, kernel `grain_layer`), the counts per pixel set
    /// by the pixel's area and the particles' (`particle_area_um2` × scales, each sub-layer's share
    /// of the channel's maximum density), its dye clouds blurred by `blur_dye_clouds_um` · √(density
    /// per particle) pixels. The sub-layers add up, × the micro-structure's clumping (only below
    /// ~0.6 µm pixels), less the fog (`density_min`), then the final blur.
    func encodeGrain(_ density: any MTLTexture, pixelSizeUm: Double,
                     on encoder: Encoder) -> any MTLTexture {
        let grain = parameters.filmRender.grain
        let (width, height) = (density.width, density.height)
        let layers = film.data.densityCurvesLayers
        let layerMaxima = (0..<3).map { layer in
            layers.reduce(SIMD3(repeating: -Double.infinity)) { pointwiseMax($0, $1[layer]) }
        }
        let total = layerMaxima.reduce(SIMD3<Double>.zero, +)
        let fog = SIMD3(grain.densityMin)
        let particleArea = grain.particleAreaUm2 * SIMD3(grain.particleScale)
        // interp_density_cmy_layers: positives interpolate on −density.
        var source = density
        var axis = filmCurves
        if film.info.type == .positive {
            source = intermediate(width: width, height: height)
            gpu.encodeScale(on: encoder, input: density, output: source, by: -1)
            axis = filmCurves.map { -$0 }
        }
        // The first sub-layer's grain develops into the sum (the result, a density: full floats), the
        // others into one texture added to it.
        let (layerDensity, sum, layerGrain) = (intermediate(width: width, height: height),
                                               gpu.makeTexture(width: width, height: height),
                                               intermediate(width: width, height: height))
        for layer in 0..<3 {
            let share = layerMaxima[layer] / total
            var layerFog = SIMD3<Float>(share * fog)
            var layerMax = SIMD3<Float>(layerMaxima[layer] + share * fog)
            let particleCount = pixelSizeUm * pixelSizeUm * share / (particleArea * grain.particleScaleLayers[layer])
            var particles = SIMD3<Float>(particleCount)
            var uniformity = SIMD3<Float>(SIMD3(grain.uniformity))
            var (seed, index) = (Self.seed, UInt32(layer))
            gpu.encodeInterpolate(on: encoder, input: source, output: layerDensity, axis: axis,
                                  values: layers.map { $0[layer] })
            let grainOut = layer == 0 ? sum : layerGrain
            gpu.encode("grain_layer", on: encoder, textures: [layerDensity, grainOut], grid: grainOut.size) {
                $0.setBytes(&layerFog, length: MemoryLayout<SIMD3<Float>>.size, index: 0)
                $0.setBytes(&layerMax, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
                $0.setBytes(&particles, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
                $0.setBytes(&uniformity, length: MemoryLayout<SIMD3<Float>>.size, index: 3)
                $0.setBytes(&seed, length: 4, index: 4)
                $0.setBytes(&index, length: 4, index: 5)
            }
            if grain.blurDyeCloudsUm > 0 {
                // In pixels, as Python passes it: blur_dye_clouds_um · √(d_max / n).
                let densityPerParticle = (layerMaxima[layer] + share * fog) / particleCount
                gpu.encodeGaussianBlur(on: encoder, input: grainOut, output: grainOut,
                                       sigma: grain.blurDyeCloudsUm * densityPerParticle.squareRoot())
            }
            if layer > 0 {
                gpu.encodeWeightedSum(on: encoder, sum, times: SIMD3(repeating: 1),
                                      plus: layerGrain, times: SIMD3(repeating: 1), output: sum)
            }
        }
        // add_micro_structure: clumping, an independent lognormal factor of mean 1 per pixel and
        // channel with σ = micro_structure[1] nm in pixels, blurred by micro_structure[0] µm.
        let clumpingBlur = grain.microStructure[0] / pixelSizeUm
        let clumpingDeviation = grain.microStructure[1] * 0.001 / pixelSizeUm
        if clumpingDeviation > 0.05 {
            let sigma2 = log(1 + clumpingDeviation * clumpingDeviation)
            var muSigma = SIMD2<Float>(Float(-sigma2 / 2), Float(sigma2.squareRoot()))
            var seed = Self.seed
            var clumping = intermediate(width: width, height: height)
            gpu.encode("lognormal_rgb", on: encoder, textures: [clumping], grid: clumping.size) {
                $0.setBytes(&seed, length: 4, index: 0)
                $0.setBytes(&muSigma, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            }
            if clumpingBlur > 0.4 {
                let blurred = intermediate(width: width, height: height)
                gpu.encodeGaussianBlur(on: encoder, input: clumping, output: blurred,
                                       sigma: SIMD3(repeating: clumpingBlur))
                clumping = blurred
            }
            gpu.encodeMultiply(on: encoder, a: sum, b: clumping, output: sum)
        }
        gpu.encodeMatrix(on: encoder, input: sum, output: sum,
                         rows: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], offset: -fog)
        if grain.blur > 0 {
            gpu.encodeGaussianBlur(on: encoder, input: sum, output: sum, sigma: SIMD3(repeating: grain.blur))
        }
        return sum
    }

    /// ResizingService.pixel_size_um (no crop or upscale): the film format's long side over the
    /// image's.
    func pixelSizeUm(of texture: any MTLTexture) -> Double {
        parameters.camera.filmFormatMm * 1000 / Double(max(texture.width, texture.height))
    }
}

extension Simulation {
    /// `cmy_film → log_e_print` (PrintingStage.expose): the enlarger light through the negative's
    /// dye densities and base, integrated against the paper's spectral sensitivity over 81 bands,
    /// normalised so a mid-grey negative gives the paper a unit exposure, plus preflash, × print
    /// exposure and the burn (not Spektrafilm's) through `burnMask` (``encodeBurnMask(_:on:)``),
    /// through the enlarger's diffusion filter, as log10.
    ///
    /// Not ported: the scanner's black/white correction (factor 1 unless on; off by default).
    public func encodePrintExpose(_ cmy: any MTLTexture, burnMask: (any MTLTexture)? = nil,
                                  on encoder: Encoder) -> any MTLTexture {
        let output = gpu.makeTexture(width: cmy.width, height: cmy.height)
        let filter = parameters.enlarger.diffusionFilter
        var bandCount = UInt32(printFilmBands.count)
        var factors = SIMD2<Float>(Float(printExposureFactor), Float(parameters.enlarger.printExposure))
        var preflash = SIMD3<Float>(preflashRaw)
        // Without a mask, 0 stops: the kernel leaves the burn out (and reads `cmy` in the mask's place).
        var burnStops = burnMask == nil ? 0 : Float(parameters.enlarger.burn?.stops ?? 0)
        // The filter spreads the exposure itself, so the kernel leaves the log to after it.
        var linear = UInt32(filter.active ? 1 : 0)
        let vignette = parameters.enlarger.vignette
        var vignetteValues = SIMD3<Float>(Float(vignette?.stops ?? 0), Float(vignette?.midpoint ?? 0),
                                          Float(vignette?.softness ?? 0))
        gpu.encode("print_exposure", on: encoder, textures: [cmy, output, burnMask ?? cmy], grid: output.size) {
            $0.setBytes(printFilmBands, length: printFilmBands.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            $0.setBytes(printPaperBands, length: printPaperBands.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            $0.setBytes(&bandCount, length: 4, index: 2)
            $0.setBytes(&factors, length: MemoryLayout<SIMD2<Float>>.size, index: 3)
            $0.setBytes(&preflash, length: MemoryLayout<SIMD3<Float>>.size, index: 4)
            $0.setBytes(&linear, length: 4, index: 5)
            $0.setBytes(&burnStops, length: 4, index: 6)
            $0.setBytes(&vignetteValues, length: MemoryLayout<SIMD3<Float>>.size, index: 7)
        }
        guard filter.active else { return output }
        gpu.encodeLogExposure(on: encoder, input: gpu.encodeDiffusionFilter(on: encoder, input: output, filter: filter,
                                                                            pixelSizeUm: pixelSizeUm(of: cmy)),
                              output: output)
        return output
    }

    /// The long side the burn's mask is fitted on, whatever the image's size, so the preview, the
    /// screen-size render and the whole photo burn alike.
    static let burnMaskLongSide = 256

    /// Where the burn falls (not Spektrafilm's), 0 to 1 in `.r`, from the film's log exposure: what's
    /// over the threshold (``Parameters/Burn``), fitted to the photo's edges by Apple's guided
    /// filter, so a dark head against a bright sky stays out of it while the whole sky, clouds and
    /// all, burns alike. The fit runs on the image at ``burnMaskLongSide`` and is drawn back at full
    /// size along the full image's edges. Nil when there's no burn.
    public func encodeBurnMask(_ logExposure: any MTLTexture, on encoder: Encoder) -> (any MTLTexture)? {
        guard let burn = parameters.enlarger.burn, burn.stops != 0 else { return nil }
        let scale = min(1, Double(Self.burnMaskLongSide) / Double(max(logExposure.width, logExposure.height)))
        let small = gpu.makeTexture(width: max(1, Int((Double(logExposure.width) * scale).rounded())),
                                    height: max(1, Int((Double(logExposure.height) * scale).rounded())))
        let bright = gpu.makeTexture(width: small.width, height: small.height, pixelFormat: .r32Float)
        let coefficients = gpu.makeTexture(width: small.width, height: small.height)
        let mask = gpu.makeTexture(width: logExposure.width, height: logExposure.height, pixelFormat: .r32Float)
        encoder.encodeCommands {
            MPSImageLanczosScale(device: gpu.device).encode(commandBuffer: $0, sourceTexture: logExposure,
                                                            destinationTexture: small)
        }
        var threshold = Float(burn.threshold)
        gpu.encode("burn_threshold", on: encoder, textures: [small, bright], grid: small.size) {
            $0.setBytes(&threshold, length: 4, index: 0)
        }
        // A window of 9 of the 256 pixels (3.5 % of the long side); ε in (log10 exposure)²: edges
        // under about 0.2 stops are smoothed over.
        let filter = MPSImageGuidedFilter(device: gpu.device, kernelDiameter: 9)
        filter.epsilon = 0.004
        encoder.encodeCommands {
            filter.encodeRegression(to: $0, sourceTexture: bright, guidanceTexture: small, weightsTexture: nil,
                                    destinationCoefficientsTexture: coefficients)
            filter.encodeReconstruction(to: $0, guidanceTexture: logExposure, coefficientsTexture: coefficients,
                                        destinationTexture: mask)
        }
        return mask
    }
}

extension Simulation {
    /// `log_e_print → cmy_print` (PrintingStage.develop, `develop_print_morph`): the paper's log
    /// exposure → CMY dye density through its (optionally morphed) fitted curves.
    public func encodePrintDevelop(_ logExposure: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        let density = gpu.makeTexture(width: logExposure.width, height: logExposure.height)
        gpu.encodeInterpolate(on: encoder, input: logExposure, output: density,
                              axis: print.data.logExposure.map { SIMD3(repeating: $0) }, values: printDevelopCurves)
        return density
    }
}

extension Simulation {
    /// `rgb_in → rgb_out`: filming, printing (skipped when scanning the film itself) and scanning.
    public func encode(_ image: RGBImage, on encoder: Encoder) -> any MTLTexture {
        let logExposure = encodeExpose(encodePreprocess(image, on: encoder), on: encoder)
        return encodePrintAndScan(encodeDevelop(logExposure, on: encoder),
                                  burnMask: encodeBurnMask(logExposure, on: encoder), on: encoder)
    }

    /// `cmy_film → rgb_out`: printing (skipped when scanning the film itself), burned through
    /// `burnMask`, and scanning. Only reads `cmyFilm`.
    public func encodePrintAndScan(_ cmyFilm: any MTLTexture, burnMask: (any MTLTexture)? = nil,
                                   on encoder: Encoder) -> any MTLTexture {
        let cmy = parameters.io.scanFilm
            ? cmyFilm : encodePrintDevelop(encodePrintExpose(cmyFilm, burnMask: burnMask, on: encoder), on: encoder)
        return encodeScan(cmy, on: encoder)
    }

    /// `cmy_print` (or `cmy_film` when scanning film) → `rgb_out` (ScanningStage.scan): to linear
    /// output RGB, gamut compression, the scanner's lens blur and unsharp mask, and encoding.
    public func encodeScan(_ cmy: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        let rgb = encodeScanLook(encodeOutputCompression(encodeDensityToRGB(cmy, on: encoder), on: encoder),
                                 on: encoder)
        return encodeOutputEncoding(encodeScannerOptics(rgb, on: encoder), on: encoder)
    }

    /// The scanned-print look (``Parameters/ScanLook``, not Spektrafilm's), in place in `rgb`.
    public func encodeScanLook(_ rgb: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        guard let look = parameters.scanner.look else { return rgb }
        let luma = SIMD3<Double>(outputColourSpace.rgbToXYZ[1])
        // The hue at 60% saturation in the output space, scaled to luminance 1.
        let hue = look.shadowHue.truncatingRemainder(dividingBy: 360) / 60
        let channel = { (n: Double) in
            let k = (n + hue).truncatingRemainder(dividingBy: 6)
            return 1 - max(0, min(k, 4 - k, 1))
        }
        let colour = SIMD3<Double>(repeating: 0.4) + 0.6 * SIMD3(channel(5), channel(3), channel(1))
        var tint = SIMD3<Float>(colour / (colour * luma).sum())
        var values = SIMD3<Float>(Float(look.blackLevel), Float(look.shadowAmount), Float(look.shadowRange))
        var lumaValues = SIMD3<Float>(luma)
        gpu.encode("scan_look", on: encoder, textures: [rgb, rgb], grid: rgb.size) {
            $0.setBytes(&values, length: MemoryLayout<SIMD3<Float>>.size, index: 0)
            $0.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
            $0.setBytes(&lumaValues, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
        }
        return rgb
    }

    /// `cmy_print` (or `cmy_film` when scanning film) → linear RGB in the output colour space
    /// (ScanningStage._density_to_rgb before output gamut compression): the dyes viewed under the
    /// profile's viewing illuminant, integrated to XYZ, plus print glare, adapted (CAT02) and
    /// converted to RGB.
    ///
    /// Not ported: the scanner's black/white correction (off by default).
    public func encodeDensityToRGB(_ cmy: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        let xyz = gpu.makeTexture(width: cmy.width, height: cmy.height)
        var bandCount = UInt32(scanDyeBands.count)
        gpu.encode("scan_xyz", on: encoder, textures: [cmy, xyz], grid: xyz.size) {
            $0.setBytes(scanDyeBands, length: scanDyeBands.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            $0.setBytes(scanCMFBands, length: scanCMFBands.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            $0.setBytes(&bandCount, length: 4, index: 2)
        }
        // add_glare: only on prints (Python passes no glare when scanning film).
        let glare = parameters.printRender.glare
        if !parameters.io.scanFilm && glare.active && glare.percent > 0 {
            let amount = gpu.encodeGlareAmount(on: encoder, width: cmy.width, height: cmy.height, glare: glare,
                                               seed: Self.seed)
            gpu.encodeWeightedSum(on: encoder, xyz, times: SIMD3(repeating: 1), plus: amount, times: scanWhite, output: xyz)
        }
        gpu.encodeMatrix(on: encoder, input: xyz, output: xyz, rows: (0..<3).map { scanToOutput.transpose[$0] })
        return xyz
    }

    /// Linear output RGB → the same, compressed into the output RGB cube
    /// (ScanningStage._density_to_rgb's `compress_rgb`), in place in `rgb`.
    public func encodeOutputCompression(_ rgb: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        guard let outputCompression else { return rgb }
        return gpu.encodeOutputCompression(outputCompression.model, maxChroma: outputCompression.maxChroma,
                                           on: encoder, rgb: rgb)
    }

    /// The scanner's lens blur, then its unsharp mask: `rgb + amount · (rgb − blur(rgb, σ))`
    /// (ScanningStage._apply_blur_and_unsharp), in place in `rgb`.
    public func encodeScannerOptics(_ rgb: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        if parameters.scanner.lensBlur > 0 {
            gpu.encodeGaussianBlur(on: encoder, input: rgb, output: rgb, sigma: SIMD3(repeating: parameters.scanner.lensBlur))
        }
        let (sigma, amount) = (parameters.scanner.unsharpMask[0], parameters.scanner.unsharpMask[1])
        if sigma > 0 && amount > 0 {
            // rgb + amount · (rgb − blur) as (1 + amount) · rgb − amount · blur, in one pass.
            let blurred = gpu.makeTexture(width: rgb.width, height: rgb.height)
            gpu.encodeGaussianBlur(on: encoder, input: rgb, output: blurred, sigma: SIMD3(repeating: sigma))
            gpu.encodeWeightedSum(on: encoder, rgb, times: SIMD3(repeating: 1 + amount),
                                  plus: blurred, times: SIMD3(repeating: -amount), output: rgb)
        }
        return rgb
    }

    /// The output colour space's transfer function (ScanningStage._apply_cctf_encoding: colour's
    /// RGB_to_RGB from the space to itself), in place in `rgb`.
    public func encodeOutputEncoding(_ rgb: any MTLTexture, on encoder: Encoder) -> any MTLTexture {
        guard parameters.io.outputCctfEncoding else { return rgb }
        // RGB → XYZ → RGB: up to 9e-5 off the identity where colour's XYZ → RGB matrix is the
        // rounded published one (sRGB, Adobe RGB, ProPhoto). Its CAT02 between the space's white
        // and itself is the identity up to rounding, so left out.
        var matrix = simd_float3x3(simd_double3x3(rows: outputColourSpace.xyzToRGB)
                                   * simd_double3x3(rows: outputColourSpace.rgbToXYZ))
        var transfer = outputColourSpace.transferIndex
        var gamma = Float(1 / (outputColourSpace.gamma ?? 1))
        gpu.encode("encode_rgb", on: encoder, textures: [rgb, rgb], grid: rgb.size) {
            $0.setBytes(&matrix, length: MemoryLayout<simd_float3x3>.size, index: 0)
            $0.setBytes(&transfer, length: 4, index: 1)
            $0.setBytes(&gamma, length: 4, index: 2)
        }
        return rgb
    }
}

/// `compute_density_curves_before_dir_couplers`, f64: shifts each curve's exposure axis by the
/// inhibition a uniform grey of that density would cause, and resamples on the original axis.
func curvesBeforeCouplers(_ curves: [SIMD3<Double>], logExposure: [Double], couplers: simd_double3x3,
                          positive: Bool) -> [SIMD3<Double>] {
    let densityMax = curves.reduce(SIMD3(repeating: -Double.infinity)) { pointwiseMax($0, $1) }
    // silver · M, row vector times matrix.
    let shifted = zip(curves, logExposure).map { density, exposure in
        SIMD3(repeating: exposure) - (positive ? densityMax - density : density) * couplers
    }
    var corrected = curves
    for channel in 0..<3 {
        let xp = shifted.map { $0[channel] }
        let fp = curves.map { positive ? -$0[channel] : $0[channel] }
        for (index, exposure) in logExposure.enumerated() {
            let value = interp(exposure, xp, fp)
            corrected[index][channel] = positive ? -value : value
        }
    }
    return corrected
}

/// colour-science's `matrix_chromatic_adaptation_VonKries` between two xy whites (Y = 1).
func vonKries(from source: SIMD2<Double>, to destination: SIMD2<Double>, transform rows: [SIMD3<Double>]) -> simd_double3x3 {
    func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> { SIMD3(xy.x / xy.y, 1, (1 - (xy.x + xy.y)) / xy.y) }
    let m = simd_double3x3(rows: rows)
    let gain = (m * xyz(destination)) / (m * xyz(source))
    return m.inverse * simd_double3x3(diagonal: gain) * m
}

extension GPU {
    /// `compute_random_glare_amount`: per pixel a lognormal amount with mean `percent` / 100 and
    /// standard deviation `roughness · percent` / 100 (`fast_lognormal_from_mean_std`), blurred by
    /// `blur` pixels; the same value in all three channels.
    func encodeGlareAmount(on encoder: Encoder, width: Int, height: Int,
                           glare: Parameters.Glare, seed: UInt32) -> any MTLTexture {
        let (mean, deviation) = (glare.percent, glare.roughness * glare.percent)
        let sigma2 = log(1 + deviation * deviation / (mean * mean))
        var muSigma = SIMD2<Float>(Float(log(mean) - sigma2 / 2), Float(sigma2.squareRoot()))
        var seed = seed
        let amount = makeTexture(width: width, height: height)
        encode("glare_lognormal", on: encoder, textures: [amount], grid: amount.size) {
            $0.setBytes(&seed, length: 4, index: 0)
            $0.setBytes(&muSigma, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        }
        guard glare.blur > 0 else { return amount }
        let blurred = makeTexture(width: width, height: height)
        encodeGaussianBlur(on: encoder, input: amount, output: blurred, sigma: SIMD3(repeating: glare.blur))
        return blurred
    }
}

/// What building a ``Simulation`` costs most — the hanatos2025 spectra, each film's tc LUT and
/// each output space's C_max table — kept for the next simulation built with the same inputs:
/// the app builds one per change of a control. The GPU copies are only ever read, so simulations
/// share them.
public final class SimulationCache {
    struct FilmingLUTKey: Hashable {
        let film: String
        let adaptationWindow: Bool
        let inputGamutCompress: Parameters.InputGamutCompressSpec
    }

    struct OutputCompressionKey: Hashable {
        let space: String
        let spec: Parameters.OutputGamutCompressSpec
    }

    var spectra: NPYArray?
    var filmingLUTs: [FilmingLUTKey: (values: [SIMD3<Double>], texture: any MTLTexture)] = [:]
    var outputCompressions: [OutputCompressionKey: (model: OutputGamutCompression, maxChroma: any MTLBuffer)] = [:]

    public init() {}
}
