#include <metal_stdlib>
using namespace metal;

// ScanningStage._density_to_rgb up to glare: the dye densities viewed under the scan
// illuminant, integrated against the CIE 1931 CMFs (cmf_bands: illuminant × CMF /
// Σ illuminant·ȳ) to XYZ, floored as Python's log10/10^ round trip does.
kernel void scan_xyz(texture2d<float, access::read> cmy [[texture(0)]],
                     texture2d<float, access::write> output [[texture(1)]],
                     constant float4 *dye_bands [[buffer(0)]],
                     constant float4 *cmf_bands [[buffer(1)]],
                     constant uint &band_count [[buffer(2)]],
                     uint2 gid [[thread_position_in_grid]]) {
    float3 xyz = spectral_transmission(cmy.read(gid).rgb, dye_bands, cmf_bands, band_count);
    output.write(float4(fmax(xyz, 0.0f) + 1e-10f, 1.0f), gid);
}

// The scanned-print look (not Spektrafilm's), in linear output RGB: the shadows pushed towards
// `tint` (luminance 1) by `look.y`, fading out by lightness `look.z`, then the blacks lifted to
// `look.x` of white, in the tint's colour as far as the shadows take it. `luma` is the space's Y row.
kernel void scan_look(texture2d<float, access::read> input [[texture(0)]],
                      texture2d<float, access::write> output [[texture(1)]],
                      constant float3 &look [[buffer(0)]],
                      constant float3 &tint [[buffer(1)]],
                      constant float3 &luma [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float3 rgb = input.read(gid).rgb;
    float y = fmax(dot(rgb, luma), 0.0f);
    float shadow = 1.0f - smoothstep(0.0f, look.z, pow(y, 1.0f / 2.4f));
    rgb = mix(rgb, y * tint, look.y * shadow);
    rgb = look.x * mix(float3(1.0f), tint, look.y) + (1.0f - look.x) * rgb;
    output.write(float4(rgb, 1.0f), gid);
}

// compute_random_glare_amount before its blur: per pixel a lognormal sample exp(μ + σ z)
// (fast_lognormal) / 100, in all three channels.
kernel void glare_lognormal(texture2d<float, access::write> output [[texture(0)]],
                            constant uint &seed [[buffer(0)]],
                            constant float2 &mu_sigma [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    Random random(seed, 1, gid);
    float amount = random.lognormal(mu_sigma.x, mu_sigma.y) / 100.0f;
    output.write(float4(float3(amount), 1.0f), gid);
}

// colour-science's cctf_encoding (linear → encoded), the inverse of decode_channel (Filming.metal),
// same `transfer` numbering; `gamma` is the encoding exponent.
inline float encode_channel(float v, uint transfer, float gamma) {
    switch (transfer) {
    case 1: return v <= 0.0031308f ? v * 12.92f : 1.055f * spow(v, 1.0f / 2.4f) - 0.055f;
    case 2: return pow(v, gamma);
    case 3: return v < 0.018f ? v * 4.5f : 1.099f * spow(v, 0.45f) - 0.099f;
    case 4: return v < pow(16.0f, 1.8f / (1.0f - 1.8f)) ? v * 16.0f : spow(v, 1.0f / 1.8f);
    default: return v;
    }
}

// colour's RGB_to_RGB from the output space to itself with encoding: `matrix` (RGB → XYZ → RGB,
// not quite the identity where colour stores a rounded XYZ → RGB matrix), then the transfer function.
kernel void encode_rgb(texture2d<float, access::read> input [[texture(0)]],
                       texture2d<float, access::write> output [[texture(1)]],
                       constant float3x3 &matrix [[buffer(0)]],
                       constant uint &transfer [[buffer(1)]],
                       constant float &gamma [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float3 v = matrix * input.read(gid).rgb;
    output.write(float4(encode_channel(v.r, transfer, gamma), encode_channel(v.g, transfer, gamma),
                        encode_channel(v.b, transfer, gamma), 1.0f), gid);
}

// The encoded output as an image file stores it, three channels in rows without padding: clipped
// to [0, 1] with NaN (outside the colour model) as 0, then × 65535 rounded to nearest even
// (16 bits) or × 255 rounded half up (8 bits). Bit for bit what vImage's vImageConvert_FTo16U
// and vImageConvert_PlanarFtoPlanar8 made of it when saving converted on the CPU (checked for
// every float in [0, 1]).
kernel void pack_rgb16(texture2d<float, access::read> input [[texture(0)]],
                       device ushort *output [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float3 v = input.read(gid).rgb;
    uint pixel = (gid.y * input.get_width() + gid.x) * 3;
    for (uint c = 0; c < 3; c++) {
        output[pixel + c] = isnan(v[c]) ? 0 : ushort(rint(clamp(v[c], 0.0f, 1.0f) * 65535.0f));
    }
}

kernel void pack_rgb8(texture2d<float, access::read> input [[texture(0)]],
                      device uchar *output [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float3 v = input.read(gid).rgb;
    uint pixel = (gid.y * input.get_width() + gid.x) * 3;
    for (uint c = 0; c < 3; c++) {
        output[pixel + c] = isnan(v[c]) ? 0 : uchar(trunc(clamp(v[c], 0.0f, 1.0f) * 255.0f + 0.5f));
    }
}
