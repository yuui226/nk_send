# libjpeg-turbo 3.1.2

Unmodified source release: https://github.com/libjpeg-turbo/libjpeg-turbo/releases/tag/3.1.2
Archive SHA-256: 8f0012234b464ce50890c490f18194f913a7b1f4e6a03d6644179fa0f867d0cf

Vendored archive is extracted at CMake configuration time, with no network dependency.
Only the static TurboJPEG library is linked into the crop JNI library. SIMD is disabled
for a consistent build without host assembler dependencies; transforms do not decode RGB.
See LICENSE-libjpeg-turbo.md and README.ijg for redistribution terms.
