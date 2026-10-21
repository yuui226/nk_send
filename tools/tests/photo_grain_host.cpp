#include "photo_grain_kernel.h"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <vector>

using ztransfer_grain::Kernel;

// Captured from the shipped single-style kernel before adding style selection.
// Multiple scales cover both the direct path and every antialiasing branch.
uint64_t fineBaseline(int width, int height) {
    uint64_t hash = 14695981039346656037ULL;
    for (int seed : {0x5a544752, -37219}) for (int strength : {25, 50, 100})
        for (int orientation : {1, 6, 8}) {
            const Kernel grain(width, height, orientation, strength, seed, 0);
            for (int y = 0; y < 83; ++y) for (int x = 0; x < 113; ++x) {
                const int red = 32 + (x * 13 + y * 3) % 190;
                const int green = 32 + (x * 7 + y * 9) % 190;
                const int blue = 32 + (x * 3 + y * 17) % 190;
                const uint32_t color = 0x7f000000U | (red << 16) | (green << 8) | blue;
                hash ^= grain.apply(color, (x * 43) % width, (y * 37) % height);
                hash *= 1099511628211ULL;
            }
        }
    return hash;
}

double testStyle(int style) {
    const int seed = 0x5a544752;
    const Kernel disabled(6000, 4000, 1, 0, seed, style);
    for (uint32_t color : {0U, 0x00123456U, 0x7f123456U, 0xffffffffU})
        assert(disabled.apply(color, 13, 24) == color);

    const Kernel enabled(6000, 4000, 1, 100, seed, style);
    for (int y = 0; y < 91; ++y) {
        for (int x = 0; x < 113; ++x) {
            for (uint32_t color : {0x00123456U, 0xff000000U, 0xffffffffU, 0xffff0000U})
                assert(enabled.apply(color, x, y) == color);
            const uint32_t source = 0x7f607080U;
            const uint32_t output = enabled.apply(source, x, y);
            assert(output >> 24 == source >> 24);
            const int dr = static_cast<int>((output >> 16) & 255) - 0x60;
            const int dg = static_cast<int>((output >> 8) & 255) - 0x70;
            const int db = static_cast<int>(output & 255) - 0x80;
            assert(dr == dg && dg == db);
        }
    }

    // All eight EXIF transforms map to the identical upright field, including mirrors.
    for (int orientation = 1; orientation <= 8; ++orientation) {
        const bool transpose = orientation >= 5;
        const Kernel raw(4032, 3024, orientation, 100, seed, style);
        const Kernel upright(transpose ? 3024 : 4032, transpose ? 4032 : 3024, 1, 100, seed, style);
        for (int y = 0; y < 3024; y += 97) {
            for (int x = 0; x < 4032; x += 101) {
                double ox, oy;
                raw.upright(x + 0.5, y + 0.5, ox, oy);
                assert(raw.apply(0xff808080U, x, y) ==
                    upright.apply(0xff808080U, static_cast<int>(ox), static_cast<int>(oy)));
            }
        }
    }

    // Stripe origins and invocation order do not enter the noise state.
    constexpr int width = 397, height = 193;
    std::vector<uint32_t> whole(width * height), stripes(width * height);
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x)
            whole[y * width + x] = enabled.apply(0xff808080U, x + 29, y + 67);
    for (int stripe = height - 1; stripe >= 0; stripe -= 13) {
        const Kernel piece(6000, 4000, 1, 100, seed, style);
        for (int y = std::max(0, stripe - 12); y <= stripe; ++y)
            for (int x = 0; x < width; ++x)
                stripes[y * width + x] = piece.apply(0xff808080U, x + 29, y + 67);
    }
    assert(whole == stripes);

    // Flat midtone expectation stays neutral; stronger settings increase energy.
    const Kernel medium(1920, 1280, 1, 50, seed, style), strong(1920, 1280, 1, 100, seed, style);
    const Kernel otherSeed(1920, 1280, 1, 100, seed + 1, style);
    double sum = 0, squares = 0, mediumSquares = 0;
    int changedBySeed = 0;
    for (int y = 0; y < 1280; ++y) {
        for (int x = 0; x < 1920; ++x) {
            const int a = static_cast<int>(strong.apply(0xff808080U, x, y) & 255) - 128;
            const int b = static_cast<int>(medium.apply(0xff808080U, x, y) & 255) - 128;
            sum += a; squares += a * a; mediumSquares += b * b;
            changedBySeed += strong.apply(0xff808080U, x, y) != otherSeed.apply(0xff808080U, x, y);
        }
    }
    const double pixels = 1920.0 * 1280;
    assert(std::abs(sum / pixels) < 0.05);
    assert(squares > mediumSquares * 3.5 && squares < mediumSquares * 4.5);
    assert(changedBySeed > pixels * 0.8);
    std::printf("style=%d midtone mean delta=%.5f, rms=%.3f; seed/strength/alpha/EXIF/stripes passed\n",
                style, sum / pixels, std::sqrt(squares / pixels));

    // Preview footprint integration agrees with downsampling the original grain.
    const Kernel small(1500, 1000, 1, 100, seed, style);
    double previewError = 0;
    for (int y = 0; y < 300; ++y) {
        for (int x = 0; x < 450; ++x) {
            double original = 0;
            for (int sy = 0; sy < 4; ++sy)
                for (int sx = 0; sx < 4; ++sx)
                    original += static_cast<int>(enabled.apply(0xff808080U, x * 4 + sx, y * 4 + sy) & 255);
            const double preview = small.apply(0xff808080U, x, y) & 255;
            const double error = preview - original / 16;
            previewError += error * error;
        }
    }
    const double rmse = std::sqrt(previewError / (450 * 300));
    assert(rmse < 1.5);
    std::printf("style=%d preview vs 4x downsample RMSE=%.3f / 255\n", style, rmse);

    // The 1920-pixel preview crosses a different sampling boundary for coarse grain.
    // Verify it separately so reducing sample count cannot make the preview too harsh.
    const Kernel original3x(5760, 3840, 1, 100, seed, style);
    double threeTimesError = 0;
    for (int y = 0; y < 200; ++y) for (int x = 0; x < 300; ++x) {
        double original = 0;
        for (int sy = 0; sy < 3; ++sy) for (int sx = 0; sx < 3; ++sx)
            original += static_cast<int>(original3x.apply(0xff808080U, x * 3 + sx, y * 3 + sy) & 255);
        const double error = (strong.apply(0xff808080U, x, y) & 255) - original / 9;
        threeTimesError += error * error;
    }
    const double threeTimesRmse = std::sqrt(threeTimesError / (300 * 200));
    assert(threeTimesRmse < 1.5);
    std::printf("style=%d 1920 preview vs 3x downsample RMSE=%.3f / 255\n", style, threeTimesRmse);

    // Normalised adjacent-pixel variation distinguishes grain size from amplitude.
    // Coarse must remain a fine texture, rather than low-frequency cloud shading.
    double variance = 0, edgeEnergy = 0;
    for (int y = 0; y < 300; ++y) for (int x = 0; x < 400; ++x) {
        const double value = enabled.noiseAt(x, y);
        const double edge = enabled.noiseAt(x + 1, y) - value;
        variance += value * value;
        edgeEnergy += edge * edge;
    }
    assert(variance > 0);
    const double relativeEdges = edgeEnergy / variance;
    assert(relativeEdges > 0.1);
    std::printf("style=%d normalised adjacent-pixel variation=%.4f\n", style, relativeEdges);

    // A representative original-photo pass, no large auxiliary pixel allocation.
    const auto started = std::chrono::steady_clock::now();
    uint32_t checksum = 0;
    for (int y = 0; y < 4000; ++y)
        for (int x = 0; x < 6000; ++x)
            checksum ^= enabled.apply(0xff808080U, x, y);
    const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    std::printf("style=%d 24 MP host kernel %.3fs, checksum=%08x\n", style, elapsed, checksum);
    return relativeEdges;
}

int main() {
    assert(fineBaseline(6000, 4000) == 0x33504fdaae41dc60ULL);
    assert(fineBaseline(1920, 1280) == 0xa26cf0ec53b454f3ULL);
    assert(fineBaseline(479, 319) == 0x0a52122b28256274ULL);
    std::puts("Fine grain matches all three pre-style pixel baselines");
    const double fine = testStyle(0), medium = testStyle(1), coarse = testStyle(2);
    assert(fine > medium * 1.3 && medium > coarse * 1.3);
    std::puts("Fine/medium/coarse have distinct spatial scales, independent of intensity");
}
