#include "photo_grain_kernel.h"
#include <cassert>
#include <vector>
#include <cstdio>
extern "C" void zt_photo_grain_rgba(uint8_t*, int, int, int, int, int, int, int, int, int);

int main() {
    const int w = 173, h = 113, fullHeight = 397, origin = 127;
    for (int style = 0; style < 3; ++style) {
        std::vector<uint8_t> bytes(w * h * 4), expected(bytes.size());
        ztransfer_grain::Kernel kernel(w, fullHeight, 1, 73, -1983457331, style);
        for (int i = 0; i < w * h; ++i) {
            const unsigned a = i % 256;
            for (int c = 0; c < 3; ++c) bytes[i * 4 + c] = ((33 + (i * (c + 1) % 181)) * a + 127) / 255;
            bytes[i * 4 + 3] = a;
        }
        expected = bytes;
        for (int i = 0; i < w * h; ++i) {
            auto* p = expected.data() + i * 4;
            const unsigned a = p[3];
            if (!a) continue;
            const auto straight = [a](unsigned c) { return std::min(255u, (c * 255 + a / 2) / a); };
            const uint32_t color = a << 24 | straight(p[0]) << 16 | straight(p[1]) << 8 | straight(p[2]);
            const auto result = kernel.apply(color, i % w, origin + i / w);
            if (result == color) continue;
            p[0] = (((result >> 16) & 255) * a + 127) / 255;
            p[1] = (((result >> 8) & 255) * a + 127) / 255;
            p[2] = ((result & 255) * a + 127) / 255;
        }
        // Deliberately cross rows and call batches in reverse order.
        for (int start = 16384; start >= 0; start -= 16384)
            zt_photo_grain_rgba(bytes.data(), w, start, std::min(16384, w * h - start), w, fullHeight, origin, 73, -1983457331, style);
        assert(bytes == expected);
    }
    std::puts("RGBA bridge: all three styles, signed seed, alpha 0...255 and reversed batch boundaries match Android kernel");
}
