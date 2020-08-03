//
//  NSObject+MTHAllocTrack.m
//  HawkeyeMemoryTest
//
//  Created by tongleiming on 2020/7/31.
//  Copyright © 2020 tongleiming. All rights reserved.
//

#import "NSObject+MTHAllocTrack.h"

#warning 为什么这个hook需要使用arc?

#if __has_feature(objc_arc)
#error This file must be compiled without ARC. Use -fno-objc-arc flag.
#endif

mtha_set_last_allocation_event_name_t *mtha_allocation_event_logger = NULL;

static BOOL mtha_isAllocTracking = NO;

@implementation NSObject (MTHAllocTrack)

+ (void)mtha_startAllocTrack {
    if (!mtha_isAllocTracking) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            mtha_isAllocTracking = YES;
            
            SEL allocSEL = @selector(alloc);
            
            id (^allocImpFactory)(MTH_RSSwizzleInfo *swizzleInfo) = ^id(MTH_RSSwizzleInfo *swizzleInfo) {
                return Block_copy(^id(__unsafe_unretained id self) {
                    id (*originalIMP)(__unsafe_unretained id, SEL);
                    originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                    id obj = originalIMP(self, allocSEL);

                    if (mtha_isAllocTracking && mtha_allocation_event_logger) {
                        mtha_allocation_event_logger(obj, class_getName([obj class]));
                    }

                    return obj;
                });
            };
            [MTH_RSSwizzle swizzleClassMethod:allocSEL inClass:NSObject.class newImpFactory:allocImpFactory];
        });
    }
}

+ (void)mtha_endAllocTrack {
    mtha_isAllocTracking = NO;
}

@end
