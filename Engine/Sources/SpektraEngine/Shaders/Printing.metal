#include <metal_stdlib>
using namespace metal;

// Σ over spectral bands of the light a dye layer stack transmits, 10^−(Σ cmy·dye_density + base),
// times a per-band weight (light × sensitivity, or light × CMF). `bands[b]` holds the three dye
// densities in .xyz and the base density in .w; bands with missing data are left out by the host.
inline float3 spectral_transmission(float3 density, constant float4 *bands, constant float4 *weights, uint count) {
    float3 sum = 0.0f;
    for (uint band = 0; band < count; band++) {
        sum += exp10(-(dot(density, bands[band].xyz) + bands[band].w)) * weights[band].xyz;
    }
    return sum;
}

// PrintingStage.expose: per spectral band, the negative transmits 10^−(dye densities + base) of
// the enlarger light, which the paper integrates through its sensitivity (paper_bands holds
// light × sensitivity). Then mid-grey normalisation (factors.x), preflash, print exposure
// (factors.y) and burn, as log10 — Python's log10 → 10^ round trip in between is the identity —
// or with `linear`, before the log (for the enlarger's diffusion filter).
//
// The burn isn't Spektrafilm's: `burn_stops` more where `burn_mask` (.r) is 1, as much less as it
// is under. At 0 stops the mask isn't read and the print is Spektrafilm's to the bit. Nor is the
// vignette (`vignette`: stops, midpoint, softness): that many stops more towards the edges (fewer
// for a reverse vignette), by the distance from the centre, 1 at the corners.
kernel void print_exposure(texture2d<float, access::read> cmy [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           texture2d<float, access::read> burn_mask [[texture(2)]],
                           constant float4 *film_bands [[buffer(0)]],
                           constant float4 *paper_bands [[buffer(1)]],
                           constant uint &band_count [[buffer(2)]],
                           constant float2 &factors [[buffer(3)]],
                           constant float3 &preflash [[buffer(4)]],
                           constant uint &linear [[buffer(5)]],
                           constant float &burn_stops [[buffer(6)]],
                           constant float3 &vignette [[buffer(7)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float3 raw = spectral_transmission(cmy.read(gid).rgb, film_bands, paper_bands, band_count);
    raw = fmax(raw * factors.x + preflash, 0.0f) + 1e-10f;
    float3 exposure = raw * factors.y;
    if (burn_stops != 0.0f) {
        exposure *= exp2(burn_stops * saturate(burn_mask.read(gid).r));
    }
    if (vignette.x != 0.0f) {
        float2 size = float2(output.get_width(), output.get_height());
        float distance = length((float2(gid) + 0.5f) / size * 2.0f - 1.0f) * M_SQRT1_2_F;
        float half_width = 0.5f * vignette.z;
        exposure *= exp2(vignette.x * smoothstep(vignette.y - half_width, vignette.y + half_width, distance));
    }
    output.write(float4(linear ? exposure : log10(fmax(exposure, 0.0f) + 1e-10f), 1.0f), gid);
}

// The burn's mask before it's fitted to the photo's edges: 0 where the film's exposure is under
// `threshold` stops over mid-grey, 1 from a stop above, smoothly between. The exposure is the
// mean of the three layers' (log_e_film is their log10, 0 at mid-grey).
kernel void burn_threshold(texture2d<float, access::read> log_exposure [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           constant float &threshold [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float3 log_e = log_exposure.read(gid).rgb;
    float stops = log2((exp10(log_e.r) + exp10(log_e.g) + exp10(log_e.b)) / 3.0f);
    output.write(float4(smoothstep(threshold, threshold + 1.0f, stops)), gid);
}
