//
//  FIZZBadgeClearer.m
//  Fizz
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
//  soon as the application is opened again. So every bundle Fizz clears is
//  remembered with the count it had, and a later write of exactly that count is
//  dropped before it reaches SBApplication. A different count is a real change
//  (messages read, new messages) and goes through, which also releases the
//  bundle again.
//
//  View: the badge is an SBIconBadgeView, a subview of the icon's image view
//  that is configured with -configureForIcon:infoProvider: and recycled with
//  -prepareForReuse. It leaves the same beat as its icon — same duration, same
//  per-icon delay — growing while it fades out, and nothing else: the finer
//  detail of a pop is over before it can be seen. The data is cleared only after
//  the ripple has settled, because clearing it up front makes SpringBoard drop
//  the badge view at once and the fade is never seen.
//
//  Reuse: an SBIconBadgeView is handed to another icon while scrolling, so the
//  pop, the hidden flag and a lowered alpha are all reset at the two entry
//  points SpringBoard uses to reuse it. That keeps a real badge, arriving
//  later, visible.
//

#import "FIZZBadgeClearer.h"

#import "FIZZHook.h"
#import "FIZZPreferences.h"
#import "FIZZSpringBoard.h"
#import "FIZZState.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>
#import <os/lock.h>

static NSString *const FIZZBadgePopKey = @"com.fizz.badge.pop";
static NSString *const FIZZBadgePopScaleKey = @"com.fizz.badge.pop.scale";
static NSString *const FIZZBadgeStateFileName = @"badge-suppression.plist";

static NSHashTable<UIView *> *gPoppingBadgeViews = nil;

// Set while Fizz itself is writing the badge values, so the write gate can tell
// its own clearing apart from a badge the system hands back.
static BOOL gInsideSelfClear = NO;

#pragma mark - Suppression state

// The cleared count of every bundle Fizz has cleared, keyed by bundle
// identifier.
static os_unfair_lock gSuppressionLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *gSuppressedBadges = nil;

// The caller holds gSuppressionLock.
static NSMutableDictionary<NSString *, NSNumber *> *FIZZBadgeSuppressionTableLocked(void) {
    if (!gSuppressedBadges) {
        NSDictionary<NSString *, NSNumber *> *stored = FIZZStateRead(FIZZBadgeStateFileName);
        gSuppressedBadges = stored.count > 0 ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    }
    return gSuppressedBadges;
}

// The caller holds gSuppressionLock.
static void FIZZBadgeSuppressionSaveLocked(void) {
    FIZZStateWrite(FIZZBadgeStateFileName, [gSuppressedBadges copy]);
}

static long long FIZZBadgeIntegerValue(id value) {
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
static void FIZZBadgeRecordBaseline(NSString *bundleIdentifier, id badge) {
    if (bundleIdentifier.length == 0) {
        return;
    }
    long long baseline = FIZZBadgeIntegerValue(badge);
    os_unfair_lock_lock(&gSuppressionLock);
    NSMutableDictionary<NSString *, NSNumber *> *table = FIZZBadgeSuppressionTableLocked();
    NSNumber *previous = table[bundleIdentifier];
    if (!previous || previous.longLongValue != baseline) {
        table[bundleIdentifier] = @(baseline);
        FIZZBadgeSuppressionSaveLocked();
    }
    os_unfair_lock_unlock(&gSuppressionLock);
}

// YES means the write only repeats the count Fizz has already cleared, so the
// caller drops it. Any other count is a real change: it is let through and the
// bundle is released from suppression.
static BOOL FIZZBadgeShouldSuppressWrite(NSString *bundleIdentifier, id value) {
    if (bundleIdentifier.length == 0 || value == nil) {
        return NO;
    }
    // With the switch off nothing is held back: a badge the application
    // publishes shows up again, as it did before the suppression layer existed.
    if (!FIZZBadgeSuppressionEnabled()) {
        return NO;
    }
    long long incoming = FIZZBadgeIntegerValue(value);
    BOOL suppress = NO;

    os_unfair_lock_lock(&gSuppressionLock);
    NSMutableDictionary<NSString *, NSNumber *> *table = FIZZBadgeSuppressionTableLocked();
    NSNumber *baseline = table[bundleIdentifier];
    if (baseline) {
        if (baseline.longLongValue == incoming) {
            suppress = YES;
        } else {
            [table removeObjectForKey:bundleIdentifier];
            FIZZBadgeSuppressionSaveLocked();
        }
    }
    os_unfair_lock_unlock(&gSuppressionLock);

    return suppress;
}

#pragma mark - Reuse resets

static void (*FIZZOriginalBadgePrepareForReuse)(id, SEL) = NULL;
static void (*FIZZOriginalBadgeConfigure)(id, SEL, id, id) = NULL;
static void (*FIZZOriginalBadgeConfigureAnimated)(id, SEL, id, id, id) = NULL;

static void FIZZBadgeResetView(UIView *view) {
    [view.layer removeAnimationForKey:FIZZBadgePopKey];
    [view.layer removeAnimationForKey:FIZZBadgePopScaleKey];
    view.hidden = NO;
    view.alpha = 1.0;
}

static void FIZZHookedBadgePrepareForReuse(SBIconBadgeView *self, SEL _cmd) {
    FIZZBadgeResetView(self);
    if (FIZZOriginalBadgePrepareForReuse) {
        FIZZOriginalBadgePrepareForReuse(self, _cmd);
    }
}

static void FIZZHookedBadgeConfigure(SBIconBadgeView *self, SEL _cmd, SBIcon *icon, id provider) {
    FIZZBadgeResetView(self);
    if (FIZZOriginalBadgeConfigure) {
        FIZZOriginalBadgeConfigure(self, _cmd, icon, provider);
    }
}

static void FIZZHookedBadgeConfigureAnimated(SBIconBadgeView *self, SEL _cmd, SBIcon *icon, id provider,
                                            id animator) {
    FIZZBadgeResetView(self);
    if (FIZZOriginalBadgeConfigureAnimated) {
        FIZZOriginalBadgeConfigureAnimated(self, _cmd, icon, provider, animator);
    }
}

#pragma mark - Write gate

// The writes Fizz watches. Only the application write is altered (the stale
// count is dropped); the icon write is dropped only when it repeats a cleared
// count.
static void (*FIZZOriginalSetBadgeValue)(id, SEL, id) = NULL;
static void (*FIZZOriginalRemoteBadgeValueDidChange)(id, SEL) = NULL;
static void (*FIZZOriginalIconSetBadge)(id, SEL, id) = NULL;

static void FIZZHookedSetBadgeValue(SBApplication *self, SEL _cmd, id value) {
    if (!gInsideSelfClear) {
        NSString *bundleIdentifier =
            [self respondsToSelector:@selector(bundleIdentifier)] ? self.bundleIdentifier : nil;
        if (FIZZBadgeShouldSuppressWrite(bundleIdentifier, value)) {
            return;
        }
    }
    if (FIZZOriginalSetBadgeValue) {
        FIZZOriginalSetBadgeValue(self, _cmd, value);
    }
}

static void FIZZHookedRemoteBadgeValueDidChange(SBApplication *self, SEL _cmd) {
    if (!gInsideSelfClear) {
        NSString *bundleIdentifier =
            [self respondsToSelector:@selector(bundleIdentifier)] ? self.bundleIdentifier : nil;
        id value = [self respondsToSelector:@selector(badgeValue)] ? self.badgeValue : nil;
        if (value && FIZZBadgeShouldSuppressWrite(bundleIdentifier, value)) {
            return;
        }
    }
    if (FIZZOriginalRemoteBadgeValueDidChange) {
        FIZZOriginalRemoteBadgeValueDidChange(self, _cmd);
    }
}

static void FIZZHookedIconSetBadge(SBIcon *self, SEL _cmd, id badge) {
    if (!gInsideSelfClear && badge) {
        SBApplication *application =
            [self respondsToSelector:@selector(application)] ? self.application : nil;
        NSString *bundleIdentifier = [application respondsToSelector:@selector(bundleIdentifier)]
                                         ? application.bundleIdentifier
                                         : nil;
        if (FIZZBadgeShouldSuppressWrite(bundleIdentifier, badge)) {
            return;
        }
    }
    if (FIZZOriginalIconSetBadge) {
        FIZZOriginalIconSetBadge(self, _cmd, badge);
    }
}

#pragma mark - Hook installation

// Bit mask of installed hooks: prepareForReuse, configureForIcon:infoProvider:,
// configureAnimatedForIcon:infoProvider:animator:, SBApplication
// -setBadgeValue:, -remoteBadgeValueDidChange and SBIcon -setBadge:.
static const NSUInteger FIZZBadgeHookMaskComplete = 63;
static NSUInteger gBadgeHookMask = 0;

static void FIZZBadgeInstallHooks(void) {
    Class badgeClass = objc_getClass("SBIconBadgeView");
    if (badgeClass) {
        if (!(gBadgeHookMask & 1) &&
            FIZZInstallHook(badgeClass, @selector(prepareForReuse), (IMP)FIZZHookedBadgePrepareForReuse,
                           (IMP *)&FIZZOriginalBadgePrepareForReuse)) {
            gBadgeHookMask |= 1;
        }
        if (!(gBadgeHookMask & 2) &&
            FIZZInstallHook(badgeClass, NSSelectorFromString(@"configureForIcon:infoProvider:"),
                           (IMP)FIZZHookedBadgeConfigure, (IMP *)&FIZZOriginalBadgeConfigure)) {
            gBadgeHookMask |= 2;
        }
        if (!(gBadgeHookMask & 4) &&
            FIZZInstallHook(badgeClass, NSSelectorFromString(@"configureAnimatedForIcon:infoProvider:animator:"),
                           (IMP)FIZZHookedBadgeConfigureAnimated,
                           (IMP *)&FIZZOriginalBadgeConfigureAnimated)) {
            gBadgeHookMask |= 4;
        }
    }

    if (!(gBadgeHookMask & 8) &&
        FIZZInstallHook(objc_getClass("SBApplication"), @selector(setBadgeValue:),
                       (IMP)FIZZHookedSetBadgeValue, (IMP *)&FIZZOriginalSetBadgeValue)) {
        gBadgeHookMask |= 8;
    }

    SEL remoteSelector = NSSelectorFromString(@"remoteBadgeValueDidChange");
    if (!(gBadgeHookMask & 16)) {
        Class owner = FIZZHookOwner(objc_getClass("SBApplication"), remoteSelector);
        if (!owner) {
            owner = FIZZHookOwner(objc_getClass("SBHSimpleApplication"), remoteSelector);
        }
        if (FIZZInstallHook(owner, remoteSelector, (IMP)FIZZHookedRemoteBadgeValueDidChange,
                           (IMP *)&FIZZOriginalRemoteBadgeValueDidChange)) {
            gBadgeHookMask |= 16;
        }
    }

    if (!(gBadgeHookMask & 32) &&
        FIZZInstallHook(objc_getClass("SBIcon"), @selector(setBadge:), (IMP)FIZZHookedIconSetBadge,
                       (IMP *)&FIZZOriginalIconSetBadge)) {
        gBadgeHookMask |= 32;
    }
}

void FIZZBadgeInstallWatchers(void) {
    FIZZBadgeInstallHooks();
    if (gBadgeHookMask == FIZZBadgeHookMaskComplete) {
        return;
    }
    // A class SpringBoard has not registered yet is retried, but each hook is
    // installed at most once so a retry can never wrap Fizz around itself.
    static NSUInteger attempts = 0;
    if (attempts++ >= 50) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       FIZZBadgeInstallWatchers();
                   });
}

#pragma mark - Views

// A badge leaves on the beat of its icon: it grows while it fades out, on the
// same per-icon delay, and nothing else is done to it.
static const CGFloat FIZZBadgePopScale = 1.45;

// Half the beat: the bubble is gone while its icon is still on the way back.
const NSTimeInterval FIZZBadgePopBeatShare = 0.5;

// Where the badge is on screen right now. A badge that is popped again while its
// first bubble is still in the air continues from that size and that opacity
// instead of snapping back to full.
static CATransform3D FIZZBadgePresentationTransform(UIView *badge) {
    CALayer *presentation = badge.layer.presentationLayer;
    return presentation ? presentation.transform : badge.layer.transform;
}

static CGFloat FIZZBadgePresentationOpacity(UIView *badge) {
    CALayer *presentation = badge.layer.presentationLayer;
    return presentation ? (CGFloat)presentation.opacity : (CGFloat)badge.layer.opacity;
}

static void FIZZBadgePopView(UIView *badge, NSTimeInterval duration, NSTimeInterval beginTime) {
    // A badge that already carries a scale keeps it as its starting point, so a
    // second bubble grows on from the first instead of snapping back to 1.
    CATransform3D transform = FIZZBadgePresentationTransform(badge);
    CGFloat baseScale = sqrt(transform.m11 * transform.m11 + transform.m12 * transform.m12);
    if (!(baseScale > 0.01)) {
        baseScale = 1.0;
    }
    CGFloat startOpacity = fmin(fmax(FIZZBadgePresentationOpacity(badge), 0.0), 1.0);

    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @(baseScale);
    grow.toValue = @(baseScale * FIZZBadgePopScale);
    grow.duration = duration;
    grow.beginTime = beginTime;
    grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    grow.fillMode = kCAFillModeForwards;
    grow.removedOnCompletion = NO;
    [badge.layer addAnimation:grow forKey:FIZZBadgePopScaleKey];

    // The fade runs as an even ramp from wherever the badge is to nothing, so the
    // bubble is seen growing all the way out instead of holding and then going.
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(startOpacity);
    fade.toValue = @0.0;
    fade.duration = duration;
    fade.beginTime = beginTime;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    fade.fillMode = kCAFillModeForwards;
    fade.removedOnCompletion = NO;
    [badge.layer addAnimation:fade forKey:FIZZBadgePopKey];
}

static NSUInteger FIZZBadgePopTree(UIView *view, Class badgeClass, NSTimeInterval duration,
                                  NSTimeInterval beginTime) {
    if (!view) {
        return 0;
    }
    NSUInteger popped = 0;
    if ([view isKindOfClass:badgeClass] && view.window && !view.hidden) {
        // Same duration and delay as the icon's own keyframe animation, so the
        // last bubble is gone as the icon comes to rest.
        FIZZBadgePopView(view, duration, beginTime);
        [gPoppingBadgeViews addObject:view];
        popped++;
    }
    for (UIView *child in view.subviews) {
        popped += FIZZBadgePopTree(child, badgeClass, duration, beginTime);
    }
    return popped;
}

void FIZZBadgePopWithRipple(UIView *iconView, NSTimeInterval duration, NSTimeInterval delay) {
    Class badgeClass = objc_getClass("SBIconBadgeView");
    if (!iconView || !badgeClass || duration <= 0) {
        return;
    }
    if (!gPoppingBadgeViews) {
        gPoppingBadgeViews = [NSHashTable weakObjectsHashTable];
    }
    // Half the icon's beat, so the bubble is seen disappearing instead of
    // lingering for the whole return leg.
    FIZZBadgePopTree(iconView, badgeClass, duration * FIZZBadgePopBeatShare,
                    CACurrentMediaTime() + delay);
}

// Runs once the ripple is over: a badge whose icon is still badged would pop back
// in when the animation is dropped, so the view stays hidden instead. The reuse
// hooks above lift the flag again as soon as SpringBoard reconfigures the view.
static void FIZZBadgeSettlePopped(void) {
    for (UIView *view in gPoppingBadgeViews.allObjects) {
        FIZZBadgeResetView(view);
        if (view.window && !view.hidden) {
            view.hidden = YES;
        }
    }
    [gPoppingBadgeViews removeAllObjects];
}

#pragma mark - Data

static SBIconModel *FIZZBadgeIconModel(void) {
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
static void FIZZBadgeClearIcon(SBIcon *icon) {
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

static NSString *FIZZBadgeBundleIdentifier(SBIcon *icon) {
    SBApplication *application = [icon respondsToSelector:@selector(application)] ? icon.application : nil;
    return [application respondsToSelector:@selector(bundleIdentifier)] ? application.bundleIdentifier : nil;
}

BOOL FIZZBadgeHasBadges(void) {
    SBIconModel *iconModel = FIZZBadgeIconModel();
    NSArray *leafIcons = [iconModel respondsToSelector:@selector(leafIcons)] ? iconModel.leafIcons : nil;
    for (SBIcon *icon in leafIcons) {
        if (![icon respondsToSelector:@selector(badgeNumberOrString)]) {
            continue;
        }
        id badge = icon.badgeNumberOrString;
        // A zero is what SpringBoard stores for "no badge"; only a positive
        // count would be wiped by the clear.
        if (badge && FIZZBadgeIntegerValue(badge) > 0) {
            return YES;
        }
    }
    return NO;
}

void FIZZBadgeClearAll(void) {
    if (!FIZZFeatureEnabled()) {
        return;
    }
    FIZZBadgeInstallWatchers();

    SBIconModel *iconModel = FIZZBadgeIconModel();
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
            if (FIZZBadgeSuppressionEnabled()) {
                FIZZBadgeRecordBaseline(FIZZBadgeBundleIdentifier(icon), badge);
            }
            FIZZBadgeClearIcon(icon);
        }
        gInsideSelfClear = NO;
    }

    // The ripple has settled by now: every popped view has finished its beat. Drop
    // the animations and keep the views hidden; icons whose data really went away
    // have had their badge views removed already.
    FIZZBadgeSettlePopped();
}
