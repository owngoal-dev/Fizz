//
//  LEMPreferences.h
//  Lemon
//
//  Preferences shared by the SpringBoard tweak and the Settings pane. The pane
//  writes the domain below; the tweak reads it when a gesture starts and before
//  a badge write is gated.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The preferences domain, which is also the package identifier.
extern NSString *const LEMPreferencesDomain;

/// Global switch, defaulting to YES.
extern NSString *const LEMPreferencesEnabledKey;

/// Keep-cleared switch, defaulting to YES.
extern NSString *const LEMPreferencesKeepClearedKey;

/// Haptic feedback switch, defaulting to YES.
extern NSString *const LEMPreferencesHapticsKey;

/// Reads one boolean, falling back to `fallback` when it was never written.
BOOL LEMPreferencesGetBool(NSString *key, BOOL fallback);

/// YES when the global switch is on.
BOOL LEMFeatureEnabled(void);

/// YES when both the global switch and the keep-cleared switch are on. Only this
/// layer drops the counts an application republishes after a clear.
BOOL LEMBadgeSuppressionEnabled(void);

/// YES when both the global switch and the haptics switch are on. The haptic
/// pattern follows the gesture, so it is off whenever the gesture is.
BOOL LEMHapticsEnabled(void);

NS_ASSUME_NONNULL_END
