//
//  FIZZLog.m
//  Fizz
//

#import "FIZZLog.h"

#import <os/log.h>

void FIZZLogLoadedMarker(const char *buildID) {
    os_log_t handle = os_log_create("com.fizz.ripple", "lifecycle");
    os_log(handle, "ApelinLoaded %{public}s", buildID);
}
