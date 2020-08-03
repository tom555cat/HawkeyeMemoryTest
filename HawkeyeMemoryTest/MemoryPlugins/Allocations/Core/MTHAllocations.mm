//
//  MTHAllocations.m
//  HawkeyeMemoryTest
//
//  Created by tongleiming on 2020/7/28.
//  Copyright © 2020 tongleiming. All rights reserved.
//

#import "MTHAllocations.h"
#import "mtha_allocate_logging.h"
#import "mtha_splay_tree.h"
#import "NSObject+MTHAllocTrack.h"

#warning 使用外部的__CFOASafe是什么意思？
#warning https://opensource.apple.com/source/CF/CF-368.28/Base.subproj/CFRuntime.c.auto.html
extern bool __CFOASafe;

extern void (*__CFObjectAllocSetLastAllocEventNameFunction)(void *, const char *);
// 定义了一个函数指针
void (*MTHA_ORIGINAL___CFObjectAllocSetLastAllocEventNameFunction)(void *, const char *) = NULL;

// MARK: allication event name
void mtha_set_last_allocation_event_name(void *ptr, const char *classname) {
    if (!mtha_memory_allocate_logging_enabled || mtha_recording == nullptr) {
        return;
    }
    
    mtha_memory_allocate_logging_lock();
    // find record and set category.
    uint32_t idx = 0;
    if (mtha_recording->malloc_records != nullptr)
#warning 从伸展树中查找这个内存分配的指针是否存在，
#warning 这个节点是什么时候创建的？
        idx = mtha_splay_tree_search(mtha_recording->malloc_records, (vm_address_t)ptr, false);
    
    if (idx > 0) {
#warning 从malloc记录中获取节点
        mtha_splay_tree_node *node = &mtha_recording->malloc_records->node[idx];
        size_t size = MTH_ALLOCATIONS_SIZE(node->category_and_size);
        // 将名字保存在了低几位，而将体积大小放在了低30位上
        node->category_and_size = MTH_ALLOCATIONS_CATEGORY_AND_SIZE((uint64_t)classname, size);
    } else {
        // malloc里找不到，到虚拟内存中查找
        uint32_t vm_idx = 0;
        if (mtha_recording->vm_records != nullptr)
            vm_idx = mtha_splay_tree_search(mtha_recording->vm_records, (vm_address_t)ptr, false);
        
        if (vm_idx > 0) {
            mtha_splay_tree_node *node = &mtha_recording->vm_records->node[vm_idx];
            size_t size = MTH_ALLOCATIONS_SIZE(node->category_and_size);
            node->category_and_size = MTH_ALLOCATIONS_CATEGORY_AND_SIZE((uint64_t)classname, size);
        }
    }
    
    mtha_memory_allocate_logging_unlock();
}

// CoreFoundation创建对象后通过这个函数指针告诉上层当前对象是什么类型
void mtha_cfobject_alloc_set_last_alloc_event_name_function(void *ptr, const char *classname) {
    if (MTHA_ORIGINAL___CFObjectAllocSetLastAllocEventNameFunction) {
        MTHA_ORIGINAL___CFObjectAllocSetLastAllocEventNameFunction(ptr, classname);
    }

    mtha_set_last_allocation_event_name(ptr, classname);
}

@interface MTHAllocations ()

// 当前层提供目录路径
@property (nonatomic, copy) NSString *logDir;

@end

@implementation MTHAllocations

- (BOOL)startMallocLogging:(BOOL)mallocLogOn vmLogging:(BOOL)vmLogOn {
#if TARGET_IPHONE_SIMULATOR
    return NO;
#else
    NSAssert(self.logDir.length > 0, @"You should conigure persistance directory before start malloc logging");
    
    // 当前层提供目录路径
    strcpy(mtha_records_cache_dir, [self.logDir UTF8String]);
    
    mtha_memory_allocate_logging_enabled = true;

    mtha_prepare_memory_allocate_logging();
    
    // hook malloc
    if (mallocLogOn) {
        malloc_logger = (mtha_malloc_logger_t *)mtha_allocate_logging;
    }
    
    // hook vm
    if (vmLogOn) {
        __syscall_logger = mtha_allocate_logging;
    }

    if (mallocLogOn || vmLogOn) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // 所以这里是hook了CoreFoundation的对象内存分配方法
#warning 但后来发现，NSData创建对象的类静态方法没有调用+[NSObject alloc]，里面实现是调用C方法NSAllocateObject来创建对象，也就是说这类方式创建的OC对象无法通过hook来获取OC类名。
#warning 最后在苹果开源代码CF-1153.18找到了答案，当__CFOASafe=true并且__CFObjectAllocSetLastAllocEventNameFunction!=NULL时，CoreFoundation创建对象后通过这个函数指针告诉上层当前对象是什么类型：
            __CFOASafe = true;
            MTHA_ORIGINAL___CFObjectAllocSetLastAllocEventNameFunction = __CFObjectAllocSetLastAllocEventNameFunction;
            __CFObjectAllocSetLastAllocEventNameFunction = mtha_cfobject_alloc_set_last_alloc_event_name_function;
            
            // hook了NSObject的alloc方法，加了一个钩子函数，钩子还是mtha_set_last_allocation_event_name；
            // 钩子函数能准确统计到NSObject的class(包括自定义的class)。
            mtha_allocation_event_logger = mtha_set_last_allocation_event_name;
            [NSObject mtha_startAllocTrack];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.f * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *dyldDumperPath = [self.logDir stringByAppendingPathComponent:@"dyld-images"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:dyldDumperPath]) {
#warning 记录了image的一些信息，有什么用？
                    mtha_setup_dyld_images_dumper_with_path(dyldDumperPath);
                }
            });
        });
    }
    
    return YES;
#endif
}

@end
