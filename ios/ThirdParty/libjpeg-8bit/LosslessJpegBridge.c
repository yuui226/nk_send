#include "LosslessJpegBridge.h"
#include <stdio.h>
#include "jpeglib.h"
#include "transupp.h"
#include <string.h>
#include <setjmp.h>
#include <stdlib.h>
#include <sys/stat.h>

#define ZT_MAX_SOURCE_BYTES (256ULL * 1024 * 1024)
#define ZT_MAX_PIXELS 100000000ULL
#define ZT_CODEC_MEMORY (192L * 1024 * 1024)

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf setjmp_buffer;
} zt_jpeg_error_mgr;

static void zt_jpeg_error_exit(j_common_ptr cinfo) {
  zt_jpeg_error_mgr *error = (zt_jpeg_error_mgr *)cinfo->err;
  longjmp(error->setjmp_buffer, 1);
}

/* Match Android STOPONWARNING: synthetic EOI and recovered entropy are not
 * acceptable sources for publishing a lossless crop. */
static void zt_jpeg_emit_message(j_common_ptr cinfo, int level) {
  if (level < 0) zt_jpeg_error_exit(cinfo);
}

typedef struct {
  struct jpeg_decompress_struct src;
  struct jpeg_compress_struct dst;
  zt_jpeg_error_mgr error;
  FILE *in, *out;
  int srcCreated, dstCreated, outputCreated, success;
} zt_jpeg_crop_context;

int zt_lossless_jpeg_crop(const char *inputPath, const char *outputPath, int width, int height, int mcuWidth, int mcuHeight, int x, int y, int cropWidth, int cropHeight) {
  if (!inputPath || !outputPath || width <= 0 || height <= 0 || mcuWidth <= 0 || mcuHeight <= 0 || x < 0 || y < 0 || cropWidth <= 0 || cropHeight <= 0 || cropWidth > width || cropHeight > height || x > width - cropWidth || y > height - cropHeight || x % mcuWidth || y % mcuHeight) return 0;
  if ((uint64_t)width * (uint64_t)height > ZT_MAX_PIXELS) return 0;
  /* Error exits use longjmp. Store mutable cleanup state on the heap so its
   * values remain defined after jumping out of a codec operation. */
  zt_jpeg_crop_context *state = calloc(1, sizeof(*state));
  if (!state) return 0;
  struct jpeg_decompress_struct *src = &state->src;
  struct jpeg_compress_struct *dst = &state->dst;
  jpeg_std_error(&state->error.pub);
  state->error.pub.error_exit = zt_jpeg_error_exit;
  state->error.pub.emit_message = zt_jpeg_emit_message;
  if (setjmp(state->error.setjmp_buffer)) goto cleanup;
  state->in = fopen(inputPath, "rb");
  if (!state->in) goto cleanup;
  struct stat sourceStat;
  if (fstat(fileno(state->in), &sourceStat) != 0 || !S_ISREG(sourceStat.st_mode) ||
      sourceStat.st_size <= 0 || (uint64_t)sourceStat.st_size > ZT_MAX_SOURCE_BYTES) goto cleanup;
  src->err = &state->error.pub;
  state->srcCreated = 1;
  jpeg_create_decompress(src);
  src->mem->max_memory_to_use = ZT_CODEC_MEMORY;
  jpeg_save_markers(src, JPEG_APP0 + 2, 0xFFFF);
  jpeg_stdio_src(src, state->in);
  jpeg_read_header(src, TRUE);
  if (src->image_width != (JDIMENSION)width || src->image_height != (JDIMENSION)height ||
      src->max_h_samp_factor * DCTSIZE != mcuWidth || src->max_v_samp_factor * DCTSIZE != mcuHeight) goto cleanup;
  jpeg_transform_info info;
  memset(&info, 0, sizeof(info));
  info.transform = JXFORM_NONE;
  info.crop = TRUE;
  info.crop_width = cropWidth;
  info.crop_height = cropHeight;
  info.crop_xoffset = x;
  info.crop_yoffset = y;
  info.crop_width_set = JCROP_POS;
  info.crop_height_set = JCROP_POS;
  info.crop_xoffset_set = JCROP_POS;
  info.crop_yoffset_set = JCROP_POS;
  if (!jtransform_request_workspace(src, &info)) goto cleanup;
  /* jpegtran requests virtual arrays before reading coefficients realizes
   * them. Nonzero crop origins need this workspace too. */
  jvirt_barray_ptr *coef = jpeg_read_coefficients(src);
  state->out = fopen(outputPath, "wb");
  if (!state->out) goto cleanup;
  state->outputCreated = 1;
  dst->err = &state->error.pub;
  state->dstCreated = 1;
  jpeg_create_compress(dst);
  dst->mem->max_memory_to_use = ZT_CODEC_MEMORY;
  jpeg_stdio_dest(dst, state->out);
  jpeg_copy_critical_parameters(src, dst);
  jvirt_barray_ptr *dstCoef = jtransform_adjust_parameters(src, dst, coef, &info);
  if (!dstCoef) goto cleanup;
  jpeg_write_coefficients(dst, dstCoef);
  for (jpeg_saved_marker_ptr marker = src->marker_list; marker; marker = marker->next) {
    /* Android SAVEMARKERS=4 retains ICC only. APP1 thumbnails and other
     * APP2 payloads (such as an uncropped multi-picture preview) must not leak.
     * Swift rebuilds the explicitly allowed EXIF fields after the transform. */
    if (marker->marker == JPEG_APP0 + 2 && marker->data_length >= 14 &&
        memcmp(marker->data, "ICC_PROFILE\0", 12) == 0) {
      jpeg_write_marker(dst, marker->marker, marker->data, marker->data_length);
    }
  }
  jtransform_execute_transformation(src, dst, coef, &info);
  jpeg_finish_compress(dst);
  if (!jpeg_finish_decompress(src)) goto cleanup;
  if (fflush(state->out) != 0 || ferror(state->out)) goto cleanup;
  int closeResult = fclose(state->out);
  state->out = NULL;
  if (closeResult != 0) goto cleanup;
  state->success = 1;

cleanup:
  if (state->dstCreated) jpeg_destroy_compress(dst);
  if (state->srcCreated) jpeg_destroy_decompress(src);
  if (state->out) fclose(state->out);
  if (state->in) fclose(state->in);
  if (!state->success && state->outputCreated) remove(outputPath);
  int success = state->success;
  free(state);
  return success;
}
