//
//  NSObject+MTHAllocTrack.h
//  HawkeyeMemoryTest
//
//  Created by tongleiming on 2020/7/31.
//  Copyright © 2020 tongleiming. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(mtha_set_last_allocation_event_name_t)(void *ptr, const char *classname);

extern mtha_set_last_allocation_event_name_t *mtha_allocation_event_logger;

@interface NSObject (MTHAllocTrack)

+ (void)mtha_startAllocTrack;
+ (void)mtha_endAllocTrack;

@end

NS_ASSUME_NONNULL_END
