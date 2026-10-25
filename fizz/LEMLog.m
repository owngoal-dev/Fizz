//
//  LEMLog.m
//  Fizz
//

#import "LEMLog.h"

#import <os/log.h>

void LEMLogLoadedMarker(const char *buildID) {
    os_log_t handle = os_log_create("com.lemon.ripple", "lifecycle");
    os_log(handle, "ApelinLoaded %{public}s", buildID);
}
