#include <metal_stdlib>
using namespace metal;

// MSL has neither log1p nor expm1: Kahan's accurate forms (Goldberg 1991, theorem 4).
inline float log1p_accurate(float x) {
    float u = 1.0f + x;
    return u == 1.0f ? x : log(u) * x / (u - 1.0f);
}
inline float expm1_accurate(float x) {
    float u = exp(x);
    if (u == 1.0f) return x;
    return u - 1.0f == -1.0f ? -1.0f : (u - 1.0f) * x / log(u);
}

// Random numbers for the stochastic kernels (glare, grain). Counter-based, so nothing is stored
// between dispatches and a render is reproducible: each pixel runs its own PCG sequence
// (PCG-RXS-M-XS 32, O'Neill 2014), started at a PCG hash of (seed, stream, pixel) (Jarzynski &
// Olano 2020). All 32-bit: 64-bit multiplies cost the GPU several instructions each. Python draws
// from numba's unseeded generator instead, so only the statistics are comparable.
inline uint pcg_step(uint state) { return state * 747796405u + 2891336453u; }

inline uint pcg_output(uint state) {
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

inline uint pcg_hash(uint value) { return pcg_output(pcg_step(value)); }

struct Random {
    uint state;

    Random(uint seed, uint stream, uint2 pixel)
        : state(pcg_hash(pixel.x ^ pcg_hash(pixel.y ^ pcg_hash(stream ^ pcg_hash(seed))))) {}

    uint next() {
        state = pcg_step(state);
        return pcg_output(state);
    }

    // Uniform in (0, 1): 24 random bits, offset by half a step so neither end is reached.
    float uniform() { return (float(next() >> 8) + 0.5f) / 16777216.0f; }

    // Standard normal (Box–Muller).
    float normal() { return sqrt(-2.0f * log(uniform())) * cospi(2.0f * uniform()); }

    // exp(μ + σ z), as fast_lognormal (σ below 1e-6 is treated as 0).
    float lognormal(float mu, float sigma) { return sigma < 1e-6f ? exp(mu) : exp(mu + sigma * normal()); }

    // Poisson(λ), as fast_poisson: Knuth's product of uniforms below λ = 30, above it the normal
    // approximation rounded and floored at 0. A float rather than a uint, as Python's is an int64:
    // grain on a 1 × 1 photo, a pixel the size of the frame, draws past 2³² particles.
    float poisson(float lambda) {
        if (!(lambda > 0.0f)) return 0.0f;
        if (lambda >= 30.0f) return fmax(rint(lambda + sqrt(lambda) * normal()), 0.0f);
        float limit = exp(-lambda), product = uniform();
        uint count = 0;
        while (product > limit) {
            product *= uniform();
            count++;
        }
        return float(count);
    }
};
