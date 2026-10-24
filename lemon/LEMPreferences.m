//
//  LEMPreferences.m
//  Lemon
//
//  The Settings pane writes com.lemon.ripple through the Preferences framework,
//  so the tweak reads the same domain with CFPreferences. Every read is a plain
//  cache lookup; cfprefsd hands the new value over after the pane saves.
//

#import "LEMPreferences.h"

NSString *const LEMPreferencesDomain = @"com.lemon.ripple";
NSString *const LEMPreferencesEnabledKey = @"Enabled";
NSString *const LEMPreferencesKeepClearedKey = @"KeepCleared";
NSString *const LEMPreferencesHapticsKey = @"Haptics";

BOOL LEMPreferencesGetBool(NSString *key, BOOL fallback) {
    if (key.length == 0) {
        return fallback;
    }
    id stored = CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)LEMPreferencesDomain));
    if (![stored respondsToSelector:@selector(boolValue)]) {
        return fallback;
    }
    return [stored boolValue];
}

BOOL LEMFeatureEnabled(void) {
    return LEMPreferencesGetBool(LEMPreferencesEnabledKey, YES);
}

BOOL LEMBadgeSuppressionEnabled(void) {
    return LEMFeatureEnabled() && LEMPreferencesGetBool(LEMPreferencesKeepClearedKey, YES);
}

BOOL LEMHapticsEnabled(void) {
    return LEMFeatureEnabled() && LEMPreferencesGetBool(LEMPreferencesHapticsKey, YES);
}
