//
//  LEMHaptics.m
//  Lemon
//
//  Core Haptics playback for the spread. Two AHAP files sit next to the dylib and
//  share their first 0.62 s: LEMRipple.ahap is the plain spread, and
//  LEMRippleCleared.ahap keeps that rhythm, cuts it with two tight dots and then
//  drops into a low rumble and a thud for the badges that were wiped.
//
//  The engine is created once and kept alive with auto shutdown, so the first
//  spread of a session does not pay the engine start latency.
//

#import "LEMHaptics.h"

#import "LEMPreferences.h"

#import <CoreHaptics/CoreHaptics.h>
#import <dlfcn.h>

// Index 0 is the plain spread, index 1 the spread that clears badges.
static NSString *const LEMHapticPatternFileNames[2] = {
    @"LEMRipple.ahap",
    @"LEMRippleCleared.ahap",
};

static CHHapticEngine *gEngine = nil;
static CHHapticPattern *gPatterns[2] = { nil, nil };
static id<CHHapticPatternPlayer> gPlayer = nil;
static BOOL gEngineRunning = NO;
static BOOL gPatternsUnavailable[2] = { NO, NO };
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

static NSUInteger LEMHapticVariantIndex(BOOL clearingBadges) {
    return clearingBadges ? 1 : 0;
}

// The patterns sit in the directory dyld loaded the dylib from. Resolving them
// through dladdr keeps the lookup correct on both the roothide and the rootless
// layout without hardcoding either prefix.
static NSURL *LEMHapticPatternURL(NSString *fileName) {
    Dl_info info;
    if (dladdr((const void *)LEMHapticPatternURL, &info) == 0 || info.dli_fname == NULL) {
        return nil;
    }
    NSString *directory = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
    if (directory.length == 0) {
        return nil;
    }
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:fileName]];
}

// A pattern that is missing or malformed is remembered as unavailable: the
// spread then stays silent instead of retrying the disk on every gesture.
static CHHapticPattern *LEMHapticPatternValue(BOOL clearingBadges) {
    NSUInteger index = LEMHapticVariantIndex(clearingBadges);
    if (gPatterns[index] || gPatternsUnavailable[index]) {
        return gPatterns[index];
    }
    NSURL *url = LEMHapticPatternURL(LEMHapticPatternFileNames[index]);
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) {
        gPatternsUnavailable[index] = YES;
        return nil;
    }
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        gPatternsUnavailable[index] = YES;
        return nil;
    }
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithDictionary:object error:&error];
    if (!pattern) {
        gPatternsUnavailable[index] = YES;
        return nil;
    }
    gPatterns[index] = pattern;
    return pattern;
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

BOOL LEMHapticsPlaySpread(BOOL clearingBadges) {
    if (!LEMHapticsEnabled()) {
        return NO;
    }
    @synchronized (LEMHapticLockToken()) {
        CHHapticPattern *pattern = LEMHapticPatternValue(clearingBadges);
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
            // Both variants are parsed and the engine is started ahead of the
            // first spread, whichever variant that spread turns out to need.
            (void)LEMHapticPatternValue(NO);
            (void)LEMHapticPatternValue(YES);
            (void)LEMHapticEngineValue();
        }
    });
}
