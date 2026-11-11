#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t (*zt_np3_map_fn)(uint32_t rgb, void* context);
typedef int (*zt_np3_cancel_fn)(void* context);

int zt_np3_apply_rgba(uint8_t* bytes, int width, int height, int rowBytes, int firstRow, int lastRow,
                      uint64_t* memo, int memoMask, zt_np3_map_fn map, void* mapContext,
                      zt_np3_cancel_fn cancelled, void* cancelContext);

#ifdef __cplusplus
}
#endif
