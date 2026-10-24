//
//  LEMIconRipple.h
//  Lemon
//
//  Radial icon ripple used by the home screen spread gesture.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Moves every visible icon of `hostView` radially away from the window center
/// and back, with a delay proportional to its distance from that center. The
/// badges fade on the same beat. Returns how long the whole wave takes, or 0
/// when no icon was animated.
NSTimeInterval LEMIconRippleRun(UIView *hostView);

NS_ASSUME_NONNULL_END
