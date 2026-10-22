// iOS pixel adapter; the noise kernel and its vendor are byte-identical to
// Android 1f804ab8. Swift owns the buffer and checks cancellation every batch.
#include "photo_grain_kernel.h"
#include <cstddef>

extern "C" void zt_photo_grain_rgba(uint8_t* pixels, int width, int start, int count,
                                   int fullWidth, int fullHeight, int originY,
                                   int intensity, int seed, int style) {
    const ztransfer_grain::Kernel kernel(fullWidth, fullHeight, 1, intensity, seed, style);
    for (int i = start; i < start + count; ++i) {
        uint8_t* p = pixels + static_cast<size_t>(i) * 4;
        const unsigned a = p[3];
        if (a == 0) continue;
        const auto straight = [a](unsigned c) { return std::min(255u, (c * 255u + a / 2u) / a); };
        const uint32_t color = (a << 24) | (straight(p[0]) << 16) | (straight(p[1]) << 8) | straight(p[2]);
        const uint32_t result = kernel.apply(color, i % width, originY + i / width);
        if (result == color) continue;
        p[0] = (((result >> 16) & 255) * a + 127) / 255;
        p[1] = (((result >> 8) & 255) * a + 127) / 255;
        p[2] = ((result & 255) * a + 127) / 255;
    }
}
