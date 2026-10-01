#include <jni.h>
#include <turbojpeg.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>

// Map compressed input instead of making a Java byte[] plus a native copy. No RGB bitmap is created.
extern "C" JNIEXPORT void JNICALL
Java_com_ztransfer_crop_LosslessJpeg_nativeCrop(JNIEnv* env, jobject, jstring input,
    jstring output, jint width, jint height, jint mcuWidth, jint mcuHeight,
    jint x, jint y, jint w, jint h) {
    const char* inPath = env->GetStringUTFChars(input, nullptr);
    if (!inPath) return;
    int fd = open(inPath, O_RDONLY);
    env->ReleaseStringUTFChars(input, inPath);
    struct stat info{};
    void* mapped = MAP_FAILED;
    tjhandle codec = nullptr;
    unsigned char* result = nullptr;
    size_t resultSize = 0;
    // Copy codec errors before destroying its handle, without pulling in libc++.
    char error[512]{};
    const auto setError = [&](const char* message) {
        snprintf(error, sizeof(error), "%s", message ? message : "JPEG crop failed");
    };
    do {
        if (fd < 0 || fstat(fd, &info) || info.st_size <= 0 || info.st_size > 256LL * 1024 * 1024) {
            setError("Cannot read JPEG source or source exceeds 256 MiB"); break;
        }
        mapped = mmap(nullptr, info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mapped == MAP_FAILED) { setError("Cannot map JPEG source"); break; }
        codec = tj3Init(TJINIT_TRANSFORM);
        if (!codec) { setError("Cannot initialize JPEG crop"); break; }
        if (tj3Set(codec, TJPARAM_MAXMEMORY, 192) ||
            tj3Set(codec, TJPARAM_MAXPIXELS, 100000000) ||
            tj3Set(codec, TJPARAM_STOPONWARNING, 1) ||
            // Keep color profiles but discard the original EXIF thumbnail, which shows uncropped content.
            tj3Set(codec, TJPARAM_SAVEMARKERS, 4) ||
            tj3DecompressHeader(codec, static_cast<unsigned char*>(mapped), info.st_size)) {
            setError(tj3GetErrorStr(codec)); break;
        }
        const int sampling = tj3Get(codec, TJPARAM_SUBSAMP);
        if (sampling < 0 || sampling >= TJ_NUMSAMP || width != tj3Get(codec, TJPARAM_JPEGWIDTH) ||
            height != tj3Get(codec, TJPARAM_JPEGHEIGHT) || mcuWidth != tjMCUWidth[sampling] ||
            mcuHeight != tjMCUHeight[sampling] || x < 0 || y < 0 || w <= 0 || h <= 0 ||
            w > width || h > height || x > width - w || y > height - h ||
            x % mcuWidth || y % mcuHeight) {
            setError("JPEG source does not match confirmed crop"); break;
        }
        tjtransform transform{};
        transform.r = {x, y, w, h};
        transform.op = TJXOP_NONE;
        transform.options = TJXOPT_CROP;
        if (tj3Transform(codec, static_cast<unsigned char*>(mapped), info.st_size,
                         1, &result, &resultSize, &transform)) {
            setError(tj3GetErrorStr(codec)); break;
        }
        const char* outPath = env->GetStringUTFChars(output, nullptr);
        if (!outPath) break;
        FILE* out = fopen(outPath, "wb");
        if (!out) setError("Cannot create crop output");
        else {
            const bool written = fwrite(result, 1, resultSize, out) == resultSize;
            const bool closed = fclose(out) == 0;
            if (!written || !closed) { unlink(outPath); setError("Cannot finish crop output"); }
        }
        env->ReleaseStringUTFChars(output, outPath);
    } while (false);
    if (result) tj3Free(result);
    if (codec) tj3Destroy(codec);
    if (mapped != MAP_FAILED) munmap(mapped, info.st_size);
    if (fd >= 0) close(fd);
    if (error[0] != '\0' && !env->ExceptionCheck()) {
        env->ThrowNew(env->FindClass("java/io/IOException"), error);
    }
}
