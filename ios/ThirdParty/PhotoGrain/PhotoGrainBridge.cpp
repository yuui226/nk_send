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
        const int x = i % width;
        const int y = originY + i / width;
        // Opaque JPEG pixels are already straight. Skipping the divide/multiply
        // pair does not change the kernel input or the stored channels.
        if (a == 255) {
            const uint32_t color = 0xff000000u | (static_cast<uint32_t>(p[0]) << 16) |
                (static_cast<uint32_t>(p[1]) << 8) | p[2];
            const uint32_t result = kernel.apply(color, x, y);
            if (result == color) continue;
            p[0] = static_cast<uint8_t>((result >> 16) & 255u);
            p[1] = static_cast<uint8_t>((result >> 8) & 255u);
            p[2] = static_cast<uint8_t>(result & 255u);
            continue;
        }
        const auto straight = [a](unsigned c) { return std::min(255u, (c * 255u + a / 2u) / a); };
        const uint32_t color = (static_cast<uint32_t>(a) << 24) | (straight(p[0]) << 16) |
            (straight(p[1]) << 8) | straight(p[2]);
        const uint32_t result = kernel.apply(color, x, y);
        if (result == color) continue;
        p[0] = static_cast<uint8_t>((((result >> 16) & 255u) * a + 127u) / 255u);
        p[1] = static_cast<uint8_t>((((result >> 8) & 255u) * a + 127u) / 255u);
        p[2] = static_cast<uint8_t>(((result & 255u) * a + 127u) / 255u);
    }
}
