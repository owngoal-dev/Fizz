//
//  LEMHaptics.m
//  Lemon
//
//  Core Haptics playback for the spread. The engine is created once and kept
//  alive with auto shutdown, so the first spread of a session does not pay the
//  engine start latency. The pattern is read from LEMRipple.ahap, which the
//  build places next to the dylib.
//

#import "LEMHaptics.h"

#import "LEMPreferences.h"

#import <CoreHaptics/CoreHaptics.h>
#import <dlfcn.h>

static NSString *const LEMHapticPatternFileName = @"LEMRipple.ahap";

static CHHapticEngine *gEngine = nil;
static CHHapticPattern *gPattern = nil;
static id<CHHapticPatternPlayer> gPlayer = nil;
static BOOL gEngineRunning = NO;
static BOOL gPatternUnavailable = NO;
static BOOL gPrewarmed = NO;

// Core Haptics calls this code from its own queues, so the state above is only
// touched while holding this token.
static id LEMHapticLockToken(void) {
    static id token = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        token = [[NSObject alloc] init];
    });
    return token;
}

// The pattern sits in the directory dyld loaded the dylib from. Resolving it
// through dladdr keeps the lookup correct on both the roothide and the rootless
// layout without hardcoding either prefix.
static NSURL *LEMHapticPatternURL(void) {
    Dl_info info;
    if (dladdr((const void *)LEMHapticPatternURL, &info) == 0 || info.dli_fname == NULL) {
        return nil;
    }
    NSString *directory = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
    if (directory.length == 0) {
        return nil;
    }
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:LEMHapticPatternFileName]];
}

static CHHapticPattern *LEMHapticPatternValue(void) {
    if (gPattern || gPatternUnavailable) {
        return gPattern;
    }
    NSURL *url = LEMHapticPatternURL();
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) {
        gPatternUnavailable = YES;
        return nil;
    }
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        gPatternUnavailable = YES;
        return nil;
    }
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithDictionary:object error:&error];
    if (!pattern) {
        gPatternUnavailable = YES;
        return nil;
    }
    gPattern = pattern;
    return gPattern;
}

static CHHapticEngine *LEMHapticEngineValue(void) {
    if (gEngine) {
        return gEngine;
    }
    if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics) {
        return nil;
    }
    NSError *error = nil;
    CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&error];
    if (!engine) {
        return nil;
    }
    // The spread is haptics without sound, and the engine may stop itself while
    // the home screen is idle; the stopped and reset handlers keep the state
    // below honest.
    engine.playsHapticsOnly = YES;
    engine.isMutedForAudio = YES;
    engine.autoShutdownEnabled = YES;
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        (void)reason;
        @synchronized (LEMHapticLockToken()) {
            gEngineRunning = NO;
            gPlayer = nil;
        }
    };
    engine.resetHandler = ^{
        @synchronized (LEMHapticLockToken()) {
            gPlayer = nil;
            gEngineRunning = [gEngine startAndReturnError:NULL];
        }
    };
    gEngineRunning = [engine startAndReturnError:&error];
    gEngine = engine;
    return gEngine;
}

BOOL LEMHapticsPlaySpread(void) {
    if (!LEMHapticsEnabled()) {
        return NO;
    }
    @synchronized (LEMHapticLockToken()) {
        CHHapticPattern *pattern = LEMHapticPatternValue();
        if (!pattern) {
            return NO;
        }
        CHHapticEngine *engine = LEMHapticEngineValue();
        if (!engine) {
            return NO;
        }
        // A second spread inside the tail of the previous one replaces it
        // instead of stacking two patterns on the hardware.
        if (gPlayer) {
            [gPlayer stopAtTime:CHHapticTimeImmediate error:NULL];
            gPlayer = nil;
        }
        if (!gEngineRunning) {
            gEngineRunning = [engine startAndReturnError:NULL];
            if (!gEngineRunning) {
                return NO;
            }
        }
        NSError *error = nil;
        id<CHHapticPatternPlayer> player = [engine createPlayerWithPattern:pattern error:&error];
        if (!player || ![player startAtTime:CHHapticTimeImmediate error:&error]) {
            return NO;
        }
        gPlayer = player;
        return YES;
    }
}

void LEMHapticsPrewarm(void) {
    if (gPrewarmed || !LEMHapticsEnabled()) {
        return;
    }
    gPrewarmed = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @synchronized (LEMHapticLockToken()) {
            (void)LEMHapticPatternValue();
            (void)LEMHapticEngineValue();
        }
    });
}
