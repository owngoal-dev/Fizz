//
//  LEMLog.h
//  Fizz
//
//  Fizz emits one line in production: the marker the Apelin loader watches to
//  confirm that the tweak is loaded. Everything else is kept out of shipping
//  builds.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Emits `ApelinLoaded <buildID>` on the com.lemon.ripple os_log subsystem.
void LEMLogLoadedMarker(const char *buildID);

NS_ASSUME_NONNULL_END
