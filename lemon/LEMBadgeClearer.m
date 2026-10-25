//
//  LEMBadgeClearer.m
//  Lemon
//
//  Clearing badges has four sides, all of them found by dumping and watching the
//  running SpringBoard:
//
//  Data: an SBApplicationIcon carries badgeNumberOrString, but the value is only
//  forwarded from its SBApplication, which owns badgeValue and
//  -setBadgeValue:. Only -setBadgeValue:nil on the application really clears the
//  badge; -setBadge: on the icon and -noteBadgeDidChange then tell the icon
//  views to reload. SpringBoard has no single "clear all badges" method, so
//  every leaf icon is walked.
//
//  Persistence: the count does not only live in SpringBoard. An application
//  publishes its own badge when it leaves the foreground, over BoardServices and
//  UIKitServices, and SpringBoard hands the value back after its own restart.
//  Clearing the objects is therefore never enough: the old number returns as
//  soon as the application is opened again. So every bundle Lemon clears is
//  remembered with the count it had, and a later write of exactly that count is
//  dropped before it reaches SBApplication. A different count is a real change
//  (messages read, new messages) and goes through, which also releases the
//  bundle again.
//
//  View: the badge is an SBIconBadgeView, a subview of the icon's image view
//  that is configured with -configureForIcon:infoProvider: and recycled with
//  -prepareForReuse. It leaves as a bubble does, on the beat of the icon ripple
//  — same duration, same per-icon delay — puffing up, then bursting in the last
//  tenth of that beat with a thin ring thrown outward. The data is cleared only
//  after the ripple has settled, because clearing it up front makes SpringBoard
//  drop the badge view at once and the pop is never seen.
//
//  Reuse: an SBIconBadgeView is handed to another icon while scrolling, so the
//  pop, the hidden flag and a lowered alpha are all reset at the two entry
//  points SpringBoard uses to reuse it. That keeps a real badge, arriving
//  later, visible.
//

#import "LEMBadgeClearer.h"

#import "LEMHook.h"
#import "LEMPreferences.h"
#import "LEMSpringBoard.h"
#import "LEMState.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>
#import <os/lock.h>

static NSString *const LEMBadgePopKey = @"com.lemon.badge.pop";
static NSString *const LEMBadgePopScaleKey = @"com.lemon.badge.pop.scale";
static NSString *const LEMBadgeBurstRingKey = @"com.lemon.badge.pop.ring";
static NSString *const LEMBadgeStateFileName = @"badge-suppression.plist";

static NSHashTable<UIView *> *gPoppingBadgeViews = nil;

// Set while Lemon itself is writing the badge values, so the write gate can tell
// its own clearing apart from a badge the system hands back.
static BOOL gInsideSelfClear = NO;

#pragma mark - Suppression state

// The cleared count of every bundle Lemon has cleared, keyed by bundle
// identifier.
static os_unfair_lock gSuppressionLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *gSuppressedBadges = nil;

// The caller holds gSuppressionLock.
static NSMutableDictionary<NSString *, NSNumber *> *LEMBadgeSuppressionTableLocked(void) {
    if (!gSuppressedBadges) {
        NSDictionary<NSString *, NSNumber *> *stored = LEMStateRead(LEMBadgeStateFileName);
        gSuppressedBadges = stored.count > 0 ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    }
    return gSuppressedBadges;
}

// The caller holds gSuppressionLock.
static void LEMBadgeSuppressionSaveLocked(void) {
    LEMStateWrite(LEMBadgeStateFileName, [gSuppressedBadges copy]);
}

static long long LEMBadgeIntegerValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value longLongValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value longLongValue];
    }
    return 0;
}

// Remembers the count that was just cleared. A later write of that exact count
// is the stale value the application keeps publishing, not a new one.
static void LEMBadgeRecordBaseline(NSString *bundleIdentifier, id badge) {
    if (bundleIdentifier.length == 0) {
        return;
    }
    long long baseline = LEMBadgeIntegerValue(badge);
    os_unfair_lock_lock(&gSuppressionLock);
    NSMutableDictionary<NSString *, NSNumber *> *table = LEMBadgeSuppressionTableLocked();
    NSNumber *previous = table[bundleIdentifier];
    if (!previous || previous.longLongValue != baseline) {
        table[bundleIdentifier] = @(baseline);
        LEMBadgeSuppressionSaveLocked();
    }
    os_unfair_lock_unlock(&gSuppressionLock);
}

// YES means the write only repeats the count Lemon has already cleared, so the
// caller drops it. Any other count is a real change: it is let through and the
// bundle is released from suppression.
static BOOL LEMBadgeShouldSuppressWrite(NSString *bundleIdentifier, id value) {
    if (bundleIdentifier.length == 0 || value == nil) {
        return NO;
    }
    // With the switch off nothing is held back: a badge the application
    // publishes shows up again, as it did before the suppression layer existed.
    if (!LEMBadgeSuppressionEnabled()) {
        return NO;
    }
    long long incoming = LEMBadgeIntegerValue(value);
    BOOL suppress = NO;

    os_unfair_lock_lock(&gSuppressionLock);
    NSMutableDictionary<NSString *, NSNumber *> *table = LEMBadgeSuppressionTableLocked();
    NSNumber *baseline = table[bundleIdentifier];
    if (baseline) {
        if (baseline.longLongValue == incoming) {
            suppress = YES;
        } else {
            [table removeObjectForKey:bundleIdentifier];
            LEMBadgeSuppressionSaveLocked();
        }
    }
    os_unfair_lock_unlock(&gSuppressionLock);

    return suppress;
}

#pragma mark - Reuse resets

static void (*LEMOriginalBadgePrepareForReuse)(id, SEL) = NULL;
static void (*LEMOriginalBadgeConfigure)(id, SEL, id, id) = NULL;
static void (*LEMOriginalBadgeConfigureAnimated)(id, SEL, id, id, id) = NULL;

static void LEMBadgeRemoveBurstRing(UIView *badge);

static void LEMBadgeResetView(UIView *view) {
    [view.layer removeAnimationForKey:LEMBadgePopKey];
    [view.layer removeAnimationForKey:LEMBadgePopScaleKey];
    LEMBadgeRemoveBurstRing(view);
    view.hidden = NO;
    view.alpha = 1.0;
}

static void LEMHookedBadgePrepareForReuse(SBIconBadgeView *self, SEL _cmd) {
    LEMBadgeResetView(self);
    if (LEMOriginalBadgePrepareForReuse) {
        LEMOriginalBadgePrepareForReuse(self, _cmd);
    }
}

static void LEMHookedBadgeConfigure(SBIconBadgeView *self, SEL _cmd, SBIcon *icon, id provider) {
    LEMBadgeResetView(self);
    if (LEMOriginalBadgeConfigure) {
        LEMOriginalBadgeConfigure(self, _cmd, icon, provider);
    }
}

static void LEMHookedBadgeConfigureAnimated(SBIconBadgeView *self, SEL _cmd, SBIcon *icon, id provider,
                                            id animator) {
    LEMBadgeResetView(self);
    if (LEMOriginalBadgeConfigureAnimated) {
        LEMOriginalBadgeConfigureAnimated(self, _cmd, icon, provider, animator);
    }
}

#pragma mark - Write gate

// The writes Lemon watches. Only the application write is altered (the stale
// count is dropped); the icon write is dropped only when it repeats a cleared
// count.
static void (*LEMOriginalSetBadgeValue)(id, SEL, id) = NULL;
static void (*LEMOriginalRemoteBadgeValueDidChange)(id, SEL) = NULL;
static void (*LEMOriginalIconSetBadge)(id, SEL, id) = NULL;

static void LEMHookedSetBadgeValue(SBApplication *self, SEL _cmd, id value) {
    if (!gInsideSelfClear) {
        NSString *bundleIdentifier =
            [self respondsToSelector:@selector(bundleIdentifier)] ? self.bundleIdentifier : nil;
        if (LEMBadgeShouldSuppressWrite(bundleIdentifier, value)) {
            return;
        }
    }
    if (LEMOriginalSetBadgeValue) {
        LEMOriginalSetBadgeValue(self, _cmd, value);
    }
}

static void LEMHookedRemoteBadgeValueDidChange(SBApplication *self, SEL _cmd) {
    if (!gInsideSelfClear) {
        NSString *bundleIdentifier =
            [self respondsToSelector:@selector(bundleIdentifier)] ? self.bundleIdentifier : nil;
        id value = [self respondsToSelector:@selector(badgeValue)] ? self.badgeValue : nil;
        if (value && LEMBadgeShouldSuppressWrite(bundleIdentifier, value)) {
            return;
        }
    }
    if (LEMOriginalRemoteBadgeValueDidChange) {
        LEMOriginalRemoteBadgeValueDidChange(self, _cmd);
    }
}

static void LEMHookedIconSetBadge(SBIcon *self, SEL _cmd, id badge) {
    if (!gInsideSelfClear && badge) {
        SBApplication *application =
            [self respondsToSelector:@selector(application)] ? self.application : nil;
        NSString *bundleIdentifier = [application respondsToSelector:@selector(bundleIdentifier)]
                                         ? application.bundleIdentifier
                                         : nil;
        if (LEMBadgeShouldSuppressWrite(bundleIdentifier, badge)) {
            return;
        }
    }
    if (LEMOriginalIconSetBadge) {
        LEMOriginalIconSetBadge(self, _cmd, badge);
    }
}

#pragma mark - Hook installation

// Bit mask of installed hooks: prepareForReuse, configureForIcon:infoProvider:,
// configureAnimatedForIcon:infoProvider:animator:, SBApplication
// -setBadgeValue:, -remoteBadgeValueDidChange and SBIcon -setBadge:.
static const NSUInteger LEMBadgeHookMaskComplete = 63;
static NSUInteger gBadgeHookMask = 0;

static void LEMBadgeInstallHooks(void) {
    Class badgeClass = objc_getClass("SBIconBadgeView");
    if (badgeClass) {
        if (!(gBadgeHookMask & 1) &&
            LEMInstallHook(badgeClass, @selector(prepareForReuse), (IMP)LEMHookedBadgePrepareForReuse,
                           (IMP *)&LEMOriginalBadgePrepareForReuse)) {
            gBadgeHookMask |= 1;
        }
        if (!(gBadgeHookMask & 2) &&
            LEMInstallHook(badgeClass, NSSelectorFromString(@"configureForIcon:infoProvider:"),
                           (IMP)LEMHookedBadgeConfigure, (IMP *)&LEMOriginalBadgeConfigure)) {
            gBadgeHookMask |= 2;
        }
        if (!(gBadgeHookMask & 4) &&
            LEMInstallHook(badgeClass, NSSelectorFromString(@"configureAnimatedForIcon:infoProvider:animator:"),
                           (IMP)LEMHookedBadgeConfigureAnimated,
                           (IMP *)&LEMOriginalBadgeConfigureAnimated)) {
            gBadgeHookMask |= 4;
        }
    }

    if (!(gBadgeHookMask & 8) &&
        LEMInstallHook(objc_getClass("SBApplication"), @selector(setBadgeValue:),
                       (IMP)LEMHookedSetBadgeValue, (IMP *)&LEMOriginalSetBadgeValue)) {
        gBadgeHookMask |= 8;
    }

    SEL remoteSelector = NSSelectorFromString(@"remoteBadgeValueDidChange");
    if (!(gBadgeHookMask & 16)) {
        Class owner = LEMHookOwner(objc_getClass("SBApplication"), remoteSelector);
        if (!owner) {
            owner = LEMHookOwner(objc_getClass("SBHSimpleApplication"), remoteSelector);
        }
        if (LEMInstallHook(owner, remoteSelector, (IMP)LEMHookedRemoteBadgeValueDidChange,
                           (IMP *)&LEMOriginalRemoteBadgeValueDidChange)) {
            gBadgeHookMask |= 16;
        }
    }

    if (!(gBadgeHookMask & 32) &&
        LEMInstallHook(objc_getClass("SBIcon"), @selector(setBadge:), (IMP)LEMHookedIconSetBadge,
                       (IMP *)&LEMOriginalIconSetBadge)) {
        gBadgeHookMask |= 32;
    }
}

void LEMBadgeInstallWatchers(void) {
    LEMBadgeInstallHooks();
    if (gBadgeHookMask == LEMBadgeHookMaskComplete) {
        return;
    }
    // A class SpringBoard has not registered yet is retried, but each hook is
    // installed at most once so a retry can never wrap Lemon around itself.
    static NSUInteger attempts = 0;
    if (attempts++ >= 50) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       LEMBadgeInstallWatchers();
                   });
}

#pragma mark - Views

// A badge leaves the way a soap bubble does: it puffs up and holds while the
// icon springs back, then bursts in the last tenth of the beat and throws a thin
// ring outward. The scale and the opacity share one duration, so the pop lands
// exactly where the old fade used to end.
static const CGFloat LEMBadgePopScaleValues[] = { 1.0, 1.24, 1.18, 1.46 };
static const CGFloat LEMBadgePopScaleTimes[] = { 0.0, 0.34, 0.80, 1.0 };
static const CGFloat LEMBadgePopOpacityValues[] = { 1.0, 1.0, 0.92, 0.0 };
static const CGFloat LEMBadgePopOpacityTimes[] = { 0.0, 0.50, 0.82, 1.0 };
static const CGFloat LEMBadgeBurstRingStart = 0.82;

static NSMapTable<UIView *, CAShapeLayer *> *gBadgeRings = nil;

// A badge keeps its ring in the superview, so a second pop must first take the
// ring of the first one away instead of stacking another one on top of it.
static void LEMBadgeRemoveBurstRing(UIView *badge) {
    CAShapeLayer *ring = [gBadgeRings objectForKey:badge];
    if (ring) {
        [ring removeFromSuperlayer];
        [gBadgeRings removeObjectForKey:badge];
    }
}

static NSArray<NSNumber *> *LEMBadgeScaledValues(const CGFloat *values, NSUInteger count,
                                                 CGFloat baseScale) {
    NSMutableArray<NSNumber *> *scaled = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [scaled addObject:@(values[index] * baseScale)];
    }
    return scaled;
}

static NSArray<NSNumber *> *LEMBadgeNumbers(const CGFloat *values, NSUInteger count) {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [numbers addObject:@(values[index])];
    }
    return numbers;
}

static UIColor *LEMBadgeBubbleColor(UIView *badge) {
    UIColor *background = badge.backgroundColor;
    if (background && CGColorGetAlpha(background.CGColor) > 0.05) {
        return background;
    }
    return badge.tintColor ?: [UIColor systemRedColor];
}

// The ring lives in the badge's superview, since the badge itself is scaled by
// the pop. It stays at zero opacity until the burst, so nothing shows during the
// delay of the icons farther out.
static void LEMBadgeAddBurstRing(UIView *badge, NSTimeInterval beginTime,
                                 NSTimeInterval duration) {
    UIView *container = badge.superview;
    if (!container || duration <= 0) {
        return;
    }
    if (!gBadgeRings) {
        gBadgeRings = [NSMapTable weakToStrongObjectsMapTable];
    }
    LEMBadgeRemoveBurstRing(badge);
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = badge.frame;
    CGRect bounds = ring.bounds;
    if (CGRectGetWidth(bounds) < 2 || CGRectGetHeight(bounds) < 2) {
        return;
    }
    ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(bounds, 0.75, 0.75)].CGPath;
    ring.fillColor = UIColor.clearColor.CGColor;
    ring.strokeColor = LEMBadgeBubbleColor(badge).CGColor;
    ring.lineWidth = 1.5;
    ring.opacity = 0.0f;
    [container.layer addSublayer:ring];

    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[ @0.0, @0.0, @0.95, @0.0 ];
    fade.keyTimes = @[
        @0.0, @(LEMBadgeBurstRingStart), @(LEMBadgeBurstRingStart + 0.05), @1.0
    ];
    fade.duration = duration;
    fade.beginTime = beginTime;
    fade.fillMode = kCAFillModeForwards;
    fade.removedOnCompletion = NO;
    [ring addAnimation:fade forKey:LEMBadgeBurstRingKey];

    CAKeyframeAnimation *scale = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    scale.values = @[ @1.0, @1.0, @2.05 ];
    scale.keyTimes = @[ @0.0, @(LEMBadgeBurstRingStart), @1.0 ];
    scale.duration = duration;
    scale.beginTime = beginTime;
    scale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    scale.fillMode = kCAFillModeForwards;
    scale.removedOnCompletion = NO;
    [ring addAnimation:scale forKey:LEMBadgeBurstRingKey];

    if (!gBadgeRings) {
        gBadgeRings = [NSMapTable weakToStrongObjectsMapTable];
    }
    [gBadgeRings setObject:ring forKey:badge];
}

// Where the badge is on screen right now. A badge that is popped again while its
// first bubble is still in the air continues from that size and that opacity
// instead of snapping back to full.
static CATransform3D LEMBadgePresentationTransform(UIView *badge) {
    CALayer *presentation = badge.layer.presentationLayer;
    return presentation ? presentation.transform : badge.layer.transform;
}

static CGFloat LEMBadgePresentationOpacity(UIView *badge) {
    CALayer *presentation = badge.layer.presentationLayer;
    return presentation ? (CGFloat)presentation.opacity : (CGFloat)badge.layer.opacity;
}

static void LEMBadgePopView(UIView *badge, NSTimeInterval duration, NSTimeInterval beginTime) {
    // A badge that already carries a scale keeps it, so the puff multiplies what
    // is there instead of snapping the view back to 1.
    CATransform3D transform = LEMBadgePresentationTransform(badge);
    CGFloat baseScale = sqrt(transform.m11 * transform.m11 + transform.m12 * transform.m12);
    if (!(baseScale > 0.01)) {
        baseScale = 1.0;
    }
    CGFloat startOpacity = fmin(fmax(LEMBadgePresentationOpacity(badge), 0.0), 1.0);

    CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pop.values = LEMBadgeScaledValues(LEMBadgePopScaleValues, 4, baseScale);
    pop.keyTimes = LEMBadgeNumbers(LEMBadgePopScaleTimes, 4);
    pop.duration = duration;
    pop.beginTime = beginTime;
    pop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    pop.fillMode = kCAFillModeForwards;
    pop.removedOnCompletion = NO;
    [badge.layer addAnimation:pop forKey:LEMBadgePopScaleKey];

    // The bubble stays solid for most of the beat, so the burst reads as the film
    // breaking instead of the badge fading away.
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    if (startOpacity < 0.999) {
        fade.values = @[ @(startOpacity), @(startOpacity), @(startOpacity * 0.92), @0.0 ];
    } else {
        fade.values = LEMBadgeNumbers(LEMBadgePopOpacityValues, 4);
    }
    fade.keyTimes = LEMBadgeNumbers(LEMBadgePopOpacityTimes, 4);
    fade.duration = duration;
    fade.beginTime = beginTime;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    fade.fillMode = kCAFillModeForwards;
    fade.removedOnCompletion = NO;
    [badge.layer addAnimation:fade forKey:LEMBadgePopKey];

    LEMBadgeAddBurstRing(badge, beginTime, duration);
}

static NSUInteger LEMBadgePopTree(UIView *view, Class badgeClass, NSTimeInterval duration,
                                  NSTimeInterval beginTime) {
    if (!view) {
        return 0;
    }
    NSUInteger popped = 0;
    if ([view isKindOfClass:badgeClass] && view.window && !view.hidden) {
        // Same duration and delay as the icon's own keyframe animation, so the
        // burst lands as the icon comes to rest and the last badge is gone.
        LEMBadgePopView(view, duration, beginTime);
        [gPoppingBadgeViews addObject:view];
        popped++;
    }
    for (UIView *child in view.subviews) {
        popped += LEMBadgePopTree(child, badgeClass, duration, beginTime);
    }
    return popped;
}

void LEMBadgePopWithRipple(UIView *iconView, NSTimeInterval duration, NSTimeInterval delay) {
    Class badgeClass = objc_getClass("SBIconBadgeView");
    if (!iconView || !badgeClass || duration <= 0) {
        return;
    }
    if (!gPoppingBadgeViews) {
        gPoppingBadgeViews = [NSHashTable weakObjectsHashTable];
    }
    LEMBadgePopTree(iconView, badgeClass, duration, CACurrentMediaTime() + delay);
}

// Runs once the ripple is over: a badge whose icon is still badged would pop back
// in when the animation is dropped, so the view stays hidden instead. The reuse
// hooks above lift the flag again as soon as SpringBoard reconfigures the view.
static void LEMBadgeSettlePopped(void) {
    for (UIView *view in gPoppingBadgeViews.allObjects) {
        LEMBadgeResetView(view);
        if (view.window && !view.hidden) {
            view.hidden = YES;
        }
    }
    [gPoppingBadgeViews removeAllObjects];
    for (CAShapeLayer *ring in gBadgeRings.objectEnumerator) {
        [ring removeFromSuperlayer];
    }
    [gBadgeRings removeAllObjects];
}

#pragma mark - Data

static SBIconModel *LEMBadgeIconModel(void) {
    Class controllerClass = objc_getClass("SBIconController");
    if (!controllerClass) {
        return nil;
    }
    SBIconController *controller = [(id)controllerClass sharedInstance];
    if (![controller respondsToSelector:@selector(iconManager)]) {
        return nil;
    }
    SBHIconManager *iconManager = controller.iconManager;
    if (![iconManager respondsToSelector:@selector(iconModel)]) {
        return nil;
    }
    return iconManager.iconModel;
}

// Clears one icon. Leaving out the application does not stick: the icon only
// forwards its application's badge value, so the badge comes straight back.
static void LEMBadgeClearIcon(SBIcon *icon) {
    if ([icon respondsToSelector:@selector(application)]) {
        SBApplication *application = icon.application;
        if ([application respondsToSelector:@selector(setBadgeValue:)]) {
            [application setBadgeValue:nil];
        }
    }
    if ([icon respondsToSelector:@selector(setBadge:)]) {
        [icon setBadge:nil];
    }
    if ([icon respondsToSelector:@selector(noteBadgeDidChange)]) {
        [icon noteBadgeDidChange];
    }
}

static NSString *LEMBadgeBundleIdentifier(SBIcon *icon) {
    SBApplication *application = [icon respondsToSelector:@selector(application)] ? icon.application : nil;
    return [application respondsToSelector:@selector(bundleIdentifier)] ? application.bundleIdentifier : nil;
}

BOOL LEMBadgeHasBadges(void) {
    SBIconModel *iconModel = LEMBadgeIconModel();
    NSArray *leafIcons = [iconModel respondsToSelector:@selector(leafIcons)] ? iconModel.leafIcons : nil;
    for (SBIcon *icon in leafIcons) {
        if (![icon respondsToSelector:@selector(badgeNumberOrString)]) {
            continue;
        }
        id badge = icon.badgeNumberOrString;
        // A zero is what SpringBoard stores for "no badge"; only a positive
        // count would be wiped by the clear.
        if (badge && LEMBadgeIntegerValue(badge) > 0) {
            return YES;
        }
    }
    return NO;
}

void LEMBadgeClearAll(void) {
    if (!LEMFeatureEnabled()) {
        return;
    }
    LEMBadgeInstallWatchers();

    SBIconModel *iconModel = LEMBadgeIconModel();
    NSArray *leafIcons = [iconModel respondsToSelector:@selector(leafIcons)] ? iconModel.leafIcons : nil;
    if (leafIcons.count > 0) {
        gInsideSelfClear = YES;
        for (SBIcon *icon in leafIcons) {
            if (![icon respondsToSelector:@selector(badgeNumberOrString)]) {
                continue;
            }
            id badge = icon.badgeNumberOrString;
            if (!badge) {
                continue;
            }
            // Remember the count before it is cleared: this is what the
            // application will publish again on its next exit. Only the
            // suppression layer keeps those counts; with it off the clear still
            // happens, but nothing is held back afterwards.
            if (LEMBadgeSuppressionEnabled()) {
                LEMBadgeRecordBaseline(LEMBadgeBundleIdentifier(icon), badge);
            }
            LEMBadgeClearIcon(icon);
        }
        gInsideSelfClear = NO;
    }

    // The ripple has settled by now: every popped view has finished its beat. Drop
    // the animations and keep the views hidden; icons whose data really went away
    // have had their badge views removed already.
    LEMBadgeSettlePopped();
}
