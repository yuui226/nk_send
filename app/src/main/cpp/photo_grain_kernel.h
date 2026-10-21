#ifndef ZTRANSFER_PHOTO_GRAIN_KERNEL_H
#define ZTRANSFER_PHOTO_GRAIN_KERNEL_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include "vendor/fastnoise-lite-1.1.1/FastNoiseLite.h"

namespace ztransfer_grain {

// Spatially correlated, monochrome finishing grain, not a physical emulsion simulator.
// One noise field lives in upright photo space with a fixed reference long edge. A
// lower-resolution preview integrates a pixel footprint instead of enlarging grain.
class Kernel {
public:
    // style IDs match PhotoGrainStyle: fine=0, medium=1, coarse=2.
    Kernel(int width, int height, int orientation, int intensity, int seed, int style = 0)
        : width_(width), height_(height), orientation_(orientation),
          scale_(3000.0 / std::max(width, height)), strength_(intensity / 100.0f), noise_(seed) {
        noise_.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2S);
        const float frequency = style == 1 ? 0.46f : (style == 2 ? 0.32f : 0.65f);
        noise_.SetFrequency(frequency);
        // Keep the original fine expression bit-for-bit, including its sampling
        // thresholds. Larger grains need fewer subpixel samples, not more amplitude.
        const double footprint = style == 0 ? scale_ * 1.1 :
            scale_ * 1.4 * (static_cast<double>(frequency) / 0.65);
        const int desired = std::max(1, static_cast<int>(std::ceil(footprint)));
        samples_ = std::min(4, desired);
        // Very small thumbnails cannot represent this frequency: fade the unresolved
        // portion instead of allowing noise to alias into larger moire patterns.
        attenuation_ = std::min(1.0f, 4.0f / desired);
    }

    void upright(double rawX, double rawY, double& x, double& y) const {
        switch (orientation_) {
            case 2: x = width_ - rawX; y = rawY; break;
            case 3: x = width_ - rawX; y = height_ - rawY; break;
            case 4: x = rawX; y = height_ - rawY; break;
            case 5: x = rawY; y = rawX; break;
            case 6: x = height_ - rawY; y = rawX; break;
            case 7: x = height_ - rawY; y = width_ - rawX; break;
            case 8: x = rawY; y = width_ - rawX; break;
            default: x = rawX; y = rawY; break;
        }
    }

    float noiseAt(int rawX, int rawY) const {
        double uprightX, uprightY;
        upright(rawX + 0.5, rawY + 0.5, uprightX, uprightY);
        const double x = uprightX * scale_, y = uprightY * scale_;
        float total = 0.0f;
        for (int sy = 0; sy < samples_; ++sy) {
            const double dy = ((sy + 0.5) / samples_ - 0.5) * scale_;
            for (int sx = 0; sx < samples_; ++sx) {
                const double dx = ((sx + 0.5) / samples_ - 0.5) * scale_;
                total += noise_.GetNoise(static_cast<float>(x + dx), static_cast<float>(y + dy));
            }
        }
        return total / (samples_ * samples_) * attenuation_;
    }

    uint32_t apply(uint32_t color, int rawX, int rawY) const {
        if (strength_ <= 0.0f || color >> 24 == 0) return color;
        const int r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255;
        // Symmetric RGB headroom prevents clipping from lifting blacks, tinting
        // highlights, or introducing a DC shift in saturated colours. Alpha is untouched.
        const int headroom = std::min(std::min({r, g, b}), 255 - std::max({r, g, b}));
        if (headroom == 0) return color;
        const float luma = (r * 0.2126f + g * 0.7152f + b * 0.0722f) / 255.0f;
        const float tonalWeight = 0.35f + 0.65f * 4.0f * luma * (1.0f - luma);
        const float amplitude = std::min(static_cast<float>(headroom), 24.0f * strength_ * tonalWeight);
        const int delta = std::clamp(static_cast<int>(std::round(noiseAt(rawX, rawY) * amplitude)),
                                     -headroom, headroom);
        return (color & 0xff000000U) | ((r + delta) << 16) | ((g + delta) << 8) | (b + delta);
    }

private:
    int width_, height_, orientation_, samples_;
    double scale_;
    float strength_, attenuation_;
    FastNoiseLite noise_;
};

} // namespace ztransfer_grain
#endif
