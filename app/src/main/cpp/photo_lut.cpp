#include <jni.h>
#include <cmath>
#include <cstdint>

namespace {
constexpr int kAxisValues = 6 * 256;
constexpr int kAxisBytes = kAxisValues * 4 * 2;
constexpr int kBatch = 16 * 1024;

// Deliberately preserve Kotlin's operation order. FMA/reassociation change rounding near
// 8-bit boundaries; this file is compiled without contraction or fast-math.
inline int channel(const float* data, int p000, int p100, int p010, int p110,
                   int p001, int p101, int p011, int p111, int c, int original,
                   float tx, float ux, float ty, float uy, float tz, float uz, float strength) {
    const float a = data[p000+c] * ux + data[p100+c] * tx;
    const float b = data[p010+c] * ux + data[p110+c] * tx;
    const float cc = data[p001+c] * ux + data[p101+c] * tx;
    const float d = data[p011+c] * ux + data[p111+c] * tx;
    const float mixed = (a * uy + b * ty) * uz + (cc * uy + d * ty) * tz;
    const float clamped = mixed < 0.f ? 0.f : (mixed > 1.f ? 1.f : mixed);
    const float result = clamped * 255.f;
    const float value = original + (result - original) * strength;
    // Equivalent to Float.roundToInt(): nearest, ties toward positive infinity.
    // Do not add 0.5 in float, which can incorrectly round the value just below a tie.
    return static_cast<int>(std::floor(static_cast<double>(value) + 0.5));
}
// Fixed 64 KiB pixel scratch; one worker, cancellation between batches.
__attribute__((noinline))
void runBatch(JNIEnv* env, jintArray pixels, jint start, jint count,
              const int32_t* offsets, const float* weights, const float* data,
              float strength, bool preserveAlpha) {
    jint batch[kBatch];
    env->GetIntArrayRegion(pixels, start, count, batch);
    if (env->ExceptionCheck()) return;
    for (int i = 0; i < count; ++i) {
        const uint32_t color = static_cast<uint32_t>(batch[i]);
        const uint32_t alpha = preserveAlpha ? color >> 24 : 255;
        if (alpha == 0) continue;
        const int r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255;
        const int x0 = offsets[r], x1 = offsets[256+r];
        const int y0 = offsets[512+g], y1 = offsets[768+g];
        const int z0 = offsets[1024+b], z1 = offsets[1280+b];
        const int p000=z0+y0+x0, p100=z0+y0+x1, p010=z0+y1+x0, p110=z0+y1+x1;
        const int p001=z1+y0+x0, p101=z1+y0+x1, p011=z1+y1+x0, p111=z1+y1+x1;
        const float tx=weights[r], ux=weights[256+r], ty=weights[512+g], uy=weights[768+g];
        const float tz=weights[1024+b], uz=weights[1280+b];
        const int red=channel(data,p000,p100,p010,p110,p001,p101,p011,p111,0,r,tx,ux,ty,uy,tz,uz,strength);
        const int green=channel(data,p000,p100,p010,p110,p001,p101,p011,p111,1,g,tx,ux,ty,uy,tz,uz,strength);
        const int blue=channel(data,p000,p100,p010,p110,p001,p101,p011,p111,2,b,tx,ux,ty,uy,tz,uz,strength);
        batch[i] = static_cast<jint>((alpha << 24) | (red << 16) | (green << 8) | blue);
    }
    env->SetIntArrayRegion(pixels, start, count, batch);
}

void invalid(JNIEnv* env) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Invalid LUT batch");
}
}

extern "C" JNIEXPORT void JNICALL
Java_com_ztransfer_filter_NativePhotoLut_mapBatch(JNIEnv* env, jobject, jobject buffer,
        jintArray pixels, jint start, jint count, jfloat strength, jboolean preserveAlpha) {
    if (!buffer || !pixels || start < 0 || count < 0 || count > kBatch ||
        count > env->GetArrayLength(pixels) || start > env->GetArrayLength(pixels) - count ||
        !std::isfinite(strength) || strength < 0.f || strength > 1.f) { invalid(env); return; }
    auto* raw = static_cast<const uint8_t*>(env->GetDirectBufferAddress(buffer));
    const jlong capacity = env->GetDirectBufferCapacity(buffer);
    if (!raw || capacity < kAxisBytes + 24 * 4) { invalid(env); return; }
    const auto* offsets = reinterpret_cast<const int32_t*>(raw);
    const auto* weights = reinterpret_cast<const float*>(raw + kAxisValues * 4);
    const auto* data = reinterpret_cast<const float*>(raw + kAxisBytes);
    // Tables are private, immutable and constructed by PhotoCubeMapper. No JNI calls or
    // Java-array critical sections inside the pixel loop; GC and download can keep running.
    runBatch(env, pixels, start, count, offsets, weights, data, strength, preserveAlpha);
}
