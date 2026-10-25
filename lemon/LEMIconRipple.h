//
//  LEMIconRipple.h
//  Lemon
//
//  Radial icon ripple used by the home screen spread gesture.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the follow leg: the icons of `hostView` that can take part are placed
/// at rest and remembered, so LEMIconRippleUpdateFollow can carry them outwards
/// while the fingers are still opening the spread. Returns NO when no icon can
/// take part.
BOOL LEMIconRippleBeginFollow(UIView *hostView);

/// Carries the followed icons outwards by `progress` of the follow leg, 0…1.
void LEMIconRippleUpdateFollow(CGFloat progress);

/// Ends the follow leg and drops the icons back to rest, with a short ease-out
/// when `animated`. A spread that went on to trigger the wave does not call
/// this: LEMIconRippleRun picks the movement up where the fingers left it.
void LEMIconRippleEndFollow(BOOL animated);

/// Moves every visible icon of `hostView` radially away from the window center
/// and back, with a delay proportional to its distance from that center, from
/// wherever the icons already are. The badges pop on the same beat. Returns how
/// long the whole wave takes, or 0 when no icon was animated.
NSTimeInterval LEMIconRippleRun(UIView *hostView);

NS_ASSUME_NONNULL_END
