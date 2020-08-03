//
//  mtha_allocate_logging.h
//  HawkeyeMemoryTest
//
//  Created by tongleiming on 2020/7/28.
//  Copyright © 2020 tongleiming. All rights reserved.
//

#ifndef mtha_allocate_logging_hpp
#define mtha_allocate_logging_hpp

#include <stdio.h>
#include <sys/syslimits.h>

#include "mtha_splay_tree.h"
#include "mtha_backtrace_uniquing_table.h"

#define MTH_ALLOCATIONS_MAX_STACK_SIZE 200


//#define MALLOC_LOG_TYPE_ALLOCATE stack_logging_type_alloc
//#define MALLOC_LOG_TYPE_DEALLOCATE stack_logging_type_dealloc
//#define MALLOC_LOG_TYPE_HAS_ZONE stack_logging_flag_zone
//#define MALLOC_LOG_TYPE_CLEARED stack_logging_flag_cleared

// 这部分代码来源于XNU，和libmalloc
//#define stack_logging_type_free        0
//#define stack_logging_type_generic    1    /* anything that is not allocation/deallocation */
//#define stack_logging_type_alloc    2    /* malloc, realloc, etc... */
//#define stack_logging_type_dealloc    4    /* free, realloc, etc... */
//#define stack_logging_type_vm_allocate  16      /* vm_allocate or mmap */
//#define stack_logging_type_vm_deallocate  32    /* vm_deallocate or munmap */
//#define stack_logging_type_mapped_file_or_shared_mem    128

#define mth_allocations_type_free 0
#define mth_allocations_type_generic 1        /* anything that is not allocation/deallocation */
#define mth_allocations_type_alloc 2          /* malloc, realloc, etc... */
#define mth_allocations_type_dealloc 4        /* free, realloc, etc... */
#define mth_allocations_type_vm_allocate 16   /* vm_allocate or mmap */
#define mth_allocations_type_vm_deallocate 32 /* vm_deallocate or munmap */
#define mth_allocations_type_mapped_file_or_shared_mem 128

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Record files info
extern char mtha_records_cache_dir[PATH_MAX];    /**< the directory to cache all the records, should be set before start. */
extern const char *mtha_malloc_records_filename; /**< the heap records filename */
extern const char *mtha_vm_records_filename;     /**< the vm records filename */
extern const char *mtha_stacks_records_filename; /**< the backtrace records filename */

// 是否记录的标记
extern boolean_t mtha_memory_allocate_logging_enabled;

// 考虑32/64位兼容，统一偏移为4字节；难道这个结构体会持久化到本地被不同架构的系统访问吗？
#pragma pack(push, 4)
typedef struct {
    mtha_splay_tree *malloc_records = NULL;
    mtha_splay_tree *vm_records = NULL;
    mtha_backtrace_uniquing_table *backtrace_records = NULL;
} mth_allocations_record_raw;
#pragma pack(pop)

// 供外部使用，单线程访问
extern mth_allocations_record_raw *mtha_recording;

// 开始记录之前进行准备
boolean_t mtha_prepare_memory_allocate_logging(void);

// 操作mtha_recording时使用的加锁和解锁方法
void mtha_memory_allocate_logging_lock(void);
void mtha_memory_allocate_logging_unlock(void);

typedef void(mtha_malloc_logger_t)(uint32_t type_flags, uintptr_t zone_ptr, uintptr_t arg2, uintptr_t arg3, uintptr_t return_val, uint32_t num_hot_to_skip);

extern mtha_malloc_logger_t *malloc_logger;
extern mtha_malloc_logger_t *__syscall_logger;

#ifdef __cplusplus
}
#endif

#endif /* mtha_allocate_logging_hpp */
