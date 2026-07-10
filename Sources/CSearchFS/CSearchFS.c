#include "include/CSearchFS.h"
#include <stdio.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <errno.h>
#include <stdlib.h>

struct SearchParam {
    uint32_t length;
    uint64_t fileId;
};

struct ResultEntry {
    uint32_t length;
    attrreference_t nameRef;
    fsobj_type_t objType;
    struct timespec modTime;
    uint64_t fileId;
    uint64_t parentId;
    off_t fileSize;
};

int scan_volume_catalog(
    const char *volume_path,
    CSearchFSCallback callback,
    void *context
) {
    struct attrlist returnAttrList;
    memset(&returnAttrList, 0, sizeof(returnAttrList));
    returnAttrList.bitmapcount = ATTR_BIT_MAP_COUNT;
    returnAttrList.commonattr = ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID | ATTR_CMN_PARENTID;
    returnAttrList.fileattr = ATTR_FILE_TOTALSIZE;

    struct fssearchblock searchBlock;
    memset(&searchBlock, 0, sizeof(searchBlock));
    searchBlock.searchattrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    searchBlock.searchattrs.commonattr = ATTR_CMN_FILEID;

    struct SearchParam lower;
    lower.length = sizeof(lower);
    lower.fileId = 1;

    struct SearchParam upper;
    upper.length = sizeof(upper);
    upper.fileId = ULLONG_MAX;

    searchBlock.searchparams1 = &lower;
    searchBlock.sizeofsearchparams1 = sizeof(lower);
    searchBlock.searchparams2 = &upper;
    searchBlock.sizeofsearchparams2 = sizeof(upper);

    searchBlock.returnattrs = &returnAttrList;
    
    // Allocate a large buffer (256 KB) to reduce syscall count
    size_t bufSize = 262144;
    char *resultBuf = malloc(bufSize);
    if (!resultBuf) {
        return ENOMEM;
    }
    
    searchBlock.returnbuffer = resultBuf;
    searchBlock.returnbuffersize = bufSize;
    searchBlock.maxmatches = 1000; // Return up to 1000 matches per call

    struct searchstate state;
    memset(&state, 0, sizeof(state));

    unsigned long matchCount = 0;
    unsigned int options = SRCHFS_START | SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS;

    int scanResult = 0;
    do {
        matchCount = 0;
        int err = searchfs(volume_path, &searchBlock, &matchCount, 0, options, &state);
        if (err != 0) {
            int errNum = errno;
            if (errNum != EAGAIN) {
                scanResult = errNum;
                break;
            }
        }

        char *ptr = resultBuf;
        for (unsigned long i = 0; i < matchCount; i++) {
            struct ResultEntry *entry = (struct ResultEntry *)ptr;
            
            // Reconstruct name string safely
            char name[512] = {0};
            if (entry->nameRef.attr_length > 0 && entry->nameRef.attr_length < 512) {
                char *namePtr = ((char *)&entry->nameRef) + entry->nameRef.attr_dataoffset;
                strncpy(name, namePtr, entry->nameRef.attr_length);
            }
            
            int is_dir = (entry->objType == VDIR);
            int64_t size = is_dir ? 0 : (int64_t)entry->fileSize;
            double mod_date = (double)entry->modTime.tv_sec + (double)entry->modTime.tv_nsec / 1e9;
            
            callback(
                entry->fileId,
                entry->parentId,
                name,
                is_dir,
                size,
                mod_date,
                context
            );

            ptr += entry->length;
        }

        options &= ~SRCHFS_START; // Clear start flag for subsequent calls
        
        if (err == 0) {
            // Completed scan without EAGAIN (no more matches)
            break;
        }
    } while (1);

    free(resultBuf);
    return scanResult;
}
