/* Compile the production bridge unchanged except for its libc I/O calls.
 * The codec is the same bundled sources used by the iOS app. No test hooks
 * or fault flags are linked into the production application. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "jpeglib.h"
#include "jerror.h"

static int fail_flush, fail_close, last_codec_error;
static void record_codec_error(j_common_ptr codec) {
  last_codec_error = codec->err->msg_code;
  codec->err->output_message(codec);
}
static int is_output(FILE *stream) {
  return (fcntl(fileno(stream), F_GETFL) & O_ACCMODE) != O_RDONLY;
}
static int checked_flush(FILE *stream) {
  if (fail_flush && is_output(stream)) { errno = ENOSPC; return EOF; }
  return fflush(stream);
}
static int checked_close(FILE *stream) {
  int fail = fail_close && is_output(stream);
  int result = fclose(stream);
  if (fail) { errno = EIO; return EOF; }
  return result;
}
#define fflush checked_flush
#define fclose checked_close
/* Keep codec failures visible in the host test log before the production jump. */
#define longjmp(buffer, value) (record_codec_error(cinfo), longjmp(buffer, value))
#include "../ThirdParty/libjpeg-8bit/LosslessJpegBridge.c"
#undef longjmp
#undef fflush
#undef fclose

static void fixture(const char *path) {
  FILE *file = fopen(path, "wb"); assert(file);
  struct jpeg_compress_struct codec;
  struct jpeg_error_mgr error;
  codec.err = jpeg_std_error(&error);
  jpeg_create_compress(&codec);
  jpeg_stdio_dest(&codec, file);
  codec.image_width = 128; codec.image_height = 96;
  codec.input_components = 3; codec.in_color_space = JCS_RGB;
  jpeg_set_defaults(&codec); jpeg_set_quality(&codec, 95, TRUE);
  jpeg_start_compress(&codec, TRUE);
  unsigned char pixels[128 * 3];
  while (codec.next_scanline < codec.image_height) {
    for (int x = 0; x < 128 * 3; x++) pixels[x] = (x * 37 + codec.next_scanline * 71) % 256;
    JSAMPROW row = pixels; jpeg_write_scanlines(&codec, &row, 1);
  }
  jpeg_finish_compress(&codec); jpeg_destroy_compress(&codec);
  assert(fclose(file) == 0);
}
static int crop(const char *in, const char *out) {
  return zt_lossless_jpeg_crop(in, out, 128, 96, 16, 16, 16, 16, 64, 64);
}
int main(void) {
  char directory[] = "/tmp/ztransfer-native-crop-XXXXXX";
  assert(mkdtemp(directory));
  char input[256], output[256], truncated[256];
  snprintf(input, sizeof(input), "%s/source.jpg", directory);
  snprintf(output, sizeof(output), "%s/output.jpg", directory);
  snprintf(truncated, sizeof(truncated), "%s/truncated.jpg", directory);
  fixture(input);
  FILE *file = fopen(input, "rb"); assert(file);
  assert(fseek(file, 0, SEEK_END) == 0); long count = ftell(file); rewind(file);
  unsigned char *bytes = malloc(count); assert(bytes);
  assert(fread(bytes, 1, count, file) == (size_t)count); assert(fclose(file) == 0);
  size_t sos = 0;
  for (size_t i = 2; i + 1 < (size_t)count; i++) {
    if (bytes[i] == 0xff && bytes[i + 1] == 0xda) { sos = i; break; }
  }
  assert(sos && sos + 32 < (size_t)count);
  const size_t lengths[] = {sos + 16, (sos + count) / 2, count - 2};
  for (int i = 0; i < 3; i++) {
    file = fopen(truncated, "wb"); assert(file);
    assert(fwrite(bytes, 1, lengths[i], file) == lengths[i]); assert(fclose(file) == 0);
    assert(!crop(truncated, output)); assert(access(output, F_OK) != 0);
  }
  for (int i = 0; i < 2; i++) {
    fail_flush = i == 0; fail_close = i == 1;
    assert(!crop(input, output)); assert(access(output, F_OK) != 0);
    fail_flush = fail_close = 0;
    assert(crop(input, output)); assert(unlink(output) == 0);
  }
  /* A sparse source at the exact compressed limit is accepted without reading
   * trailing bytes after EOI; one byte above it is rejected before codec work. */
  file = fopen(truncated, "wb"); assert(file);
  assert(fwrite(bytes, 1, count, file) == (size_t)count);
  assert(fflush(file) == 0);
  assert(ftruncate(fileno(file), ZT_MAX_SOURCE_BYTES) == 0);
  assert(fclose(file) == 0);
  assert(crop(truncated, output)); assert(unlink(output) == 0);
  assert(truncate(truncated, ZT_MAX_SOURCE_BYTES + 1) == 0);
  last_codec_error = 0;
  assert(!crop(truncated, output)); assert(last_codec_error == 0);
  assert(access(output, F_OK) != 0);

  /* Legal SOF dimensions at the pixel ceiling need more than the coefficient
   * budget. Verify the allocator refuses backing storage before entropy decode,
   * rather than merely failing later because this synthetic scan is short. */
  unsigned char *large = malloc(count); assert(large); memcpy(large, bytes, count);
  size_t sof = 0;
  for (size_t i = 2; i + 8 < (size_t)count; i++) {
    if (large[i] == 0xff && large[i + 1] == 0xc0) { sof = i; break; }
  }
  assert(sof);
  large[sof + 5] = large[sof + 7] = 10000 >> 8;
  large[sof + 6] = large[sof + 8] = 10000 & 255;
  file = fopen(truncated, "wb"); assert(file);
  assert(fwrite(large, 1, count, file) == (size_t)count); assert(fclose(file) == 0);
  last_codec_error = 0;
  assert(!zt_lossless_jpeg_crop(truncated, output, 10000, 10000, 16, 16, 16, 16, 64, 64));
  assert(last_codec_error == JERR_NO_BACKING_STORE); assert(access(output, F_OK) != 0);
  last_codec_error = 0;
  assert(!zt_lossless_jpeg_crop(truncated, output, 10001, 10000, 16, 16, 16, 16, 64, 64));
  assert(last_codec_error == 0); assert(access(output, F_OK) != 0);
  free(large);
  assert(crop(input, output)); assert(unlink(output) == 0);

  file = fopen(input, "rb"); assert(file);
  unsigned char *after = malloc(count); assert(after);
  assert(fread(after, 1, count, file) == (size_t)count);
  assert(memcmp(bytes, after, count) == 0); assert(fclose(file) == 0);
  free(after); free(bytes);
  assert(unlink(input) == 0); assert(unlink(truncated) == 0); assert(rmdir(directory) == 0);
  puts("PASS: 3 entropy/EOI truncations, flush failure, close failure, retries, source preservation, 256MiB source boundary, 100MP pixel boundary, 192MiB codec budget (ASan/UBSan)");
}
