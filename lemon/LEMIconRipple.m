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
// The return leg crosses the icon's starting point by a small share of the
// offset and settles back onto it, so the tail of the ripple bounces instead of
// stopping dead. The deepest point of that overshoot sits late in the return.
static const CGFloat LEMRippleSettleOvershoot = 0.06;
static const CGFloat LEMRippleSettleKeyShare = 0.72;
static const NSUInteger LEMRippleMaximumDepth = 8;
// How much of the full offset the fingers carry the icons before the wave takes
// over; the wave finishes the outward leg from there. Past the trigger distance
// the icons keep going, but each further point of spread adds less than the one
// before, so the travel presses against a soft limit instead of being cut off.
static const CGFloat LEMRippleFollowShare = 0.55;
static const CGFloat LEMRippleFollowLimitShare = 0.9;
// The followed value chases what the fingers ask for through a spring, so it
// trails them a little and settles with a short overshoot instead of being glued
// to the fingers. Slightly underdamped on purpose.
static const CGFloat LEMRippleSpringStiffness = 400.0;
static const CGFloat LEMRippleSpringDamping = 28.0;
// The release back to rest is sprung as well, and slightly underdamped, so an
// icon passes its starting point by a little before it settles onto it.
static const CGFloat LEMRippleReturnStiffness = 420.0;
static const CGFloat LEMRippleReturnDamping = 21.0;

static NSString *const LEMRippleTranslationKeyX = @"transform.translation.x";
static NSString *const LEMRippleTranslationKeyY = @"transform.translation.y";
static NSString *const LEMRippleReturnKeyX = @"com.lemon.ripple.follow.x";
static NSString *const LEMRippleReturnKeyY = @"com.lemon.ripple.follow.y";

static NSMutableArray<UIView *> *gFollowIcons = nil;
static NSMutableArray<NSValue *> *gFollowOffsets = nil;
static CGFloat gFollowShare = 0;
static CGFloat gFollowTarget = 0;
static CGFloat gFollowVelocity = 0;
static NSTimeInterval gFollowLastTick = 0;

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

// Moves `layer` from `startShare` of `offset` out to `offset`, then back through
// the starting point and onto it over `duration`.
static void LEMRippleAddTranslation(CALayer *layer, NSString *keyPath, CGFloat offset,
                                    CGFloat startShare, NSTimeInterval duration,
                                    NSTimeInterval delay) {
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    CGFloat outTime = LEMRippleOutKeyTime * (1.0 - startShare);
    CGFloat settleTime = outTime + (1.0 - outTime) * LEMRippleSettleKeyShare;
    animation.values = @[ @(offset * startShare), @(offset),
                          @(-offset * LEMRippleSettleOvershoot), @0.0 ];
    animation.keyTimes = @[ @0.0, @(outTime), @(settleTime), @1.0 ];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    animation.duration = duration;
    animation.beginTime = CACurrentMediaTime() + delay;
    // Icons farther out start later; holding the first value keeps one that is
    // already partway out where it is until its own beat begins.
    animation.fillMode = kCAFillModeBackwards;
    [layer addAnimation:animation forKey:keyPath];
}

// What the fingers ask for, in share of the full offset. Up to the trigger
// distance it rises almost directly with them, and past it every further point
// of spread buys less and less, approaching the limit without ever reaching it.
static CGFloat LEMRippleFollowTargetShare(CGFloat progress) {
    if (!(progress > 0)) {
        return 0;
    }
    // Chosen so that progress 1 lands exactly on LEMRippleFollowShare.
    const CGFloat knee = LEMRippleFollowLimitShare / LEMRippleFollowShare - 1.0;
    return LEMRippleFollowLimitShare * progress / (progress + knee);
}

static void LEMRippleApplyFollow(void) {
    NSUInteger count = gFollowIcons.count;
    for (NSUInteger index = 0; index < count; index++) {
        CGPoint offset = [gFollowOffsets[index] CGPointValue];
        LEMRippleSetLayerTranslation(gFollowIcons[index].layer,
                                     CGPointMake(offset.x * gFollowShare, offset.y * gFollowShare));
    }
}

// One step of the spring that carries the icons towards what the fingers ask
// for. It is what keeps them from being glued to the fingers: they trail a
// little, keep moving for a moment after the fingers stop, and press against the
// limit instead of stopping at it.
static BOOL LEMRippleStepFollow(NSTimeInterval now) {
    if (gFollowIcons.count == 0) {
        return NO;
    }
    NSTimeInterval dt = gFollowLastTick > 0 ? now - gFollowLastTick : 1.0 / 60.0;
    gFollowLastTick = now;
    // A stalled frame must not make the spring explode.
    dt = fmin(fmax(dt, 1.0 / 240.0), 1.0 / 30.0);

    CGFloat displacement = gFollowTarget - gFollowShare;
    CGFloat acceleration = LEMRippleSpringStiffness * displacement - LEMRippleSpringDamping * gFollowVelocity;
    gFollowVelocity += acceleration * dt;
    gFollowShare += gFollowVelocity * dt;

    // The spring may overshoot the limit a little, which is the elasticity that
    // is wanted, but it may never leave the range or go behind the start.
    if (gFollowShare > LEMRippleFollowLimitShare) {
        gFollowShare = LEMRippleFollowLimitShare;
        gFollowVelocity = fmin(gFollowVelocity, 0);
    } else if (gFollowShare < 0) {
        gFollowShare = 0;
        gFollowVelocity = fmax(gFollowVelocity, 0);
    }

    LEMRippleApplyFollow();
    return YES;
}

// Runs the spring while the fingers are down. It is started by the first
// movement of a follow leg and stopped as soon as the leg ends.
@interface LEMFollowDriver : NSObject
@property (nonatomic, strong) CADisplayLink *link;
+ (instancetype)sharedDriver;
- (void)start;
- (void)stop;
@end

static LEMFollowDriver *gFollowDriver = nil;

@implementation LEMFollowDriver

+ (instancetype)sharedDriver {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gFollowDriver = [[LEMFollowDriver alloc] init];
    });
    return gFollowDriver;
}

- (void)start {
    if (self.link) {
        return;
    }
    gFollowLastTick = 0;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.link = link;
}

- (void)stop {
    [self.link invalidate];
    self.link = nil;
    gFollowLastTick = 0;
}

- (void)tick:(CADisplayLink *)link {
    if (!LEMRippleStepFollow(CACurrentMediaTime())) {
        [self stop];
    }
}

@end

static void LEMRippleResetFollowState(void) {
    [[LEMFollowDriver sharedDriver] stop];
    [gFollowIcons removeAllObjects];
    [gFollowOffsets removeAllObjects];
    gFollowShare = 0;
    gFollowTarget = 0;
    gFollowVelocity = 0;
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
    if (gFollowIcons.count == 0) {
        return;
    }
    // The fingers only set what to aim at; the spring decides where the icons
    // actually are on this frame.
    gFollowTarget = LEMRippleFollowTargetShare(progress);
    [[LEMFollowDriver sharedDriver] start];
}

// Carries one axis of the translation from `from` back to rest through a spring,
// so the icon overshoots its starting point by a little and settles onto it.
static void LEMRippleAddSpringBack(CALayer *layer, NSString *keyPath, CGFloat from, NSString *key) {
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:keyPath];
    animation.fromValue = @(from);
    animation.toValue = @0.0;
    animation.mass = 1.0;
    animation.stiffness = LEMRippleReturnStiffness;
    animation.damping = LEMRippleReturnDamping;
    animation.initialVelocity = 0.0;
    // The settling time is only known once the spring is configured.
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:key];
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
        // The release springs back instead of easing back, so an icon that was
        // carried partway out passes its starting point and settles onto it
        // rather than stopping there.
        LEMRippleAddSpringBack(layer, LEMRippleTranslationKeyX, current.x, LEMRippleReturnKeyX);
        LEMRippleAddSpringBack(layer, LEMRippleTranslationKeyY, current.y, LEMRippleReturnKeyY);
    }
    LEMRippleResetFollowState();
}

NSTimeInterval LEMIconRippleRun(UIView *hostView) {
    // The follow leg ends here: from this point the wave animates the icons, and
    // the last position the spring left them in is where the wave starts.
    [[LEMFollowDriver sharedDriver] stop];
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
        // The badge of the icon rides the same beat: it grows while it fades out
        // and is gone as the icon comes to rest, as the wave settles.
        LEMBadgePopWithRipple(icon, LEMRippleDuration, delay);
        animated++;
    }

    LEMRippleResetFollowState();

    return animated > 0 ? LEMRippleDuration + LEMRippleMaximumDelay : 0;
}
