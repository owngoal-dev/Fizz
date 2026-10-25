//
//  FIZZIconRipple.h
//  Fizz
//
//  Radial icon ripple used by the home screen spread gesture.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the follow leg: the icons of `hostView` that can take part are placed
/// at rest and remembered, so FIZZIconRippleUpdateFollow can carry them outwards
/// while the fingers are still opening the spread. Returns NO when no icon can
/// take part.
BOOL FIZZIconRippleBeginFollow(UIView *hostView);

/// Carries the followed icons towards the position `progress` asks for. A
/// progress of 1 is the trigger distance; anything above it asks for a share
/// that presses against the follow limit without reaching it, and the icons
/// chase every one of those positions through a spring, not directly.
void FIZZIconRippleUpdateFollow(CGFloat progress);

/// Ends the follow leg and drops the icons back to rest, with a short ease-out
/// when `animated`. A spread that went on to trigger the wave does not call
/// this: FIZZIconRippleRun picks the movement up where the fingers left it.
void FIZZIconRippleEndFollow(BOOL animated);

/// The two moments of a wave that matter from outside.
typedef struct {
    /// When the wave is completely over and the last icon sits at rest, overshoot
    /// tail included.
    NSTimeInterval settle;
    /// When the icons cross their original positions on the way back, which is
    /// where they read as landed; the tail of the overshoot follows it. 0 when no
    /// icon was animated.
    NSTimeInterval touchdown;
} FIZZRippleTiming;

/// Moves every visible icon of `hostView` radially away from the window center
/// and back, with a delay proportional to its distance from that center, from
/// wherever the icons already are. The badges pop on the same beat. Both members
/// of the result are 0 when no icon was animated.
FIZZRippleTiming FIZZIconRippleRun(UIView *hostView);

NS_ASSUME_NONNULL_END
