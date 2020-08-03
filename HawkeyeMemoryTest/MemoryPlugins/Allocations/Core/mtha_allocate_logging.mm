//
//  mtha_allocate_logging.mm
//  HawkeyeMemoryTest
//
//  Created by tongleiming on 2020/7/28.
//  Copyright © 2020 tongleiming. All rights reserved.
//

#include "mtha_allocate_logging.h"

#include <sys/mman.h>
#include <limits.h>
#include "mtha_locking.h"
#include "mtha_inner_allocate.h"

// vm_statistics.h
// clang-format off
static const char *vm_flags[] = {
    "0", "malloc", "malloc_small", "malloc_large", "malloc_huge", "SBRK",
    "realloc", "malloc_tiny", "malloc_large_reusable", "malloc_large_reused",
    "analysis_tool", "malloc_nano", "12", "13", "14",
    "15", "16", "17", "18", "19",
    "mach_msg", "iokit", "22", "23", "24",
    "25", "26", "27", "28", "29",
    "stack", "guard", "shared_pmap", "dylib", "objc_dispatchers",
    "unshared_pmap", "36", "37", "38", "39",
    "appkit", "foundation", "core_graphics", "carbon_or_core_services", "java",
    "coredata", "coredata_objectids", "47", "48", "49",
    "ats", "layerkit", "cgimage", "tcmalloc", "CG_raster_data(layers&images)",
    "CG_shared_images_fonts", "CG_framebuffers", "CG_backingstores", "CG_x-alloc", "59",
    "dyld", "dyld_malloc", "sqlite", "JavaScriptCore", "JIT_allocator",
    "JIT_file", "GLSL", "OpenCL", "QuartzCore", "WebCorePurgeableBuffers",
    "ImageIO", "CoreProfile", "assetsd", "os_once_alloc", "libdispatch",
    "Accelerate.framework", "CoreUI", "CoreUIFile", "GenealogyBuffers", "RawCamera",
    "CorpseInfo", "ASL", "SwiftRuntime", "SwiftMetadata", "DHMM",
    "85", "SceneKit.framework", "skywalk", "IOSurface", "libNetwork",
    "Audio", "VideoBitStream", "CoreMediaXCP", "CoreMediaRPC", "CoreMediaMemoryPool",
    "CoreMediaReadCache", "CoreMediaCrabs", "QuickLook", "Accounts.framework", "99",
};

// 内部其实是pthread的信号量
static _malloc_lock_s stack_logging_lock = _MALLOC_LOCK_INIT;

// 标记是否记录的变量
boolean_t mtha_memory_allocate_logging_enabled = false;

boolean_t mth_allocations_need_sys_frame = false;

#warning 如何单线程控制访问它
mth_allocations_record_raw *mtha_recording;

static vm_address_t *current_stack_origin;

char mtha_records_cache_dir[PATH_MAX];
const char *mtha_vm_records_filename = "vm_records_raw";
const char *mtha_malloc_records_filename = "malloc_records_raw";
const char *mtha_stacks_records_filename = "stacks_records_raw";


static void mtha_disable_stack_logging(void) {
    mtha_memory_allocate_logging_enabled = false;
}


static malloc_zone_t *stack_id_zone = NULL;

boolean_t mtha_prepare_memory_allocate_logging(void) {
    mtha_memory_allocate_logging_lock();
    
    if (!mtha_recording) {
        size_t full_shared_mem_size = sizeof(mth_allocations_record_raw);
        // mmap走的应该是底层的vm_allocate，也会创建和VM_MAKE_TAG(XXX)相关的vm region。
        mtha_recording = (mth_allocations_record_raw *)mmap(0, full_shared_mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, VM_MAKE_TAG(VM_AMKE_TAG_HAWKEYE_UNIQUING_TABLE), 0);
        if (MAP_FAILED == mtha_recording) {
            // 从作者的打印输出也可以看出来创建的是vm region
            MTHLogWarn(@"error creating VM region for stack logging output buffers.");
            mtha_disable_stack_logging();
            goto fail;
        }
        
        char uniquing_table_file_path[PATH_MAX];  // PATH_MAX路径最大长度
        strcpy(uniquing_table_file_path, mtha_records_cache_dir);
        strcat(uniquing_table_file_path, "/");
        strcat(uniquing_table_file_path, mtha_stacks_records_filename);
        
#warning ???? 后期看看这个backtrace是如何使用的？
        size_t page_size = mth_allocations_need_sys_frame ? MTHA_VM_DEFAULT_UNIQUING_PAGE_SIZE_WITH_SYS : MTHA_VM_DEFAULT_UNIQUING_PAGE_SIZE_WITHOUT_SYS;
        mtha_recording->backtrace_records = mtha_create_uniquing_table(uniquing_table_file_path, page_size);
        if (!mtha_recording->backtrace_records) {
            MTHLogWarn(@"error while allocating stack uniquing table.");
            mtha_disable_stack_logging();
            goto fail;
        }
        
        mtha_recording->vm_records = NULL;
        
#warning ？？？是一个栈帧最多200条记录？
        uint64_t stack_buffer_sz = (uint64_t)round_page(sizeof(vm_address_t) * MTH_ALLOCATIONS_MAX_STACK_SIZE);
        current_stack_origin = (vm_address_t *)mtha_allocate_page(stack_buffer_sz);
        if (!current_stack_origin) {
            MTHLogWarn("error while allocating stack trace buffer.");
            mtha_disable_stack_logging();
            goto fail;
        }
        
#warning 为什么使用了malloc_zone_t？有什么优势？
        if (stack_id_zone == NULL) {
            stack_id_zone = malloc_create_zone(0, 0);
            malloc_set_zone_name(stack_id_zone, "com.meitu.hawkeye.allocations");
            mtha_setup_hawkeye_malloc_zone(stack_id_zone);
        }
        
        if (mtha_recording) {
            char vm_filepath[PATH_MAX], malloc_filepath[PATH_MAX];
            strcpy(vm_filepath, mtha_records_cache_dir);
            strcpy(malloc_filepath, mtha_records_cache_dir);
            strcat(vm_filepath, "/");
            strcat(malloc_filepath, "/");
            strcat(vm_filepath, mtha_vm_records_filename);
            strcat(malloc_filepath, mtha_malloc_records_filename);
#warning 看后续数据是如何插进来的
            mtha_recording->vm_records = mtha_splay_tree_create_on_mmapfile(5000, vm_filepath);
            mtha_recording->malloc_records = mtha_splay_tree_create_on_mmapfile(200000, malloc_filepath);
        }
    }
    
    mtha_memory_allocate_logging_unlock();
    return true;
    
fail:
    mtha_memory_allocate_logging_unlock();
    return false;
}

void mtha_memory_allocate_logging_lock(void) {
    _malloc_lock_lock(&stack_logging_lock);
}

void mtha_memory_allocate_logging_unlock(void) {
    _malloc_lock_unlock(&stack_logging_lock);
}

void mtha_allocate_logging(uint32_t type_flags, uintptr_t zone_ptr, uintptr_t arg2, uintptr_t arg3, uintptr_t return_val, uint32_t num_hot_to_skip) {
    if (!mtha_memory_allocate_logging_enabled)
    return;

    uintptr_t size = 0;
    uintptr_t ptr_arg = 0;
    uint64_t stackid_and_flags = 0;
    uint64_t category_and_size = 0;

#if MTH_ALLOCATIONS_DEBUG
    static uint64_t malloc_size_counter = 0;
    static uint64_t vm_allocate_size_counter = 0;
    static uint64_t count = 0;
    static uint64_t alive_ptr_count = 0;
#endif
    
    // 调用realloc时mth_allocations_type_alloc和mth_allocations_type_dealloc同时会为1，因为既要dealloc，又要alloc。
    // check incoming data
    // malloc_zone_realloc: MALLOC_LOG_TYPE_ALLOCATE | MALLOC_LOG_TYPE_DEALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE
    if (type_flags & mth_allocations_type_alloc && type_flags & mth_allocations_type_dealloc) {
        size = arg3;
        ptr_arg = arg2;  // malloc_zone_realloc调用时传递的原来的指针
        // return_val为malloc_zone_realloc新返回的指针
        if (ptr_arg == return_val) {
            return;
        }
        if (ptr_arg == 0) { // 在调用malloc_zone_realloc时不传递指针相当于malloc_zone_malloc
            // 做亦或操作，抹掉dealloc标记
            type_flags ^= mth_allocations_type_dealloc;
        } else {
            // realloc(arg1, arg2) -> result is same as free(arg1); malloc(arg2) -> result
            // 分成两块做统计
            // 1> dealloc
            mtha_allocate_logging(mth_allocations_type_dealloc, zone_ptr, ptr_arg, (uintptr_t)0, (uintptr_t)0, num_hot_to_skip+1);
            // 2> alloc
            mtha_allocate_logging(mth_allocations_type_alloc, zone_ptr, size, (uintptr_t)0, return_val, num_hot_to_skip+1);
        }
    }
    
    if (type_flags & mth_allocations_type_dealloc || type_flags & mth_allocations_type_vm_deallocate) {
        // malloc_zone_free中，调用malloc_logger传递的arg3，即size为0；
        // mach_vm_deallocate中，调用__syscall_logger传递的arg3，即size，是mach_vm_deallocate的参数的size。
        ptr_arg = arg2;  // 要释放的内存地址
        size = arg3;     // 释放的体积
        if (ptr_arg == 0) {
            return; // free(nil)
        }
    }
    if (type_flags & mth_allocations_type_alloc || type_flags & mth_allocations_type_vm_allocate) {
        // malloc_zone_malloc中，malloc_logger(MALLOC_LOG_TYPE_ALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE, (uintptr_t)zone, (uintptr_t)size, 0, (uintptr_t)ptr, 0);
        // arg2是size。
        if (return_val == 0 || return_val == (uintptr_t)MAP_FAILED) {
            return; // 分配失败
        }
        size = arg2;
    }
    
    if (type_flags & mth_allocations_type_vm_allocate || type_flags & mth_allocations_type_vm_deallocate) {
        // mach_vm_allocate中，__syscall_logger(stack_logging_type_vm_allocate | userTagFlags, (uintptr_t)target, (uintptr_t)size, 0, (uintptr_t)*address, 0);
        // target是mach_port_name_t
        mach_port_t targetTask = (mach_port_t)zone_ptr;
        // 暂时忽略掉其他task"注入"的vm。
        if (targetTask != mach_task_self()) {
            return;
        }
    }

#warning 暂时搞不懂
    vm_address_t self_thread = (vm_address_t)_os_tsd_get_direct(__TSD_THREAD_SELF);
    if (thread_doing_logging == self_thread) {
        // Prevent a thread from deadlocking against itself if vm_allocate() or malloc()
        // is called below here, from __prepare_to_log_stacks() or _prepare_to_log_stacks_stage2(),
        // or if we are logging an event and need to call __expand_uniquing_table() which calls
        // vm_allocate() to grow stack logging data structures.  Any such "administrative"
        // vm_allocate or malloc calls would attempt to recursively log those events.
        return;
    }
    
    // lock and enter
    mtha_memory_allocate_logging_lock();
    
    thread_doing_logging = self_thread; // for preventing deadlock'ing on stack logging on a single thread
    
    uint64_t uniqueStackIdentifier = mtha_vm_invalid_stack_id;
    
    // for single chunk malloc detector
    vm_address_t frames_for_chunk_malloc[MTH_ALLOCATIONS_MAX_STACK_SIZE];
    size_t frames_count_for_chunk_malloc = 0;
    
    if (type_flags & mth_allocations_type_vm_deallocate) {
        // 如果是vm dealloc，则从vm记录伸展树上删除该节点
        if (mtha_recording && mtha_recording->vm_records) {
            mtha_splay_tree_node removed = mtha_splay_tree_delete(mtha_recording->vm_records, ptr_arg);
            if (removed.category_and_size > 0) {
                size = MTH_ALLOCATIONS_SIZE(removed.category_and_size);
            }
        }
        goto out;
    } else if (type_flags & mth_allocations_type_dealloc) {
        // 如果是dealloc，则从malloc记录伸展树中删除该节点
        if (mtha_recording && mtha_recording->malloc_records) {
            mtha_splay_tree_node removed = mtha_splay_tree_delete(mtha_recording->malloc_records, ptr_arg);
            if (removed.category_and_size > 0) {
                size = MTH_ALLOCATIONS_SIZE(removed.category_and_size);
            }
        }
        goto out;
    }
    
    // 规避一些情况
    // now actually begin
    // since there could have been a fatal (to stack logging) error such as the log files not being created, check these variables before continuing
    if (!mtha_memory_allocate_logging_enabled) {
        goto out;
    }
    
    if (((type_flags & mth_allocations_type_vm_allocate) || (type_flags & mth_allocations_type_alloc)) && size > 0) {
#warning 这个identifier是干什么用的？
        uniqueStackIdentifier = mtha_enter_stack_into_table_while_locked(self_thread, num_hot_to_skip, false, 1);
    }
    
    if (uniqueStackIdentifier == mtha_vm_invalid_stack_id) {
        goto out;
    }
    
#warning stackid_and_flags是干什么用的？
    // store ptr, size, & stack_id
    stackid_and_flags = MTH_ALLOCATIONS_OFFSET_AND_FLAGS(uniqueStackIdentifier, type_flags);
    if (type_flags & mth_allocations_type_vm_allocate) {
        // 在mach_vm_allocate中，
        // #define VM_FLAGS_ALIAS_MASK    0xFF000000
        // int userTagFlags = flags & VM_FLAGS_ALIAS_MASK;
        // type_flags = stack_logging_type_vm_allocate | userTagFlags，
        // 这里是为了提取出userTagFlags，
        
        // 剥离type_flags中的stack_logging_type_vm_allocate这1位的内容
        uint32_t type = (type_flags & ~mth_allocations_type_vm_allocate);
        
        //#define VM_MAKE_TAG(tag) ((tag) << 24)
        // 获取用户在vm_allocate调用时传递的tag, VM_MAKE_TAG(200) | VM_FLAGS_ANYWHERE)
        type = type >> 24;
        const char *flag = "unknown";
        // 系统定义的VM_MEMORY_XXX为 1~98
        if (type <= 99)
            flag = vm_flags[type];
        // 根据获取的名字和大小创建合并起来
        category_and_size = MTH_ALLOCATIONS_CATEGORY_AND_SIZE(flag, size);
    } else {
        // vm_dealloc找不到名字，malloc/dealloc也找不到名字
        category_and_size = MTH_ALLOCATIONS_CATEGORY_AND_SIZE(0, size);
    }
    
    if (type_flags & mth_allocations_type_vm_allocate) {
        // 插入记录到vm_records中
        if (!mtha_splay_tree_insert(mtha_recording->vm_records, return_val, stackid_and_flags, category_and_size)) {
            mtha_recording->vm_records = mtha_expand_splay_tree(mtha_recording->vm_records);
            if (mtha_recording->vm_records) {
                mtha_splay_tree_insert(mtha_recording->vm_records, return_val, stackid_and_flags, category_and_size);
            } else {
                mtha_disable_stack_logging();
            }
        }
    } else if (type_flags & mth_allocations_type_alloc) {
        // 将记录插入到malloc_records中
        if (!mtha_splay_tree_insert(mtha_recording->malloc_records, return_val, stackid_and_flags, category_and_size)) {
            mtha_recording->malloc_records = mtha_expand_splay_tree(mtha_recording->malloc_records);
            if (mtha_recording->malloc_records) {
                mtha_splay_tree_insert(mtha_recording->malloc_records, return_val, stackid_and_flags, category_and_size);
            } else {
                mtha_disable_stack_logging();
            }
        }
        
#warning ????有什么关系？？？
        // 此处若直接回调让外部处理，需要处理死锁问题。故此处延后到 mtha_malloc_unlock_stack_logging 锁结束后处理
        if (chunk_malloc_detector_enable && chunk_malloc_detector_threshold_in_bytes < size && chunk_malloc_detector_block != nullptr) {
            memcpy(frames_for_chunk_malloc, current_frames, current_frames_count * sizeof(vm_address_t));
            frames_count_for_chunk_malloc = current_frames_count;
        }
    }
out:
    
#if MTH_ALLOCATIONS_DEBUG
#endif
    
    thread_doing_logging = 0;
    mtha_memory_allocate_logging_unlock();
    
    if (chunk_malloc_detector_enable && chunk_malloc_detector_threshold_in_bytes < size && chunk_malloc_detector_block != nullptr && frames_count_for_chunk_malloc > 0) {
        chunk_malloc_detector_block(size, frames_for_chunk_malloc, frames_count_for_chunk_malloc);
    }
}
