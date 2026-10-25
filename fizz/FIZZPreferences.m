//
//  FIZZPreferences.m
//  Fizz
//
//  The Settings pane writes com.fizz.ripple through the Preferences framework,
//  so the tweak reads the same domain with CFPreferences. Every read is a plain
//  cache lookup; cfprefsd hands the new value over after the pane saves.
//

#import "FIZZPreferences.h"

NSString *const FIZZPreferencesDomain = @"com.fizz.ripple";
NSString *const FIZZPreferencesEnabledKey = @"Enabled";
NSString *const FIZZPreferencesKeepClearedKey = @"KeepCleared";
NSString *const FIZZPreferencesHapticsKey = @"Haptics";

BOOL FIZZPreferencesGetBool(NSString *key, BOOL fallback) {
    if (key.length == 0) {
        return fallback;
    }
    id stored = CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)FIZZPreferencesDomain));
    if (![stored respondsToSelector:@selector(boolValue)]) {
        return fallback;
    }
    return [stored boolValue];
}

BOOL FIZZFeatureEnabled(void) {
    return FIZZPreferencesGetBool(FIZZPreferencesEnabledKey, YES);
}

BOOL FIZZBadgeSuppressionEnabled(void) {
    return FIZZFeatureEnabled() && FIZZPreferencesGetBool(FIZZPreferencesKeepClearedKey, YES);
}

BOOL FIZZHapticsEnabled(void) {
    return FIZZFeatureEnabled() && FIZZPreferencesGetBool(FIZZPreferencesHapticsKey, YES);
}
