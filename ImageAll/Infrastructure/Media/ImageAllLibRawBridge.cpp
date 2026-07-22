#include "ImageAllLibRawBridge.h"

#include "libraw/libraw.h"

#include <stdlib.h>
#include <string.h>

static int copy_thumb(libraw_data_t *raw, uint8_t **out_bytes, size_t *out_length, int32_t *out_width, int32_t *out_height)
{
    if (!raw || !out_bytes || !out_length || !out_width || !out_height) {
        return -1;
    }
    *out_bytes = NULL;
    *out_length = 0;
    *out_width = 0;
    *out_height = 0;

    int err = libraw_unpack_thumb(raw);
    if (err != LIBRAW_SUCCESS) {
        return err;
    }

    libraw_processed_image_t *thumb = libraw_dcraw_make_mem_thumb(raw, &err);
    if (!thumb || err != LIBRAW_SUCCESS) {
        if (thumb) {
            libraw_dcraw_clear_mem(thumb);
        }
        return err != 0 ? err : -2;
    }

    size_t length = (size_t)thumb->data_size;
    uint8_t *copy = (uint8_t *)malloc(length);
    if (!copy) {
        libraw_dcraw_clear_mem(thumb);
        return -3;
    }
    memcpy(copy, thumb->data, length);
    *out_bytes = copy;
    *out_length = length;
    *out_width = (int32_t)thumb->width;
    *out_height = (int32_t)thumb->height;
    libraw_dcraw_clear_mem(thumb);
    return 0;
}

int ImageAll_LibRawProbePath(const char *path, int32_t *out_width, int32_t *out_height)
{
    if (!path || !out_width || !out_height) {
        return -1;
    }
    *out_width = 0;
    *out_height = 0;
    libraw_data_t *raw = libraw_init(0);
    if (!raw) {
        return -2;
    }
    int err = libraw_open_file(raw, path);
    if (err != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return err;
    }
    *out_width = (int32_t)raw->sizes.iwidth;
    *out_height = (int32_t)raw->sizes.iheight;
    if (*out_width <= 0 || *out_height <= 0) {
        *out_width = (int32_t)raw->sizes.width;
        *out_height = (int32_t)raw->sizes.height;
    }
    libraw_close(raw);
    return (*out_width > 0 && *out_height > 0) ? 0 : -3;
}

int ImageAll_LibRawProbeBuffer(const uint8_t *bytes, size_t length, int32_t *out_width, int32_t *out_height)
{
    if (!bytes || length == 0 || !out_width || !out_height) {
        return -1;
    }
    *out_width = 0;
    *out_height = 0;
    libraw_data_t *raw = libraw_init(0);
    if (!raw) {
        return -2;
    }
    int err = libraw_open_buffer(raw, bytes, length);
    if (err != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return err;
    }
    *out_width = (int32_t)raw->sizes.iwidth;
    *out_height = (int32_t)raw->sizes.iheight;
    if (*out_width <= 0 || *out_height <= 0) {
        *out_width = (int32_t)raw->sizes.width;
        *out_height = (int32_t)raw->sizes.height;
    }
    libraw_close(raw);
    return (*out_width > 0 && *out_height > 0) ? 0 : -3;
}

int ImageAll_LibRawDecodeThumbFromPath(
    const char *path,
    uint8_t **out_bytes,
    size_t *out_length,
    int32_t *out_width,
    int32_t *out_height
) {
    if (!path) {
        return -1;
    }
    libraw_data_t *raw = libraw_init(0);
    if (!raw) {
        return -2;
    }
    int err = libraw_open_file(raw, path);
    if (err != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return err;
    }
    err = copy_thumb(raw, out_bytes, out_length, out_width, out_height);
    libraw_close(raw);
    return err;
}

int ImageAll_LibRawDecodeThumbFromBuffer(
    const uint8_t *bytes,
    size_t length,
    uint8_t **out_bytes,
    size_t *out_length,
    int32_t *out_width,
    int32_t *out_height
) {
    if (!bytes || length == 0) {
        return -1;
    }
    libraw_data_t *raw = libraw_init(0);
    if (!raw) {
        return -2;
    }
    int err = libraw_open_buffer(raw, bytes, length);
    if (err != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return err;
    }
    err = copy_thumb(raw, out_bytes, out_length, out_width, out_height);
    libraw_close(raw);
    return err;
}

void ImageAll_LibRawFree(void *pointer)
{
    free(pointer);
}
