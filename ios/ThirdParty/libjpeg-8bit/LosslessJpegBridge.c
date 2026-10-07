#include "LosslessJpegBridge.h"
#include <stdio.h>
#include "jpeglib.h"
#include "transupp.h"
#include <string.h>

static unsigned exif_u16(const JOCTET *p, int little) { return little ? ((unsigned)p[0] | ((unsigned)p[1] << 8)) : (((unsigned)p[0] << 8) | p[1]); }
static unsigned exif_u32(const JOCTET *p, int little) { return little ? ((unsigned)p[0] | ((unsigned)p[1] << 8) | ((unsigned)p[2] << 16) | ((unsigned)p[3] << 24)) : (((unsigned)p[0] << 24) | ((unsigned)p[1] << 16) | ((unsigned)p[2] << 8) | p[3]); }
static void exif_put32(JOCTET *p, int little, unsigned v) { if (little) { p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; } else { p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; } }
static void update_exif_dimensions(jpeg_saved_marker_ptr m, int width, int height) {
  if (!m || m->marker != JPEG_APP0 + 1 || m->data_length < 14 || memcmp(m->data, "Exif\0\0", 6) != 0) return;
  JOCTET *t = m->data + 6; int little = t[0]=='I' && t[1]=='I'; if (!little && !(t[0]=='M' && t[1]=='M')) return;
  if (exif_u16(t+2,little) != 42) return; unsigned off=exif_u32(t+4,little); if (off+2 > m->data_length-6) return; JOCTET *ifd=t+off; unsigned count=exif_u16(ifd,little);
  if (off+2+count*12 > m->data_length-6) return;
  for (unsigned i=0;i<count;i++) { JOCTET *e=ifd+2+i*12; unsigned tag=exif_u16(e,little); if (tag!=0x0100 && tag!=0x0101 && tag!=0xa002 && tag!=0xa003) continue; unsigned type=exif_u16(e+2,little); unsigned n=exif_u32(e+4,little); unsigned value=(tag==0x0100||tag==0xa002)?(unsigned)width:(unsigned)height; if (n!=1) continue; if (type==3) { if (little) { e[8]=value; e[9]=value>>8; } else { e[8]=value>>8; e[9]=value; } } else if (type==4) exif_put32(e+8,little,value); }
}

int zt_lossless_jpeg_crop(const char *inputPath, const char *outputPath, int width, int height, int mcuWidth, int mcuHeight, int x, int y, int cropWidth, int cropHeight) {
  if (!inputPath || !outputPath || width <= 0 || height <= 0 || mcuWidth <= 0 || mcuHeight <= 0 || x < 0 || y < 0 || cropWidth <= 0 || cropHeight <= 0 || x + cropWidth > width || y + cropHeight > height || x % mcuWidth || y % mcuHeight) return 0;
  FILE *in = fopen(inputPath, "rb"), *out = NULL; struct jpeg_decompress_struct src; struct jpeg_compress_struct dst; struct jpeg_error_mgr se, de; jvirt_barray_ptr *coef = NULL, *dstCoef = NULL; jpeg_transform_info info;
  if (!in) return 0; memset(&src, 0, sizeof(src)); memset(&dst, 0, sizeof(dst)); memset(&info, 0, sizeof(info)); src.err = jpeg_std_error(&se); jpeg_create_decompress(&src); jpeg_save_markers(&src, JPEG_APP0 + 1, 0xFFFF); jpeg_save_markers(&src, JPEG_APP0 + 2, 0xFFFF); jpeg_save_markers(&src, JPEG_COM, 0xFFFF); jpeg_stdio_src(&src, in); jpeg_read_header(&src, TRUE); coef = jpeg_read_coefficients(&src);
  info.transform = JXFORM_NONE; info.crop = TRUE; info.crop_width = cropWidth; info.crop_height = cropHeight; info.crop_xoffset = x; info.crop_yoffset = y; info.crop_width_set = JCROP_POS; info.crop_height_set = JCROP_POS; info.crop_xoffset_set = JCROP_POS; info.crop_yoffset_set = JCROP_POS;
  if (!jtransform_request_workspace(&src, &info)) { jpeg_destroy_decompress(&src); fclose(in); return 0; }
  out = fopen(outputPath, "wb"); if (!out) { jpeg_destroy_decompress(&src); fclose(in); return 0; }
  dst.err = jpeg_std_error(&de); jpeg_create_compress(&dst); jpeg_stdio_dest(&dst, out); jpeg_copy_critical_parameters(&src, &dst); dstCoef = jtransform_adjust_parameters(&src, &dst, coef, &info); if (!dstCoef) { jpeg_destroy_compress(&dst); fclose(out); jpeg_destroy_decompress(&src); fclose(in); return 0; } jpeg_write_coefficients(&dst, dstCoef);
  for (jpeg_saved_marker_ptr marker = src.marker_list; marker; marker = marker->next) {
    update_exif_dimensions(marker, cropWidth, cropHeight);
    jpeg_write_marker(&dst, marker->marker, marker->data, marker->data_length);
  }
  jtransform_execute_transformation(&src, &dst, coef, &info); jpeg_finish_compress(&dst); jpeg_destroy_compress(&dst); fclose(out); jpeg_destroy_decompress(&src); fclose(in); return 1;
}
