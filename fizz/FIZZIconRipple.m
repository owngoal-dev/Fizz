//
//  FIZZIconRipple.m
//  Fizz
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

#import "FIZZIconRipple.h"

#import "FIZZBadgeClearer.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

static const CGFloat FIZZRippleMaximumOffset = 26.0;
static const NSTimeInterval FIZZRippleDuration = 0.5;
static const NSTimeInterval FIZZRippleMaximumDelay = 0.1;
static const NSUInteger FIZZRippleMaximumDepth = 8;
// How much of the full offset the fingers carry the icons before the wave takes
// over; the wave finishes the outward leg from there. Past the trigger distance
// the icons keep going, but each further point of spread adds less than the one
// before, so the travel presses against a soft limit instead of being cut off.
static const CGFloat FIZZRippleFollowShare = 0.55;
static const CGFloat FIZZRippleFollowLimitShare = 0.9;
// The followed value chases what the fingers ask for through a spring, so it
// trails them a little and settles with a short overshoot instead of being glued
// to the fingers. Slightly underdamped on purpose.
static const CGFloat FIZZRippleSpringStiffness = 400.0;
static const CGFloat FIZZRippleSpringDamping = 28.0;
// The release back to rest is sprung as well, and slightly underdamped, so an
// icon passes its starting point by a little before it settles onto it.
static const CGFloat FIZZRippleReturnStiffness = 420.0;
static const CGFloat FIZZRippleReturnDamping = 21.0;
// A release cannot carry more than this many points per second; a stalled frame
// during the follow must not turn into a jump.
static const CGFloat FIZZRippleReleaseVelocityLimit = 400.0;
static const NSTimeInterval FIZZRippleSimulationStep = 1.0 / 240.0;
static const NSTimeInterval FIZZRippleSampleStep = 1.0 / 60.0;
static const NSTimeInterval FIZZRippleWaveMaximumDuration = 1.4;

static NSString *const FIZZRippleTranslationKeyX = @"transform.translation.x";
static NSString *const FIZZRippleTranslationKeyY = @"transform.translation.y";
static NSString *const FIZZRippleReturnKeyX = @"com.fizz.ripple.follow.x";
static NSString *const FIZZRippleReturnKeyY = @"com.fizz.ripple.follow.y";

static NSMutableArray<UIView *> *gFollowIcons = nil;
static NSMutableArray<NSValue *> *gFollowOffsets = nil;
// Where each icon was when this follow leg took over, so a leg that interrupts a
// wave still in the air continues from there instead of jumping back.
static NSMutableArray<NSValue *> *gFollowBases = nil;
// Share of the offset the icons already carried when the leg began, so the
// release does not freeze them again.
static CGFloat gFollowCarried = 0;
static CGFloat gFollowShare = 0;
static CGFloat gFollowTarget = 0;
static CGFloat gFollowVelocity = 0;
static NSTimeInterval gFollowLastTick = 0;

static void FIZZRippleCollectIconViews(UIView *view, NSMutableArray<UIView *> *icons, NSUInteger depth) {
    if (!view || depth > FIZZRippleMaximumDepth) {
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
        FIZZRippleCollectIconViews(child, icons, depth + 1);
    }
}

// An icon the wave may push: it carries no scale or rotation of its own, only a
// translation the follow leg may have left on it.
static BOOL FIZZRippleTransformIsTranslation(CGAffineTransform transform) {
    return fabs(transform.a - 1.0) < 0.01 && fabs(transform.b) < 0.01 &&
           fabs(transform.c) < 0.01 && fabs(transform.d - 1.0) < 0.01;
}

static NSArray<UIView *> *FIZZRipplePlaceCollectedIcons(NSArray<UIView *> *collected, UIWindow *window,
                                                        NSMutableArray<NSValue *> *offsets,
                                                        CGFloat *maximumDistanceOut);

// Collects the icons that take part and the full radial offset of each of them
// from the window center. `offsets` receives one CGPoint value per icon, in the
// same order.
static NSArray<UIView *> *FIZZRipplePlaceIcons(UIView *hostView, NSMutableArray<NSValue *> *offsets) {
    UIWindow *window = hostView ? hostView.window : nil;
    if (!window) {
        return @[];
    }

    NSMutableArray<UIView *> *collected = [NSMutableArray array];
    FIZZRippleCollectIconViews(hostView, collected, 0);
    return FIZZRipplePlaceCollectedIcons(collected, window, offsets, NULL);
}

// Turns the icon views of one page into the offsets the wave animates, skipping
// the ones that cannot move. The farthest icon sets the scale of the whole
// ripple, and the badges' delays follow the same scale.
static NSArray<UIView *> *FIZZRipplePlaceCollectedIcons(NSArray<UIView *> *collected, UIWindow *window,
                                                        NSMutableArray<NSValue *> *offsets,
                                                        CGFloat *maximumDistanceOut) {
    if (maximumDistanceOut) {
        *maximumDistanceOut = 0;
    }
    if (collected.count == 0) {
        return @[];
    }

    CGPoint anchor = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    CGRect windowBounds = window.bounds;

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
        if (!FIZZRippleTransformIsTranslation(icon.transform)) {
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

    if (maximumDistanceOut) {
        *maximumDistanceOut = maximumDistance;
    }

    CGFloat unit = FIZZRippleMaximumOffset / maximumDistance;
    for (NSUInteger index = 0; index < icons.count; index++) {
        CGPoint center = [centers[index] CGPointValue];
        [offsets addObject:[NSValue valueWithCGPoint:CGPointMake((center.x - anchor.x) * unit,
                                                                (center.y - anchor.y) * unit)]];
    }
    return icons;
}

// How deep the release walk goes. It has to pass through the folder view, the
// page scroll view, the icon list, the icon view and the image view to reach a
// badge, so it is deeper than the follow leg's icon-only walk.
static const NSUInteger FIZZRippleWindowMaximumDepth = 12;

// One walk of the home screen window, done when the fingers are lifted. It
// returns the page icons that move and every badge on screen; the Dock's icons
// are not descendants of the page, so they stay out of the movement, but their
// badges are found here like any other and pop on the same beat.
static void FIZZRippleCollectRunViews(UIView *view, UIView *hostView, NSUInteger depth, BOOL insideIcon,
                                      NSMutableArray<UIView *> *pageIcons,
                                      NSMutableArray<UIView *> *badges) {
    if (!view || depth > FIZZRippleWindowMaximumDepth) {
        return;
    }
    Class badgeViewClass = objc_getClass("SBIconBadgeView");
    if (badgeViewClass && [view isKindOfClass:badgeViewClass]) {
        if (view.window && !view.hidden) {
            [badges addObject:view];
        }
        // A badge holds nothing else worth visiting.
        return;
    }
    Class iconViewClass = objc_getClass("SBIconView");
    BOOL isIconView = iconViewClass ? [view isKindOfClass:iconViewClass]
                                    : [NSStringFromClass([view class]) containsString:@"IconView"];
    // Only the outermost icon view of a page moves; the walk keeps going through
    // it because its badge sits on the image view inside.
    if (isIconView && !insideIcon && [view isDescendantOfView:hostView]) {
        [pageIcons addObject:view];
    }
    BOOL nextInsideIcon = insideIcon || isIconView;
    for (UIView *child in view.subviews) {
        FIZZRippleCollectRunViews(child, hostView, depth + 1, nextInsideIcon, pageIcons, badges);
    }
}

// Where the icon is on screen right now, so a movement that is already under way
// is picked up instead of restarted. A presentation layer that cannot be read
// falls back to the model value.
static CGFloat FIZZRippleCurrentTranslation(UIView *icon, NSString *keyPath, CGFloat fallback) {
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

static CGPoint FIZZRippleCurrentOffset(UIView *icon) {
    CALayer *layer = icon.layer;
    return CGPointMake(FIZZRippleCurrentTranslation(icon, FIZZRippleTranslationKeyX, layer.transform.m41),
                       FIZZRippleCurrentTranslation(icon, FIZZRippleTranslationKeyY, layer.transform.m42));
}

static void FIZZRippleSetLayerTranslation(CALayer *layer, CGPoint translation) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = CATransform3DMakeTranslation(translation.x, translation.y, 0);
    [CATransaction commit];
}

// What the release does to one icon, in seconds from the moment the fingers left
// the glass: `settle` is when it is back at rest, `touchdown` when it crosses its
// own place on the way back.
typedef struct {
    NSTimeInterval settle;
    NSTimeInterval touchdown;
} FIZZRippleReleaseTiming;

// Runs the released icon forward in time: from wherever the fingers left it, a
// spring pulls it back to its own place, carrying the speed it already had, so a
// flick keeps drifting outwards for a moment while a slow release turns straight
// back. A spread that was not taken all the way to its full offset is never
// pushed the rest of the way: the icon only goes as far as its own momentum
// takes it, and never past the offset the wave was drawn at. The sampled track
// is handed to Core Animation as one keyframe animation per axis.
static FIZZRippleReleaseTiming FIZZRippleAddRelease(CALayer *layer,
                                                    CGPoint offset, CGPoint from, CGPoint velocity,
                                                    NSTimeInterval delay) {
    FIZZRippleReleaseTiming timing = {0, 0};

    CGFloat length = hypot(offset.x, offset.y);
    if (length < 0.5) {
        return timing;
    }
    CGPoint direction = CGPointMake(offset.x / length, offset.y / length);

    // A stalled frame during the follow can leave an absurd speed behind; the
    // release never carries more than the limit.
    CGFloat speed = hypot(velocity.x, velocity.y);
    if (speed > FIZZRippleReleaseVelocityLimit) {
        velocity.x *= FIZZRippleReleaseVelocityLimit / speed;
        velocity.y *= FIZZRippleReleaseVelocityLimit / speed;
    }

    NSMutableArray<NSNumber *> *xs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *ys = [NSMutableArray array];
    NSMutableArray<NSNumber *> *times = [NSMutableArray array];

    CGPoint position = from;
    CGPoint speedVector = velocity;
    NSTimeInterval simulated = 0;
    NSTimeInterval nextSample = 0;
    BOOL crossed = NO;
    CGFloat projection = position.x * direction.x + position.y * direction.y;

    while (simulated < FIZZRippleWaveMaximumDuration) {
        if (simulated >= nextSample - 1e-9) {
            [xs addObject:@(position.x)];
            [ys addObject:@(position.y)];
            [times addObject:@(simulated)];
            nextSample += FIZZRippleSampleStep;
        }

        // Only the return spring runs: nothing pushes the icon further out than
        // the fingers took it, so a spread let go halfway comes straight back.
        CGFloat stiffness = FIZZRippleReturnStiffness;
        CGFloat damping = FIZZRippleReturnDamping;
        CGFloat ax = -stiffness * position.x - damping * speedVector.x;
        CGFloat ay = -stiffness * position.y - damping * speedVector.y;
        speedVector.x += ax * FIZZRippleSimulationStep;
        speedVector.y += ay * FIZZRippleSimulationStep;
        position.x += speedVector.x * FIZZRippleSimulationStep;
        position.y += speedVector.y * FIZZRippleSimulationStep;
        simulated += FIZZRippleSimulationStep;

        CGFloat currentProjection = position.x * direction.x + position.y * direction.y;
        if (currentProjection > length) {
            // The full offset is the edge of the wave: an outward flick spends
            // what is left of its speed here instead of flying past it.
            CGFloat excess = currentProjection - length;
            position.x -= direction.x * excess;
            position.y -= direction.y * excess;
            CGFloat radialSpeed = speedVector.x * direction.x + speedVector.y * direction.y;
            if (radialSpeed > 0) {
                speedVector.x -= direction.x * radialSpeed;
                speedVector.y -= direction.y * radialSpeed;
            }
            currentProjection = length;
        }

        if (!crossed && projection > 0 && currentProjection <= 0) {
            crossed = YES;
            timing.touchdown = delay + simulated;
        }
        if (hypot(position.x, position.y) < 0.15 && hypot(speedVector.x, speedVector.y) < 2.0) {
            // Asleep: close the track on its final value and stop here.
            [xs addObject:@(position.x)];
            [ys addObject:@(position.y)];
            [times addObject:@(simulated)];
            break;
        }
        projection = currentProjection;
    }

    NSTimeInterval duration = times.lastObject.doubleValue;
    if (duration <= 0 || xs.count < 2) {
        return timing;
    }

    NSMutableArray<NSNumber *> *keys = [NSMutableArray arrayWithCapacity:times.count];
    for (NSNumber *time in times) {
        [keys addObject:@(time.doubleValue / duration)];
    }

    void (^addAnimation)(NSString *, NSArray<NSNumber *> *) =
        ^(NSString *keyPath, NSArray<NSNumber *> *values) {
            CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:keyPath];
            animation.values = values;
            animation.keyTimes = keys;
            // The track is already the movement itself; easing it again would
            // bend it away from the spring.
            animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
            animation.duration = duration;
            animation.beginTime = CACurrentMediaTime() + delay;
            animation.fillMode = kCAFillModeBackwards;
            [layer addAnimation:animation forKey:keyPath];
        };
    addAnimation(FIZZRippleTranslationKeyX, xs);
    addAnimation(FIZZRippleTranslationKeyY, ys);

    timing.settle = delay + duration;
    if (!crossed) {
        // The icon was released so far out that it never crossed its place on
        // the way back; the wave's rest is the only landmark left.
        timing.touchdown = timing.settle;
    }
    return timing;
}

// What the fingers ask for, in share of the full offset. Up to the trigger
// distance it rises almost directly with them, and past it every further point
// of spread buys less and less, approaching the limit without ever reaching it.
static CGFloat FIZZRippleFollowTargetShare(CGFloat progress) {
    if (!(progress > 0)) {
        return 0;
    }
    // Chosen so that progress 1 lands exactly on FIZZRippleFollowShare.
    const CGFloat knee = FIZZRippleFollowLimitShare / FIZZRippleFollowShare - 1.0;
    return FIZZRippleFollowLimitShare * progress / (progress + knee);
}

static void FIZZRippleApplyFollow(void) {
    NSUInteger count = gFollowIcons.count;
    for (NSUInteger index = 0; index < count; index++) {
        CGPoint offset = [gFollowOffsets[index] CGPointValue];
        CGPoint base = [gFollowBases[index] CGPointValue];
        FIZZRippleSetLayerTranslation(gFollowIcons[index].layer,
                                     CGPointMake(base.x + offset.x * gFollowShare,
                                                 base.y + offset.y * gFollowShare));
    }
}

// One step of the spring that carries the icons towards what the fingers ask
// for. It is what keeps them from being glued to the fingers: they trail a
// little, keep moving for a moment after the fingers stop, and press against the
// limit instead of stopping at it.
static BOOL FIZZRippleStepFollow(NSTimeInterval now) {
    if (gFollowIcons.count == 0) {
        return NO;
    }
    NSTimeInterval dt = gFollowLastTick > 0 ? now - gFollowLastTick : 1.0 / 60.0;
    gFollowLastTick = now;
    // A stalled frame must not make the spring explode.
    dt = fmin(fmax(dt, 1.0 / 240.0), 1.0 / 30.0);

    CGFloat displacement = gFollowTarget - gFollowShare;
    CGFloat acceleration = FIZZRippleSpringStiffness * displacement - FIZZRippleSpringDamping * gFollowVelocity;
    gFollowVelocity += acceleration * dt;
    gFollowShare += gFollowVelocity * dt;

    // The spring may overshoot the limit a little, which is the elasticity that
    // is wanted, but it may never leave the range or go behind the start.
    if (gFollowShare > FIZZRippleFollowLimitShare) {
        gFollowShare = FIZZRippleFollowLimitShare;
        gFollowVelocity = fmin(gFollowVelocity, 0);
    } else if (gFollowShare < 0) {
        gFollowShare = 0;
        gFollowVelocity = fmax(gFollowVelocity, 0);
    }

    FIZZRippleApplyFollow();
    return YES;
}

// Runs the spring while the fingers are down. It is started by the first
// movement of a follow leg and stopped as soon as the leg ends.
@interface FIZZFollowDriver : NSObject
@property (nonatomic, strong) CADisplayLink *link;
+ (instancetype)sharedDriver;
- (void)start;
- (void)stop;
@end

static FIZZFollowDriver *gFollowDriver = nil;

@implementation FIZZFollowDriver

+ (instancetype)sharedDriver {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gFollowDriver = [[FIZZFollowDriver alloc] init];
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
    if (!FIZZRippleStepFollow(CACurrentMediaTime())) {
        [self stop];
    }
}

@end

static void FIZZRippleResetFollowState(void) {
    [[FIZZFollowDriver sharedDriver] stop];
    [gFollowIcons removeAllObjects];
    [gFollowOffsets removeAllObjects];
    [gFollowBases removeAllObjects];
    gFollowCarried = 0;
    gFollowShare = 0;
    gFollowTarget = 0;
    gFollowVelocity = 0;
}

BOOL FIZZIconRippleBeginFollow(UIView *hostView) {
    if (!gFollowIcons) {
        gFollowIcons = [NSMutableArray array];
        gFollowOffsets = [NSMutableArray array];
        gFollowBases = [NSMutableArray array];
    }
    FIZZRippleResetFollowState();
    NSArray<UIView *> *icons = FIZZRipplePlaceIcons(hostView, gFollowOffsets);

    // A wave from the previous gesture may still be in the air. The follow leg
    // takes each icon over exactly where it is on screen — its animations are
    // dropped and that position becomes the model value — so a new spread never
    // waits for the old one to finish, and nothing jumps when it does.
    CGFloat carried = 0;
    for (NSUInteger index = 0; index < icons.count; index++) {
        UIView *icon = icons[index];
        CGPoint current = FIZZRippleCurrentOffset(icon);
        [icon.layer removeAnimationForKey:FIZZRippleTranslationKeyX];
        [icon.layer removeAnimationForKey:FIZZRippleTranslationKeyY];
        [icon.layer removeAnimationForKey:FIZZRippleReturnKeyX];
        [icon.layer removeAnimationForKey:FIZZRippleReturnKeyY];
        FIZZRippleSetLayerTranslation(icon.layer, current);
        [gFollowIcons addObject:icon];
        [gFollowBases addObject:[NSValue valueWithCGPoint:current]];

        CGPoint offset = [gFollowOffsets[index] CGPointValue];
        CGFloat squared = offset.x * offset.x + offset.y * offset.y;
        if (squared > 1.0) {
            carried += (current.x * offset.x + current.y * offset.y) / squared;
        }
    }
    if (icons.count > 0) {
        gFollowCarried = fmin(fmax(carried / (CGFloat)icons.count, 0.0), 0.9);
    }
    return gFollowIcons.count > 0;
}

void FIZZIconRippleUpdateFollow(CGFloat progress) {
    if (gFollowIcons.count == 0) {
        return;
    }
    // The fingers only set what to aim at; the spring decides where the icons
    // actually are on this frame.
    gFollowTarget = FIZZRippleFollowTargetShare(progress);
    [[FIZZFollowDriver sharedDriver] start];
}

// Carries one axis of the translation from `from` back to rest through a spring,
// so the icon overshoots its starting point by a little and settles onto it.
static void FIZZRippleAddSpringBack(CALayer *layer, NSString *keyPath, CGFloat from, NSString *key) {
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:keyPath];
    animation.fromValue = @(from);
    animation.toValue = @0.0;
    animation.mass = 1.0;
    animation.stiffness = FIZZRippleReturnStiffness;
    animation.damping = FIZZRippleReturnDamping;
    animation.initialVelocity = 0.0;
    // The settling time is only known once the spring is configured.
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:key];
}

void FIZZIconRippleEndFollow(BOOL animated) {
    NSUInteger count = gFollowIcons.count;
    for (NSUInteger index = 0; index < count; index++) {
        UIView *icon = gFollowIcons[index];
        CALayer *layer = icon.layer;
        CGPoint current = FIZZRippleCurrentOffset(icon);
        FIZZRippleSetLayerTranslation(layer, CGPointZero);
        if (!animated || hypot(current.x, current.y) < 0.5) {
            continue;
        }
        // The release springs back instead of easing back, so an icon that was
        // carried partway out passes its starting point and settles onto it
        // rather than stopping there.
        FIZZRippleAddSpringBack(layer, FIZZRippleTranslationKeyX, current.x, FIZZRippleReturnKeyX);
        FIZZRippleAddSpringBack(layer, FIZZRippleTranslationKeyY, current.y, FIZZRippleReturnKeyY);
    }
    FIZZRippleResetFollowState();
}

FIZZRippleTiming FIZZIconRippleRun(UIView *hostView) {
    FIZZRippleTiming timing = {0, 0};
    // The follow leg ends here: from this point the wave animates the icons, and
    // the last position the spring left them in is where the wave starts.
    [[FIZZFollowDriver sharedDriver] stop];
    CGFloat followShare = gFollowShare;

    UIWindow *window = hostView ? hostView.window : nil;
    if (!window) {
        FIZZRippleResetFollowState();
        return timing;
    }

    // The whole release costs one walk: the icons of the page that move, and
    // every badge on screen, wherever its icon lives.
    NSMutableArray<UIView *> *pageIcons = [NSMutableArray array];
    NSMutableArray<UIView *> *badges = [NSMutableArray array];
    FIZZRippleCollectRunViews(window, hostView, 0, NO, pageIcons, badges);

    NSMutableArray<NSValue *> *offsets = [NSMutableArray array];
    CGFloat maximumDistance = 0;
    NSArray<UIView *> *icons = FIZZRipplePlaceCollectedIcons(pageIcons, window, offsets, &maximumDistance);

    NSUInteger animated = 0;
    NSTimeInterval touchdown = 0;
    NSTimeInterval settle = 0;
    // The follow spring's speed at the instant the fingers left, in share of the
    // offset per second: every icon leaves with its own share of it.
    CGFloat shareVelocity = gFollowVelocity;
    // How much of the way the icons already are, either because the fingers
    // carried them or because the leg took over a wave still in the air, so the
    // release does not hold them still while their turn comes.
    CGFloat carried = fmin(fmax(fmax(followShare, gFollowCarried) / FIZZRippleFollowLimitShare, 0.0), 1.0);
    for (NSUInteger index = 0; index < icons.count; index++) {
        UIView *icon = icons[index];
        CGPoint offset = [offsets[index] CGPointValue];
        CGFloat length = hypot(offset.x, offset.y);
        if (length < 0.5) {
            continue;
        }

        // The wave starts from wherever the icon already is, with the speed the
        // follow leg left it with: the release continues the movement instead of
        // starting it over. A wave that replaces another one is caught mid-flight
        // the same way.
        CGPoint current = FIZZRippleCurrentOffset(icon);

        // From here on the wave animates the translation itself, so the follow
        // leg's model transform and its return animation go away.
        FIZZRippleSetLayerTranslation(icon.layer, CGPointZero);
        [icon.layer removeAnimationForKey:FIZZRippleReturnKeyX];
        [icon.layer removeAnimationForKey:FIZZRippleReturnKeyY];

        CGFloat progress = fmin(length / FIZZRippleMaximumOffset, 1.0);
        // A gesture the fingers already carried part of the way does not hold
        // its icons still for their turn: the stagger only remains for the part
        // of the wave that has not started yet.
        NSTimeInterval delay = FIZZRippleMaximumDelay * progress * (1.0 - carried);
        CGPoint velocity = CGPointMake(offset.x * shareVelocity, offset.y * shareVelocity);
        FIZZRippleReleaseTiming release = FIZZRippleAddRelease(icon.layer, offset, current, velocity, delay);
        if (release.touchdown > touchdown) {
            touchdown = release.touchdown;
        }
        if (release.settle > settle) {
            settle = release.settle;
        }
        animated++;
    }

    // Every badge leaves on the same rule the icons use — its distance to the
    // screen center over the scale the wave is drawn at — so a badge on a page
    // keeps exactly the delay of its own icon, and the Dock's badges join the
    // same wave even though their icons stay where they are.
    CGPoint anchor = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    NSUInteger popping = 0;
    for (UIView *badge in badges) {
        NSTimeInterval badgeDelay = 0;
        if (maximumDistance > 0.5) {
            CGPoint center =
                [badge convertPoint:CGPointMake(CGRectGetMidX(badge.bounds), CGRectGetMidY(badge.bounds))
                             toView:window];
            CGFloat progress = fmin(hypot(center.x - anchor.x, center.y - anchor.y) / maximumDistance, 1.0);
            badgeDelay = FIZZRippleMaximumDelay * progress * (1.0 - carried);
        }
        FIZZBadgePopBadge(badge, FIZZRippleDuration, badgeDelay);
        popping++;
    }

    FIZZRippleResetFollowState();

    if (animated == 0 && popping == 0) {
        return timing;
    }
    if (animated > 0) {
        // The wave is over when the last icon is asleep, not at a fixed length.
        timing.settle = settle;
    } else {
        // Nothing moved, so the wave has no beat here: the clear waits for the
        // last bubble instead.
        timing.settle = FIZZRippleDuration * FIZZBadgePopBeatShare + FIZZRippleMaximumDelay;
    }
    timing.touchdown = touchdown;
    return timing;
}
