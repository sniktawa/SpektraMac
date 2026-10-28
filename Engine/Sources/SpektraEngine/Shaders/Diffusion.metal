#include <metal_stdlib>
using namespace metal;

// The diffusion filter's FFT convolution (apply_diffusion_filter_um), one channel at a time, in
// buffers of the FFT's size, `size` = (width, height), row-major.

// One channel's PSF, unnormalised (the convolution divides by its sum): at whole-pixel offsets
// within `radius` (a square, as Python's kernel), Σ_k weight_k · exp(−r/λ_k) / (2πλ_k²), with
// components[k] = (1/λ_k, weight_k / (2πλ_k²)); placed around index 0, offsets past half the size
// wrapping to the negative ones; 0 elsewhere.
kernel void diffusion_psf(device float *psf [[buffer(0)]],
                          constant uint2 &size [[buffer(1)]],
                          constant int &radius [[buffer(2)]],
                          constant float2 *components [[buffer(3)]],
                          constant uint &count [[buffer(4)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int dx = gid.x > size.x / 2 ? int(gid.x) - int(size.x) : int(gid.x);
    int dy = gid.y > size.y / 2 ? int(gid.y) - int(size.y) : int(gid.y);
    float value = 0.0f;
    if (abs(dx) <= radius && abs(dy) <= radius) {
        float r = sqrt(float(dx * dx + dy * dy));
        for (uint k = 0; k < count; k++) {
            value += components[k].y * exp(-r * components[k].x);
        }
    }
    psf[gid.y * size.x + gid.x] = value;
}

// `channel` of the image reduced by `scale` (each scale × scale block's mean, the last ones
// smaller), extended by `radius` pixels on each side, mirrored about the edge pixels (np.pad's
// `reflect`, which repeats a single row or column), from index 0; 0 past it.
kernel void diffusion_pad(texture2d<float, access::read> image [[texture(0)]],
                          device float *signal [[buffer(0)]],
                          constant uint2 &size [[buffer(1)]],
                          constant int &radius [[buffer(2)]],
                          constant uint &channel [[buffer(3)]],
                          constant int &scale [[buffer(4)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int fullWidth = image.get_width(), fullHeight = image.get_height();
    int width = (fullWidth + scale - 1) / scale, height = (fullHeight + scale - 1) / scale;
    int x = int(gid.x) - radius, y = int(gid.y) - radius;
    float value = 0.0f;
    if (x < width + radius && y < height + radius) {
        x = width == 1 ? 0 : (x < 0 ? -x : (x >= width ? 2 * (width - 1) - x : x));
        y = height == 1 ? 0 : (y < 0 ? -y : (y >= height ? 2 * (height - 1) - y : y));
        int x1 = min((x + 1) * scale, fullWidth), y1 = min((y + 1) * scale, fullHeight);
        for (int j = y * scale; j < y1; j++) {
            for (int i = x * scale; i < x1; i++) {
                value += image.read(uint2(i, j))[channel];
            }
        }
        value /= float((x1 - x * scale) * (y1 - y * scale));
    }
    signal[gid.y * size.x + gid.x] = value;
}

// (1 − amount) · image + amount · blurred for `channel`, in place: the blurred padded channel,
// read `radius` pixels in; reduced by `scale`, between its pixels' centres bilinearly.
kernel void diffusion_blend(texture2d<float, access::read_write> image [[texture(0)]],
                            device const float *blurred [[buffer(0)]],
                            constant uint2 &size [[buffer(1)]],
                            constant int &radius [[buffer(2)]],
                            constant uint &channel [[buffer(3)]],
                            constant float &amount [[buffer(4)]],
                            constant int &scale [[buffer(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
    float4 pixel = image.read(gid);
    float scattered;
    if (scale == 1) {
        scattered = blurred[(gid.y + uint(radius)) * size.x + gid.x + uint(radius)];
    } else {
        // At least radius − 1 (≥ 4) and under the reduced size + radius: inside the padded image.
        float2 position = (float2(gid) + 0.5f) / float(scale) - 0.5f + float(radius);
        float2 corner = floor(position), t = position - corner;
        uint i = uint(corner.y) * size.x + uint(corner.x);
        scattered = mix(mix(blurred[i], blurred[i + 1], t.x), mix(blurred[i + size.x], blurred[i + size.x + 1], t.x), t.y);
    }
    pixel[channel] = (1.0f - amount) * pixel[channel] + amount * scattered;
    image.write(pixel, gid);
}
