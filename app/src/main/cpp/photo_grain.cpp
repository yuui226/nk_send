#include <jni.h>
#include <cstdint>
#include "photo_grain_kernel.h"

namespace {
constexpr int kBatchPixels = 16 * 1024;

void invalid(JNIEnv* env) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Invalid photo grain batch");
}

__attribute__((noinline))
void apply(JNIEnv* env, jintArray pixels, int start, int count, int tileWidth, int pixelOffset,
           int fullWidth, int fullHeight, int originX, int originY, int orientation,
           int intensity, int seed, int style) {
    jint batch[kBatchPixels];
    env->GetIntArrayRegion(pixels, start, count, batch);
    if (env->ExceptionCheck()) return;
    const ztransfer_grain::Kernel kernel(fullWidth, fullHeight, orientation, intensity, seed, style);
    for (int i = 0; i < count; ++i) {
        const int64_t pixel = static_cast<int64_t>(pixelOffset) + i;
        const int x = originX + static_cast<int>(pixel % tileWidth);
        const int y = originY + static_cast<int>(pixel / tileWidth);
        batch[i] = static_cast<jint>(kernel.apply(static_cast<uint32_t>(batch[i]), x, y));
    }
    env->SetIntArrayRegion(pixels, start, count, batch);
}
}

extern "C" JNIEXPORT void JNICALL
Java_com_ztransfer_grain_NativePhotoGrain_applyBatch(JNIEnv* env, jobject, jintArray pixels,
        jint start, jint count, jint tileWidth, jint pixelOffset, jint fullWidth, jint fullHeight,
        jint originX, jint originY, jint orientation, jint intensity, jint seed, jint style) {
    if (!pixels || start < 0 || count < 0 || count > kBatchPixels ||
        count > env->GetArrayLength(pixels) || start > env->GetArrayLength(pixels) - count ||
        tileWidth <= 0 || fullWidth <= 0 || fullHeight <= 0 || originX < 0 || originY < 0 ||
        originX > fullWidth || tileWidth > fullWidth - originX || originY >= fullHeight ||
        pixelOffset < 0 || orientation < 1 || orientation > 8 || intensity < 0 || intensity > 100 ||
        style < 0 || style > 2 ||
        (count > 0 && (static_cast<int64_t>(pixelOffset) + count - 1) / tileWidth >= fullHeight - originY)) {
        invalid(env); return;
    }
    if (count == 0 || intensity == 0) return;
    apply(env, pixels, start, count, tileWidth, pixelOffset, fullWidth, fullHeight,
          originX, originY, orientation, intensity, seed, style);
}
