// Exact-color NP3 scan. Android PhotoFilterRenderer keeps one 2^20-slot memo on
// the original-quality path: a repeated sRGB color is stored and reused, and a
// hash collision recomputes instead of approximating. The Swift engine still
// owns the color math and is called only on a miss. This file only walks
// premultiplied RGBA and preserves that byte rounding.
//
// One memo belongs to one worker. Entries are not synchronized.

#include <cstddef>
#include <cstdint>

extern "C" {

typedef uint32_t (*zt_np3_map_fn)(uint32_t rgb, void* context);
typedef int (*zt_np3_cancel_fn)(void* context);

int zt_np3_apply_rgba(uint8_t* bytes, int width, int height, int rowBytes, int firstRow, int lastRow,
                      uint64_t* memo, int memoMask, zt_np3_map_fn map, void* mapContext,
                      zt_np3_cancel_fn cancelled, void* cancelContext) {
    if (firstRow < 0) firstRow = 0;
    if (lastRow > height) lastRow = height;
    for (int y = firstRow; y < lastRow; ++y) {
        if (cancelled(cancelContext)) return 1;
        uint8_t* row = bytes + static_cast<intptr_t>(y) * rowBytes;
        for (int x = 0; x < width; ++x) {
            if ((x & 4095) == 0 && cancelled(cancelContext)) return 1;
            uint8_t* pixel = row + static_cast<intptr_t>(x) * 4;
            const uint32_t alpha = pixel[3];
            if (alpha == 0) continue;
            const uint32_t red = (static_cast<uint32_t>(pixel[0]) * 255u + alpha / 2u) / alpha;
            const uint32_t green = (static_cast<uint32_t>(pixel[1]) * 255u + alpha / 2u) / alpha;
            const uint32_t blue = (static_cast<uint32_t>(pixel[2]) * 255u + alpha / 2u) / alpha;
            const uint32_t rgb = ((red > 255u ? 255u : red) << 16) |
                ((green > 255u ? 255u : green) << 8) |
                (blue > 255u ? 255u : blue);
            // Android ExactRgbMemo: 32-bit wrapped multiply by the golden-ratio constant.
            const uint32_t mixed = rgb * 0x9E3779B9u;
            const uint32_t index = (mixed ^ (mixed >> 16)) & static_cast<uint32_t>(memoMask);
            const uint64_t entry = memo[index];
            uint32_t mapped;
            if (static_cast<uint32_t>(entry >> 32) == rgb + 1u) {
                mapped = static_cast<uint32_t>(entry & 0xffffffu);
            } else {
                mapped = map(rgb, mapContext) & 0xffffffu;
                memo[index] = (static_cast<uint64_t>(rgb + 1u) << 32) | mapped;
            }
            pixel[0] = static_cast<uint8_t>(((mapped >> 16) * alpha + 127u) / 255u);
            pixel[1] = static_cast<uint8_t>((((mapped >> 8) & 255u) * alpha + 127u) / 255u);
            pixel[2] = static_cast<uint8_t>(((mapped & 255u) * alpha + 127u) / 255u);
        }
    }
    return cancelled(cancelContext) ? 1 : 0;
}

} // extern "C"
