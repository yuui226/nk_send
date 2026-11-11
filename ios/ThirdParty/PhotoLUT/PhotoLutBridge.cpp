// Opaque sRGB LUT batches. Axis tables and the staged trilinear order match
// Android PhotoCubeMapper / photo_lut.cpp. Rounding matches Swift Float.rounded()
// (schoolbook, ties away from zero) via floor(double + 0.5), which is also
// Android's roundToInt for these non-negative channels. Compiled without
// contraction so values next to an 8-bit boundary do not move.
//
// Pixels are premultiplied RGBA, byteOrder32Big. Alpha 0 is left untouched.
// 0 < alpha < 255 is left untouched and reported so Swift can un-premultiply
// with the original float sampler. Opaque pixels are finished here.

#include <cmath>
#include <cstddef>
#include <cstdint>

namespace {

constexpr int kAxis = 256;

#pragma clang fp contract(off) reassociate(off)
inline float clamp01(float value) {
    if (value < 0.f) return 0.f;
    if (value > 1.f) return 1.f;
    return value;
}

#pragma clang fp contract(off) reassociate(off)
inline float smoothStep(float lower, float upper, float value) {
    const float t = clamp01((value - lower) / (upper - lower));
    return t * t * (3.f - 2.f * t);
}

#pragma clang fp contract(off) reassociate(off)
inline int roundSchoolbook(float value) {
    if (value < 0.f) value = 0.f;
    else if (value > 255.f) value = 255.f;
    return static_cast<int>(std::floor(static_cast<double>(value) + 0.5));
}

#pragma clang fp contract(off) reassociate(off)
inline int quantizeUnit(float value) {
    // Swift UInt32(channel * 255 + 0.5) truncates. Inputs are already in 0...1,
    // so the largest sum is 255.5 and still truncates to 255.
    const float scaled = clamp01(value) * 255.f + 0.5f;
    if (scaled <= 0.f) return 0;
    if (scaled >= 255.f) return 255;
    return static_cast<int>(scaled);
}

#pragma clang fp contract(off) reassociate(off)
inline int channel(const float* data, int p000, int p100, int p010, int p110,
                   int p001, int p101, int p011, int p111, int c, float originalByte,
                   float tx, float ux, float ty, float uy, float tz, float uz, float strength) {
    const float a = data[p000 + c] * ux + data[p100 + c] * tx;
    const float b = data[p010 + c] * ux + data[p110 + c] * tx;
    const float cc = data[p001 + c] * ux + data[p101 + c] * tx;
    const float d = data[p011 + c] * ux + data[p111 + c] * tx;
    const float mixed = (a * uy + b * ty) * uz + (cc * uy + d * ty) * tz;
    const float mappedByte = clamp01(mixed) * 255.f;
    return roundSchoolbook(originalByte + (mappedByte - originalByte) * strength);
}

#pragma clang fp contract(off) reassociate(off)
inline void finish(int& red, int& green, int& blue, float shadowScale, float highlightScale,
                   float contrast, float saturation) {
    float r = static_cast<float>(red) / 255.f;
    float g = static_cast<float>(green) / 255.f;
    float b = static_cast<float>(blue) / 255.f;
    const float luma = clamp01(r * 0.2126f + g * 0.7152f + b * 0.0722f);
    const float shadows = shadowScale * smoothStep(0.f, 0.68f, 1.f - luma);
    const float highlights = highlightScale * smoothStep(0.32f, 1.f, luma);
    r = clamp01(r + shadows + highlights);
    g = clamp01(g + shadows + highlights);
    b = clamp01(b + shadows + highlights);
    r = clamp01((r - 0.5f) * contrast + 0.5f);
    g = clamp01((g - 0.5f) * contrast + 0.5f);
    b = clamp01((b - 0.5f) * contrast + 0.5f);
    const float post = clamp01(r * 0.2126f + g * 0.7152f + b * 0.0722f);
    red = quantizeUnit(post + (r - post) * saturation);
    green = quantizeUnit(post + (g - post) * saturation);
    blue = quantizeUnit(post + (b - post) * saturation);
}

} // namespace

extern "C" {

void zt_photo_lut_prepare(int32_t* offsets, float* weights, int size,
                          float min0, float max0, float min1, float max1, float min2, float max2) {
    const float mins[3] = {min0, min1, min2};
    const float maxs[3] = {max0, max1, max2};
    const int strides[3] = {3, size * 3, size * size * 3};
    for (int channel = 0; channel < 3; ++channel) {
        const float range = maxs[channel] - mins[channel];
        int32_t* low = offsets + channel * 2 * kAxis;
        int32_t* high = low + kAxis;
        float* fraction = weights + channel * 2 * kAxis;
        float* inverse = fraction + kAxis;
        for (int value = 0; value < kAxis; ++value) {
            float coordinate = ((static_cast<float>(value) / 255.f - mins[channel]) / range);
            if (coordinate < 0.f) coordinate = 0.f;
            else if (coordinate > 1.f) coordinate = 1.f;
            coordinate *= static_cast<float>(size - 1);
            const int cell = static_cast<int>(coordinate);
            const int next = cell + 1 < size ? cell + 1 : size - 1;
            low[value] = cell * strides[channel];
            high[value] = next * strides[channel];
            fraction[value] = coordinate - static_cast<float>(cell);
            inverse[value] = 1.f - fraction[value];
        }
    }
}

int zt_photo_lut_apply(uint8_t* pixels, int pixelCount, const int32_t* offsets, const float* weights,
                       const float* rgb, float strength, int finishing, float shadowScale,
                       float highlightScale, float contrast, float saturation) {
    const int32_t* lowR = offsets;
    const int32_t* highR = offsets + kAxis;
    const int32_t* lowG = offsets + 2 * kAxis;
    const int32_t* highG = offsets + 3 * kAxis;
    const int32_t* lowB = offsets + 4 * kAxis;
    const int32_t* highB = offsets + 5 * kAxis;
    const float* txR = weights;
    const float* uxR = weights + kAxis;
    const float* txG = weights + 2 * kAxis;
    const float* uxG = weights + 3 * kAxis;
    const float* txB = weights + 4 * kAxis;
    const float* uxB = weights + 5 * kAxis;
    int partial = 0;
    for (int i = 0; i < pixelCount; ++i) {
        uint8_t* pixel = pixels + static_cast<intptr_t>(i) * 4;
        const unsigned alpha = pixel[3];
        if (alpha == 0) continue;
        if (alpha != 255) {
            partial = 1;
            continue;
        }
        const int r = pixel[0], g = pixel[1], b = pixel[2];
        const int p000 = lowB[b] + lowG[g] + lowR[r];
        const int p100 = lowB[b] + lowG[g] + highR[r];
        const int p010 = lowB[b] + highG[g] + lowR[r];
        const int p110 = lowB[b] + highG[g] + highR[r];
        const int p001 = highB[b] + lowG[g] + lowR[r];
        const int p101 = highB[b] + lowG[g] + highR[r];
        const int p011 = highB[b] + highG[g] + lowR[r];
        const int p111 = highB[b] + highG[g] + highR[r];
        const float tx = txR[r], ux = uxR[r], ty = txG[g], uy = uxG[g], tz = txB[b], uz = uxB[b];
        // Match the Swift mapper: originalByte is (byte / 255) * 255, not the integer byte.
        const float originalR = (static_cast<float>(r) / 255.f) * 255.f;
        const float originalG = (static_cast<float>(g) / 255.f) * 255.f;
        const float originalB = (static_cast<float>(b) / 255.f) * 255.f;
        int red = channel(rgb, p000, p100, p010, p110, p001, p101, p011, p111, 0, originalR, tx, ux, ty, uy, tz, uz, strength);
        int green = channel(rgb, p000, p100, p010, p110, p001, p101, p011, p111, 1, originalG, tx, ux, ty, uy, tz, uz, strength);
        int blue = channel(rgb, p000, p100, p010, p110, p001, p101, p011, p111, 2, originalB, tx, ux, ty, uy, tz, uz, strength);
        if (finishing) finish(red, green, blue, shadowScale, highlightScale, contrast, saturation);
        pixel[0] = static_cast<uint8_t>(red);
        pixel[1] = static_cast<uint8_t>(green);
        pixel[2] = static_cast<uint8_t>(blue);
    }
    return partial;
}

} // extern "C"
