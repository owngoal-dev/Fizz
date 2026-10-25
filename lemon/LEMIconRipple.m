//
//  LEMIconRipple.m
//  Lemon
//
//  Radial icon ripple: each icon is pushed away from the window center along
//  the line that joins it to that center, then springs back. Icons farther from
//  the center start slightly later and travel farther, so the movement reads as
//  one wave spreading outwards instead of every icon jumping at once.
//
//  The wave has two legs. While the fingers are still opening, the follow leg
//  moves the icons with them, so the home screen answers the gesture before the
//  pinch recognizer has decided anything. The wave leg then continues the
//  outward movement from wherever the fingers left it and brings every icon
//  back, and a wave that replaces another one is caught mid-flight the same way
//  instead of snapping to rest.
//
//  The movement is a CAKeyframeAnimation on the layer's translation, so the
//  model transform of the icon is left alone and SpringBoard's own icon layout
//  keeps working. Only the follow leg writes the layer transform, and the wave
//  reads it back before clearing it.
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
// How much of the full offset the fingers carry the icons before the wave takes
// over; the wave finishes the outward leg from there.
static const CGFloat LEMRippleFollowShare = 0.55;
static const NSTimeInterval LEMRippleReturnDuration = 0.18;

static NSString *const LEMRippleTranslationKeyX = @"transform.translation.x";
static NSString *const LEMRippleTranslationKeyY = @"transform.translation.y";
static NSString *const LEMRippleReturnKeyX = @"com.lemon.ripple.follow.x";
static NSString *const LEMRippleReturnKeyY = @"com.lemon.ripple.follow.y";

static NSMutableArray<UIView *> *gFollowIcons = nil;
static NSMutableArray<NSValue *> *gFollowOffsets = nil;
static CGFloat gFollowShare = 0;

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

// An icon the wave may push: it carries no scale or rotation of its own, only a
// translation the follow leg may have left on it.
static BOOL LEMRippleTransformIsTranslation(CGAffineTransform transform) {
    return fabs(transform.a - 1.0) < 0.01 && fabs(transform.b) < 0.01 &&
           fabs(transform.c) < 0.01 && fabs(transform.d - 1.0) < 0.01;
}

// Collects the icons that take part and the full radial offset of each of them
// from the window center. `offsets` receives one CGPoint value per icon, in the
// same order.
static NSArray<UIView *> *LEMRipplePlaceIcons(UIView *hostView, NSMutableArray<NSValue *> *offsets) {
    UIWindow *window = hostView ? hostView.window : nil;
    if (!window) {
        return @[];
    }

    CGPoint anchor = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    CGRect windowBounds = window.bounds;

    NSMutableArray<UIView *> *collected = [NSMutableArray array];
    LEMRippleCollectIconViews(hostView, collected, 0);
    if (collected.count == 0) {
        return @[];
    }

    // Only icons that are on screen, visible and not being animated by
    // SpringBoard itself take part; the farthest of them sets the scale of the
    // whole ripple.
    NSMutableArray<UIView *> *icons = [NSMutableArray arrayWithCapacity:collected.count];
    NSMutableArray<NSValue *> *centers = [NSMutableArray arrayWithCapacity:collected.count];
    CGFloat maximumDistance = 0;
    for (UIView *icon in collected) {
        CGPoint center = [icon convertPoint:CGPointMake(CGRectGetMidX(icon.bounds), CGRectGetMidY(icon.bounds))
                                     toView:window];
        CGRect frame = [icon convertRect:icon.bounds toView:window];
        if (!CGRectIntersectsRect(frame, windowBounds)) {
            continue;
        }
        if (icon.hidden || icon.alpha < 0.01) {
            continue;
        }
        if (!LEMRippleTransformIsTranslation(icon.transform)) {
            continue;
        }
        CGFloat distance = hypot(center.x - anchor.x, center.y - anchor.y);
        [icons addObject:icon];
        [centers addObject:[NSValue valueWithCGPoint:center]];
        if (distance > maximumDistance) {
            maximumDistance = distance;
        }
    }

    if (maximumDistance <= 0.5) {
        return @[];
    }

    CGFloat unit = LEMRippleMaximumOffset / maximumDistance;
    for (NSUInteger index = 0; index < icons.count; index++) {
        CGPoint center = [centers[index] CGPointValue];
        [offsets addObject:[NSValue valueWithCGPoint:CGPointMake((center.x - anchor.x) * unit,
                                                                (center.y - anchor.y) * unit)]];
    }
    return icons;
}

// Where the icon is on screen right now, so a movement that is already under way
// is picked up instead of restarted. A presentation layer that cannot be read
// falls back to the model value.
static CGFloat LEMRippleCurrentTranslation(UIView *icon, NSString *keyPath, CGFloat fallback) {
    CALayer *presentation = icon.layer.presentationLayer;
    id value = nil;
    if (presentation) {
        @try {
            value = [presentation valueForKeyPath:keyPath];
        } @catch (__unused NSException *exception) {
            value = nil;
        }
    }
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

static CGPoint LEMRippleCurrentOffset(UIView *icon) {
    CALayer *layer = icon.layer;
    return CGPointMake(LEMRippleCurrentTranslation(icon, LEMRippleTranslationKeyX, layer.transform.m41),
                       LEMRippleCurrentTranslation(icon, LEMRippleTranslationKeyY, layer.transform.m42));
}

static void LEMRippleSetLayerTranslation(CALayer *layer, CGPoint translation) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = CATransform3DMakeTranslation(translation.x, translation.y, 0);
    [CATransaction commit];
}

// Moves `layer` from `startShare` of `offset` out to `offset` and back over
// `duration`.
static void LEMRippleAddTranslation(CALayer *layer, NSString *keyPath, CGFloat offset,
                                    CGFloat startShare, NSTimeInterval duration,
                                    NSTimeInterval delay) {
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    animation.values = @[ @(offset * startShare), @(offset), @0.0 ];
    animation.keyTimes = @[ @0.0, @(LEMRippleOutKeyTime * (1.0 - startShare)), @1.0 ];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    animation.duration = duration;
    animation.beginTime = CACurrentMediaTime() + delay;
    // Icons farther out start later; holding the first value keeps one that is
    // already partway out where it is until its own beat begins.
    animation.fillMode = kCAFillModeBackwards;
    [layer addAnimation:animation forKey:keyPath];
}

static void LEMRippleResetFollowState(void) {
    [gFollowIcons removeAllObjects];
    [gFollowOffsets removeAllObjects];
    gFollowShare = 0;
}

BOOL LEMIconRippleBeginFollow(UIView *hostView) {
    if (!gFollowIcons) {
        gFollowIcons = [NSMutableArray array];
        gFollowOffsets = [NSMutableArray array];
    }
    LEMRippleResetFollowState();
    NSArray<UIView *> *icons = LEMRipplePlaceIcons(hostView, gFollowOffsets);
    [gFollowIcons addObjectsFromArray:icons];
    return gFollowIcons.count > 0;
}

void LEMIconRippleUpdateFollow(CGFloat progress) {
    NSUInteger count = gFollowIcons.count;
    if (count == 0) {
        return;
    }
    CGFloat share = LEMRippleFollowShare * fmin(fmax(progress, 0.0), 1.0);
    gFollowShare = share;
    for (NSUInteger index = 0; index < count; index++) {
        CGPoint offset = [gFollowOffsets[index] CGPointValue];
        LEMRippleSetLayerTranslation(gFollowIcons[index].layer,
                                     CGPointMake(offset.x * share, offset.y * share));
    }
}

void LEMIconRippleEndFollow(BOOL animated) {
    NSUInteger count = gFollowIcons.count;
    for (NSUInteger index = 0; index < count; index++) {
        UIView *icon = gFollowIcons[index];
        CALayer *layer = icon.layer;
        CGPoint current = LEMRippleCurrentOffset(icon);
        LEMRippleSetLayerTranslation(layer, CGPointZero);
        if (!animated || hypot(current.x, current.y) < 0.5) {
            continue;
        }
        // The release is short and eases out, so a spread that never crossed the
        // trigger just lets the icons settle back instead of dropping them.
        CAKeyframeAnimation *backX = [CAKeyframeAnimation animationWithKeyPath:LEMRippleTranslationKeyX];
        backX.values = @[ @(current.x), @0.0 ];
        backX.duration = LEMRippleReturnDuration;
        backX.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [layer addAnimation:backX forKey:LEMRippleReturnKeyX];

        CAKeyframeAnimation *backY = [CAKeyframeAnimation animationWithKeyPath:LEMRippleTranslationKeyY];
        backY.values = @[ @(current.y), @0.0 ];
        backY.duration = LEMRippleReturnDuration;
        backY.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [layer addAnimation:backY forKey:LEMRippleReturnKeyY];
    }
    LEMRippleResetFollowState();
}

NSTimeInterval LEMIconRippleRun(UIView *hostView) {
    CGFloat followShare = gFollowShare;

    NSMutableArray<NSValue *> *offsets = [NSMutableArray array];
    NSArray<UIView *> *icons = LEMRipplePlaceIcons(hostView, offsets);
    if (icons.count == 0) {
        LEMRippleResetFollowState();
        return 0;
    }

    NSUInteger animated = 0;
    for (NSUInteger index = 0; index < icons.count; index++) {
        UIView *icon = icons[index];
        CGPoint offset = [offsets[index] CGPointValue];
        CGFloat length = hypot(offset.x, offset.y);
        if (length < 0.5) {
            continue;
        }

        // The wave starts from wherever the icon already is: the follow leg left
        // it partway out, and a wave that replaces another one was caught in the
        // middle of its movement.
        CGPoint current = LEMRippleCurrentOffset(icon);
        CGFloat startShare = (current.x * offset.x + current.y * offset.y) / (length * length);
        startShare = fmax(fmin(startShare, 0.9), followShare);

        // From here on the wave animates the translation itself, so the follow
        // leg's model transform and its return animation go away.
        LEMRippleSetLayerTranslation(icon.layer, CGPointZero);
        [icon.layer removeAnimationForKey:LEMRippleReturnKeyX];
        [icon.layer removeAnimationForKey:LEMRippleReturnKeyY];

        CGFloat progress = fmin(length / LEMRippleMaximumOffset, 1.0);
        NSTimeInterval delay = LEMRippleMaximumDelay * progress;
        LEMRippleAddTranslation(icon.layer, LEMRippleTranslationKeyX, offset.x, startShare,
                                LEMRippleDuration, delay);
        LEMRippleAddTranslation(icon.layer, LEMRippleTranslationKeyY, offset.y, startShare,
                                LEMRippleDuration, delay);
        // The badge of the icon rides the same beat: it puffs up like a bubble
        // and bursts as the icon comes to rest, so the last one is gone as the
        // wave settles.
        LEMBadgePopWithRipple(icon, LEMRippleDuration, delay);
        animated++;
    }

    LEMRippleResetFollowState();

    return animated > 0 ? LEMRippleDuration + LEMRippleMaximumDelay : 0;
}
