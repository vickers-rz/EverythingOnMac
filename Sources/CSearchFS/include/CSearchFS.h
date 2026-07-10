#ifndef CSearchFS_h
#define CSearchFS_h

#include <stdint.h>

typedef void (*CSearchFSCallback)(
    uint64_t file_id,
    uint64_t parent_id,
    const char *name,
    int is_directory,
    int64_t size,
    double modification_date,
    void *context
);

#ifdef __cplusplus
extern "C" {
#endif

int scan_volume_catalog(
    const char *volume_path,
    CSearchFSCallback callback,
    void *context
);

#ifdef __cplusplus
}
#endif

#endif /* CSearchFS_h */
