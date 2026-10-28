import Foundation
import Testing
@testable import SpektraEngine

/// `golden/` at the repository root, written by `tools/golden.py` and not in the repository (about
/// 550 MB): without it, the parity tests don't run. `SPEKTRA_GOLDEN` names another folder, such as
/// the reference data `tools/check-upstream.sh` makes from another Spektrafilm commit.
let goldenDirectory = ProcessInfo.processInfo.environment["SPEKTRA_GOLDEN"].map { URL(filePath: $0) }
    ?? URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(component: "golden")

/// A file in `golden/`. The data isn't in the repository (see CONTRIBUTING.md), so a test that needs a file
/// that isn't there is skipped.
func goldenFile(_ components: String...) throws -> URL {
    let url = components.reduce(goldenDirectory) { $0.appending(component: $1) }
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        try Test.cancel("\(url.path(percentEncoded: false)) not found: run tools/golden.py to make the reference data (see CONTRIBUTING.md)")
    }
    return url
}

/// One tap of a golden case, e.g. `golden("chart-kodak_portra_400-kodak_portra_endura", "rgb_out")`.
func golden(_ caseName: String, _ tap: String) throws -> NPYArray {
    try NPYArray(contentsOf: goldenFile(caseName, "\(tap).npy"))
}

/// The golden cases `tools/golden.py` writes: four pairs on the chart and on the photo, the photo in
/// preview mode and with the camera's and the enlarger's diffusion filters on, and the rest of
/// the films and papers on the chart.
let goldenCases = ["chart", "photo"].flatMap { input in
    ["kodak_portra_400-kodak_portra_endura", "kodak_vision3_500t-kodak_2383", "fujifilm_velvia_100-scan",
     "kodak_portra_400-scan"]
        .map { "\(input)-\($0)" }
} + ["preview-kodak_portra_400-kodak_portra_endura", "diffusion-kodak_portra_400-kodak_portra_endura"]
    + chartOnlyPairs.map { "chart-\($0)" }

/// golden.py's CHART_PAIRS past the four above, on the chart and the QA oracle only: every other
/// film on its own paper, the other slides scanned, and Portra 400 on every other paper. With them,
/// every film and every paper is checked end to end.
let chartOnlyPairs = [
    "fujifilm_c200-fujifilm_crystal_archive_typeii", "fujifilm_pro_400h-fujifilm_crystal_archive_typeii",
    "fujifilm_xtra_400-fujifilm_crystal_archive_typeii",
    "kodak_ektar_100-kodak_portra_endura", "kodak_gold_200-kodak_portra_endura", "kodak_portra_160-kodak_portra_endura",
    "kodak_portra_800-kodak_portra_endura", "kodak_portra_800_push1-kodak_portra_endura",
    "kodak_portra_800_push2-kodak_portra_endura", "kodak_ultramax_400-kodak_portra_endura",
    "kodak_verita_200d-kodak_2383", "kodak_vision3_50d-kodak_2383", "kodak_vision3_200t-kodak_2383",
    "kodak_vision3_250d-kodak_2383",
    "fujifilm_provia_100f-scan", "kodak_ektachrome_100-scan", "kodak_kodachrome_64-scan",
    "kodak_portra_400-fujifilm_crystal_archive_typeii", "kodak_portra_400-kodak_ektacolor_edge",
    "kodak_portra_400-kodak_endura_premier", "kodak_portra_400-kodak_supra_endura",
    "kodak_portra_400-kodak_ultra_endura", "kodak_portra_400-kodak_2393",
]

/// Whether a case runs the photo's spatial effects (halation and the inhibitor diffusion, through
/// Apple's blur): the photo, and the photo with the diffusion filters.
func hasPhotoEffects(_ caseName: String) -> Bool {
    caseName.hasPrefix("photo") || caseName.hasPrefix("diffusion")
}

/// A case's `params.json`: the digested parameters and what the run measured.
struct GoldenCase: Decodable {
    let film: String
    let print: String?
    let taps: [String]
    let pixelSizeUm: Double
    let autoexposureEv: Double
    let params: Parameters

    /// The print profile the run used (Portra Endura for direct film scans, as golden.py sets).
    func printProfile() throws -> Profile {
        try Profile.load(print ?? "kodak_portra_endura")
    }

    init(_ name: String) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self = try decoder.decode(GoldenCase.self, from: Data(contentsOf: goldenFile(name, "params.json")))
    }
}

extension NPYArray {
    /// An `H × W × 3` array as an image.
    var image: RGBImage { RGBImage(width: shape[1], height: shape[0], pixels: values) }
}

/// Element-wise differences between a result and its reference.
struct Difference: CustomStringConvertible {
    var maxAbsolute: Double = 0
    var meanAbsolute: Double = 0
    /// max |a − b| / max(|b|, floor): relative where the reference is large, absolute near zero.
    var maxRelative: Double = 0

    init<A: BinaryFloatingPoint, B: BinaryFloatingPoint>(_ result: [A], _ reference: [B], floor: Double = 1e-3) {
        precondition(result.count == reference.count, "\(result.count) vs \(reference.count) values")
        var sum = 0.0
        for (a, b) in zip(result, reference) {
            let error = abs(Double(a) - Double(b))
            maxAbsolute = max(maxAbsolute, error)
            maxRelative = max(maxRelative, error / max(abs(Double(b)), floor))
            sum += error
        }
        meanAbsolute = sum / Double(max(result.count, 1))
    }

    var description: String {
        String(format: "max abs %.3g, mean abs %.3g, max rel %.3g", maxAbsolute, meanAbsolute, maxRelative)
    }
}

/// CIE L*a*b* of `xyz` (Y of white = 1) relative to a white of chromaticity `white`.
func lab(fromXYZ xyz: SIMD3<Double>, white: SIMD2<Double>) -> SIMD3<Double> {
    let whiteXYZ = SIMD3(white.x / white.y, 1, (1 - white.x - white.y) / white.y)
    func f(_ t: Double) -> Double {
        t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116
    }
    let r = xyz / whiteXYZ
    let (fx, fy, fz) = (f(r.x), f(r.y), f(r.z))
    return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

/// CIEDE2000 colour difference (Sharma, Wu & Dalal 2005). Custom: no Apple framework exposes it.
func deltaE2000(_ lab1: SIMD3<Double>, _ lab2: SIMD3<Double>) -> Double {
    let (l1, a1, b1) = (lab1.x, lab1.y, lab1.z)
    let (l2, a2, b2) = (lab2.x, lab2.y, lab2.z)
    let cBar = (hypot(a1, b1) + hypot(a2, b2)) / 2
    let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
    let (a1p, a2p) = ((1 + g) * a1, (1 + g) * a2)
    let (c1p, c2p) = (hypot(a1p, b1), hypot(a2p, b2))
    func hue(_ b: Double, _ a: Double) -> Double {
        if a == 0 && b == 0 { return 0 }
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
    let (h1p, h2p) = (hue(b1, a1p), hue(b2, a2p))

    let deltaL = l2 - l1
    let deltaC = c2p - c1p
    var deltaH = 0.0
    if c1p * c2p != 0 {
        deltaH = h2p - h1p
        if deltaH > 180 { deltaH -= 360 } else if deltaH < -180 { deltaH += 360 }
    }
    let deltaBigH = 2 * sqrt(c1p * c2p) * sin(deltaH / 2 * .pi / 180)

    let lBar = (l1 + l2) / 2
    let cBarP = (c1p + c2p) / 2
    var hBar = h1p + h2p
    if c1p * c2p != 0 {
        if abs(h1p - h2p) <= 180 { hBar /= 2 } else if h1p + h2p < 360 { hBar = (hBar + 360) / 2 } else { hBar = (hBar - 360) / 2 }
    }
    let rad = Double.pi / 180
    let t = 1 - 0.17 * cos((hBar - 30) * rad) + 0.24 * cos(2 * hBar * rad)
        + 0.32 * cos((3 * hBar + 6) * rad) - 0.20 * cos((4 * hBar - 63) * rad)
    let deltaTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
    let rC = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7)))
    let sL = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
    let sC = 1 + 0.045 * cBarP
    let sH = 1 + 0.015 * cBarP * t
    let rT = -sin(2 * deltaTheta * rad) * rC
    let (tl, tc, th) = (deltaL / sL, deltaC / sC, deltaBigH / sH)
    return sqrt(tl * tl + tc * tc + th * th + rT * tc * th)
}
