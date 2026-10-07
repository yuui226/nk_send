#ifndef ZTRANSFER_LOSSLESS_JPEG_BRIDGE_H
#define ZTRANSFER_LOSSLESS_JPEG_BRIDGE_H
#include <stdint.h>
int zt_lossless_jpeg_crop(const char *inputPath, const char *outputPath,
                          int width, int height, int mcuWidth, int mcuHeight,
                          int x, int y, int cropWidth, int cropHeight);
#endif
