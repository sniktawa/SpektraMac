import Foundation
import Metal
import Testing
@testable import SpektraEngine

/// The samplers of `Shaders/Common.metal`, drawn 512 × 512 times per case by a test-only kernel
/// compiled with them, against the exact distributions' mean and variance. Each case lands in a
/// different branch of its sampler.
@Suite struct RandomTests {
    static let side = 512
    static let kernel = """
        kernel void draw_samples(texture2d<float, access::write> output [[texture(0)]],
                                 constant float4 &parameters [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            Random random(20260515, 7, gid);
            // x: Poisson λ; y: lognormal σ (μ = −σ²/2, so the mean is 1); z: uniform.
            float sigma = parameters.y;
            output.write(float4(random.poisson(parameters.x), random.lognormal(-sigma * sigma / 2.0f, sigma),
                                random.uniform(), 0.0f), gid);
        }
        """

    /// Draws one case: per channel, the samples' mean and variance.
    static func draw(poisson lambda: Float = 0, lognormal sigma: Float = 0) throws -> [(mean: Double, variance: Double)] {
        let gpu = try GPU()
        let source = try String(contentsOf: shaders.appending(component: "Common.metal"), encoding: .utf8) + kernel
        let library = try gpu.device.makeLibrary(source: source, options: nil)
        let pipeline = try gpu.device.makeComputePipelineState(function: library.makeFunction(name: "draw_samples")!)
        let output = gpu.makeTexture(width: side, height: side)
        var parameters = SIMD4<Float>(lambda, sigma, 0, 0)
        try gpu.run { encoder in
            encoder.compute.setComputePipelineState(pipeline)
            encoder.compute.setTexture(output, index: 0)
            encoder.compute.setBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.compute.dispatchThreads(output.size, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        var rgba = [Float](repeating: 0, count: side * side * 4)
        output.getBytes(&rgba, bytesPerRow: side * 16, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        return (0..<3).map { channel in
            let values = stride(from: channel, to: rgba.count, by: 4).map { Double(rgba[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return (mean, values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1))
        }
    }

    /// Mean within 5 standard errors; variance within `varianceTolerance` (relative).
    static func check(_ name: String, _ sample: (mean: Double, variance: Double), mean: Double, variance: Double,
                      varianceTolerance: Double = 0.03) {
        let count = Double(side * side)
        print(String(format: "%@: mean %.5g (exact %.5g), variance %.5g (exact %.5g)",
                     name, sample.mean, mean, sample.variance, variance))
        #expect(abs(sample.mean - mean) <= 5 * (variance / count).squareRoot(), "\(name) mean")
        #expect(abs(sample.variance / variance - 1) <= varianceTolerance, "\(name) variance")
    }

    @Test(arguments: [0.5, 5, 29.5, 30, 200, 5000] as [Float])
    func poisson(lambda: Float) throws {
        let sample = try Self.draw(poisson: lambda)[0]
        Self.check("Poisson(\(lambda))", sample, mean: Double(lambda), variance: Double(lambda))
    }

    @Test func poissonOfZeroIsZero() throws {
        #expect(try Self.draw(poisson: 0)[0] == (0, 0))
    }

    @Test(arguments: [0.3, 0.7] as [Float])
    func lognormal(sigma: Float) throws {
        let sample = try Self.draw(lognormal: sigma)[1]
        let s2 = Double(sigma * sigma)
        Self.check("Lognormal(σ \(sigma))", sample, mean: 1, variance: exp(s2) - 1, varianceTolerance: 0.05)
    }

    @Test func uniform() throws {
        let sample = try Self.draw()[2]
        Self.check("Uniform", sample, mean: 0.5, variance: 1.0 / 12)
    }
}
