//
//  LEMIconRipple.m
//  Lemon
//
//  Radial icon ripple: each icon is pushed away from the window center along
//  the line that joins it to that center, then springs back. Icons farther from
//  the center start slightly later and travel farther, so the movement reads as
//  one wave spreading outwards instead of every icon jumping at once.
//
//  The movement is a CAKeyframeAnimation on the layer's translation, so the
//  model transform of the icon is never touched and SpringBoard's own icon
//  layout keeps working.
//

#import "LEMIconRipple.h"

#import "LEMBadgeClearer.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

static const CGFloat LEMRippleMaximumOffset = 26.0;
static const NSTimeInterval LEMRippleDuration = 0.5;
static const NSTimeInterval LEMRippleMaximumDelay = 0.1;
static const CGFloat LEMRippleOutKeyTime = 0.42;
static const NSUInteger LEMRippleMaximumDepth = 8;

typedef struct {
    CGPoint center;
    CGFloat distance;
} LEMRippleCandidate;

static void LEMRippleCollectIconViews(UIView *view, NSMutableArray<UIView *> *icons, NSUInteger depth) {
    if (!view || depth > LEMRippleMaximumDepth) {
        return;
    }
    // Only the outermost icon view takes part: its image view is a descendant
    // that is not itself an SBIconView, and a second translation on it would
    // double the movement of the image inside the icon.
    Class iconViewClass = objc_getClass("SBIconView");
    BOOL isIconView = iconViewClass ? [view isKindOfClass:iconViewClass]
                                    : [NSStringFromClass([view class]) containsString:@"IconView"];
    if (isIconView) {
        [icons addObject:view];
        return;
    }
    for (UIView *child in view.subviews) {
        LEMRippleCollectIconViews(child, icons, depth + 1);
    }
}

// Moves `layer` from its resting position to `offset` and back over `duration`.
static void LEMRippleAddTranslation(CALayer *layer, NSString *keyPath, CGFloat offset,
                                    NSTimeInterval duration, NSTimeInterval delay) {
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    animation.values = @[ @0.0, @(offset), @0.0 ];
    animation.keyTimes = @[ @0.0, @(LEMRippleOutKeyTime), @1.0 ];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    animation.duration = duration;
    animation.beginTime = CACurrentMediaTime() + delay;
    [layer addAnimation:animation forKey:keyPath];
}

NSTimeInterval LEMIconRippleRun(UIView *hostView) {
    UIWindow *window = hostView ? hostView.window : nil;
    if (!window) {
        return 0;
    }

    CGPoint anchor = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    CGRect windowBounds = window.bounds;

    NSMutableArray<UIView *> *collected = [NSMutableArray array];
    LEMRippleCollectIconViews(hostView, collected, 0);

    NSUInteger count = collected.count;
    if (count == 0) {
        return 0;
    }

    LEMRippleCandidate *candidates = calloc(count, sizeof(LEMRippleCandidate));
    if (!candidates) {
        return 0;
    }

    // Only icons that are on screen, visible and untouched by another animation
    // take part; the farthest of them sets the scale of the whole ripple.
    NSMutableArray<UIView *> *icons = [NSMutableArray arrayWithCapacity:count];
    CGFloat maximumDistance = 0;
    for (NSUInteger index = 0; index < count; index++) {
        UIView *icon = collected[index];
        CGPoint center = [icon convertPoint:CGPointMake(CGRectGetMidX(icon.bounds), CGRectGetMidY(icon.bounds))
                                     toView:window];
        CGRect frame = [icon convertRect:icon.bounds toView:window];
        if (!CGRectIntersectsRect(frame, windowBounds)) {
            continue;
        }
        if (icon.hidden || icon.alpha < 0.01) {
            continue;
        }
        if (!CGAffineTransformIsIdentity(icon.transform)) {
            continue;
        }
        CGFloat distance = hypot(center.x - anchor.x, center.y - anchor.y);
        NSUInteger slot = icons.count;
        [icons addObject:icon];
        candidates[slot].center = center;
        candidates[slot].distance = distance;
        if (distance > maximumDistance) {
            maximumDistance = distance;
        }
    }

    NSUInteger animated = 0;
    if (maximumDistance > 0.5) {
        CGFloat unit = LEMRippleMaximumOffset / maximumDistance;
        for (NSUInteger index = 0; index < icons.count; index++) {
            UIView *icon = icons[index];
            CGPoint center = candidates[index].center;
            CGFloat offsetX = (center.x - anchor.x) * unit;
            CGFloat offsetY = (center.y - anchor.y) * unit;
            if (hypot(offsetX, offsetY) < 0.5) {
                continue;
            }
            CGFloat progress = candidates[index].distance / maximumDistance;
            NSTimeInterval delay = LEMRippleMaximumDelay * progress;
            LEMRippleAddTranslation(icon.layer, @"transform.translation.x", offsetX,
                                    LEMRippleDuration, delay);
            LEMRippleAddTranslation(icon.layer, @"transform.translation.y", offsetY,
                                    LEMRippleDuration, delay);
            // The badge of the icon rides the same beat, so it is gone at the
            // moment the icon is farthest out.
            LEMBadgeFadeWithRipple(icon, LEMRippleDuration, delay, LEMRippleOutKeyTime);
            animated++;
        }
    }

    free(candidates);

    return animated > 0 ? LEMRippleDuration + LEMRippleMaximumDelay : 0;
}
