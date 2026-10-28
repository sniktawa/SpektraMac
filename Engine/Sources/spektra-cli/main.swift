import CoreImage
import Foundation
import SpektraEngine

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "photo":
    // spektra-cli photo <width> <height> <file.jpg>: writes a test photo, the synthetic image below,
    // so tools/benchmark.sh doesn't depend on a photo being there.
    let numbers = arguments.dropFirst().prefix(2).compactMap { Int($0) }
    guard numbers.count == 2, let path = arguments.dropFirst(3).first else { usage() }
    try writeTestPhoto(width: numbers[0], height: numbers[1], to: URL(filePath: path))
case "save":
    // spektra-cli save <photo> <file.jpg> [lens | enlarger]: saves the photo as the app does, timed.
    let paths = Array(arguments.dropFirst())
    let diffusion = paths.count == 3 ? paths[2] : nil
    guard paths.count == 2 || ["lens", "enlarger"].contains(diffusion) else { usage() }
    try await save(URL(filePath: paths[0]), to: URL(filePath: paths[1]), diffusion: diffusion)
case "benchmark":
    if let path = arguments.dropFirst().first, Int(path) == nil {
        // spektra-cli benchmark <photo>: times the app's renders of a photo (the README's figures).
        try await benchmarkRenders(of: URL(filePath: path))
    } else {
        // spektra-cli benchmark [width height]: times each ported stage on a synthetic image.
        let numbers = arguments.dropFirst().compactMap { Int($0) }
        let (width, height) = numbers.count == 2 ? (numbers[0], numbers[1]) : (6000, 4000)
        try benchmark(width: width, height: height)
    }
default:
    print("spektra-cli — port of Spektrafilm at \(SpektraEngine.referenceCommit.prefix(7))")
    print("GPU: \(try GPU().device.name)")
    usage()
}

func usage() -> Never {
    print("""
        Usage: spektra-cli benchmark [width height | photo]
               spektra-cli save <photo> <file.jpg> [lens | enlarger]
               spektra-cli photo <width> <height> <file.jpg>
        """)
    exit(1)
}

/// Saves the photo at `url` as a JPEG at `destination` the way the app does, in a process of its
/// own: opens it, renders the preview, then times ``Engine/export(controls:as:)`` and the write, as
/// the app's Save reports them. The default settings (Portra 400 printed on Portra Endura), with the
/// default diffusion filter (Black Pro-Mist 1/2) on the `lens` or the `enlarger` if asked.
/// tools/benchmark.sh reads the process's peak memory footprint.
func save(_ url: URL, to destination: URL, diffusion: String?) async throws {
    let engine = try Engine()
    _ = try await engine.open(RGBImage.decode(contentsOf: url))
    var controls = Controls()
    controls.cameraDiffusion.active = diffusion == "lens"
    controls.enlargerDiffusion.active = diffusion == "enlarger"
    _ = try await engine.render(controls: controls, mode: .preview)
    let start = ContinuousClock.now
    let image = try await engine.export(controls: controls, as: .jpeg)
    try image.write(to: destination, as: .jpeg, metadata: nil,
                    record: EditRecord(software: "spektra-cli", summary: "", keywords: [], controls: controls))
    // Plain milliseconds, for the script to read in any locale.
    print("save: \(Int(((ContinuousClock.now - start) / .milliseconds(1)).rounded())) ms")
}

/// A smooth gradient with texture: values span the exposure range like a photo.
func syntheticPixel(x: Int, y: Int, width: Int, height: Int) -> SIMD3<Float> {
    SIMD3(Float(x) / Float(width), Float(y) / Float(height), Float((x ^ y) & 255) / 255)
}

/// The synthetic image as an 8-bit sRGB JPEG at quality 0.98, as the app saves one.
func writeTestPhoto(width: Int, height: Int, to url: URL) throws {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = (syntheticPixel(x: x, y: y, width: width, height: height) * 255).rounded(.toNearestOrAwayFromZero)
            let index = (y * width + x) * 4
            bytes[index] = UInt8(pixel.x)
            bytes[index + 1] = UInt8(pixel.y)
            bytes[index + 2] = UInt8(pixel.z)
        }
    }
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let image = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                        format: .RGBA8, colorSpace: sRGB)
    try CIContext().writeJPEGRepresentation(
        of: image, to: url, colorSpace: sRGB,
        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.98])
}

/// The app's renders of `url` with the default settings (Portra 400 printed on Portra Endura): the
/// full render with every effect, as a save makes it, and the live preview that follows each change.
/// The best of several runs, each through every stage.
func benchmarkRenders(of url: URL) async throws {
    let engine = try Engine()
    let image = try RGBImage.decode(contentsOf: url)
    _ = try await engine.open(image)
    print("\(url.lastPathComponent), \(Int(image.extent.width)) × \(Int(image.extent.height)), on \(try GPU().device.name)")
    for (label, mode, runs) in [("full render", RenderMode.full, 3), ("preview", .preview, 10)] {
        var best = Duration.seconds(Int.max)
        for run in 0...runs {
            // A different exposure each time: the engine keeps the film's steps for renders that
            // only change the print, and this times every stage.
            var controls = Controls()
            controls.exposureOffsetEV = Double(run) * 0.01
            let start = ContinuousClock.now
            _ = try await engine.render(controls: controls, mode: mode)
            best = min(best, ContinuousClock.now - start)
        }
        print("\(label): \(best.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 0))))")
    }
}

func benchmark(width: Int, height: Int) throws {
    let gpu = try GPU()
    gpu.heap = gpu.reservedMemory(width: width, height: height)  // as the app does for a full render
    let film = try Profile.load("kodak_portra_400")
    let paper = try Profile.load("kodak_portra_endura")
    var parameters = Parameters()
    parameters.applyNeutralPrintFilters(film: film, print: paper, database: try Tables.loadNeutralPrintFilters())
    parameters.applyFilmSpecifics(film)
    var clock = ContinuousClock.now
    func lap(_ label: String) {
        let now = ContinuousClock.now
        print("\(label.padding(toLength: 40, withPad: " ", startingAt: 0)) \((now - clock).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        clock = now
    }

    let simulation = try Simulation(parameters: parameters, film: film, print: paper, gpu: gpu, tables: Tables.load())
    lap("setup (tc LUT, print constants, C_max)")
    var pixels = [Float](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = syntheticPixel(x: x, y: y, width: width, height: height)
            let index = (y * width + x) * 3
            pixels[index] = pixel.x
            pixels[index + 1] = pixel.y
            pixels[index + 2] = pixel.z
        }
    }
    let image = RGBImage(width: width, height: height, pixels: pixels)
    print("\(width) × \(height) on \(gpu.device.name)")
    clock = .now

    // Stage by stage; the scope frees the stage outputs before the whole chain runs.
    do {
        let rgbPre = try gpu.run { simulation.encodePreprocess(image, on: $0) }
        lap("rgb_in → rgb_pre (AE on CPU, upload)")
        let logEFilm = try gpu.run { simulation.encodeExpose(rgbPre, on: $0) }
        lap("rgb_pre → log_e_film (halation)")
        let cmyFilm = try gpu.run { simulation.encodeDevelop(logEFilm, on: $0) }
        lap("log_e_film → cmy_film (couplers)")
        let logEPrint = try gpu.run { simulation.encodePrintExpose(cmyFilm, on: $0) }
        lap("cmy_film → log_e_print (81 bands)")
        let cmyPrint = try gpu.run { simulation.encodePrintDevelop(logEPrint, on: $0) }
        lap("log_e_print → cmy_print")
        let scanned = try gpu.run { simulation.encodeDensityToRGB(cmyPrint, on: $0) }
        lap("cmy_print → scanned RGB (81 bands)")
        _ = try gpu.run { simulation.encodeOutputCompression(scanned, on: $0) }
        lap("output gamut compression (cam16ucs)")
        print("allocated on the GPU (incl. reserved): \(gpu.device.currentAllocatedSize / 1_000_000) MB")
    }

    // The app's path: the whole chain in one run.
    var peak = 0
    _ = try gpu.run { encoder in
        defer { peak = encoder.peakAllocatedSize }
        return simulation.encode(image, on: encoder)
    }
    lap("whole chain (rgb_in → rgb_out)")
    print("peak in use on the GPU: \(peak / 1_000_000) MB")
}
