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

/// Moves every visible icon of `hostView` radially away from the window center
/// and back, with a delay proportional to its distance from that center, from
/// wherever the icons already are. The badges pop on the same beat. Returns how
/// long the whole wave takes, or 0 when no icon was animated.
NSTimeInterval FIZZIconRippleRun(UIView *hostView);

NS_ASSUME_NONNULL_END
