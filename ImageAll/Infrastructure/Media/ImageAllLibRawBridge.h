#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns 0 on success. Writes logical pixel size after LibRaw identify.
int ImageAll_LibRawProbePath(
    const char *path,
    int32_t *out_width,
    int32_t *out_height
);

int ImageAll_LibRawProbeBuffer(
    const uint8_t *bytes,
    size_t length,
    int32_t *out_width,
    int32_t *out_height
);

/// Prefers embedded JPEG/bitmap thumb; allocates *out_bytes (caller frees via ImageAll_LibRawFree).
int ImageAll_LibRawDecodeThumbFromPath(
    const char *path,
    uint8_t **out_bytes,
    size_t *out_length,
    int32_t *out_width,
    int32_t *out_height
);

int ImageAll_LibRawDecodeThumbFromBuffer(
    const uint8_t *bytes,
    size_t length,
    uint8_t **out_bytes,
    size_t *out_length,
    int32_t *out_width,
    int32_t *out_height
);

void ImageAll_LibRawFree(void *pointer);

#ifdef __cplusplus
}
#endif
