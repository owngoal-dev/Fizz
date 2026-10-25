//
//  FIZZHaptics.h
//  Fizz
//
//  The only haptic Fizz has left: one system impact that marks the badge
//  bubbles vanishing. The spread itself is silent.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plays one system impact as the tap for the bubbles going away. Call on the
/// main queue. Returns NO when the haptics switch is off or the device has no
/// haptics hardware.
BOOL FIZZHapticsPlayTap(void);

/// Wakes the feedback generator ahead of the first spread, so the tap does not
/// pay the warm-up delay. Called when the home screen appears; safe to call more
/// than once.
void FIZZHapticsPrewarm(void);

NS_ASSUME_NONNULL_END
