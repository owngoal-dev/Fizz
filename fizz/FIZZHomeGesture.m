//
//  FIZZHomeGesture.m
//  Fizz
//
//  The home screen side of Fizz: a pinch recognizer on the home screen icon
//  scroll view that follows the fingers before UIKit's own threshold is
//  reached, the pan arbitration that keeps a two-finger spread from dragging
//  the page, and the ripple and badge clearing the spread triggers.
//

#import "FIZZBadgeClearer.h"
#import "FIZZHaptics.h"
#import "FIZZIconRipple.h"
#import "FIZZHook.h"
#import "FIZZLog.h"
#import "FIZZPreferences.h"

#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>

#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "dev"
#endif

// The clear runs just after the last icon and badge have come to rest.
static const NSTimeInterval FIZZClearMargin = 0.02;
// A pan that was already tracking a first touch is disabled for the duration of
// the pinch; this bounds how long it can stay disabled if the pinch never ends.
static const NSTimeInterval FIZZPanWatchdogInterval = 3.0;

static NSHashTable<UIScrollView *> *gAttachedScrollViews = nil;
static NSMapTable<UIScrollView *, UIPinchGestureRecognizer *> *gPinchRecognizers = nil;
static NSHashTable<UIPanGestureRecognizer *> *gSuppressedPans = nil;

#pragma mark - Pan arbitration

// The home screen answers a two-finger contact in more than one place: the icon
// scroll view pans with it, and the views above it carry the pull-down that
// opens the search. Every pan up that chain is limited to a single touch, so a
// spread cannot start any of them while each of them keeps working with one
// finger exactly as before.
static void FIZZLimitToSingleTouch(UIGestureRecognizer *recognizer) {
    if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return;
    }
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)recognizer;
    // A pan that needs several touches to begin is left as it is: lowering its
    // maximum below its minimum is refused, and it cannot be the one-finger
    // pull-down this is aimed at.
    if (pan.minimumNumberOfTouches > 1 || pan.maximumNumberOfTouches == 1) {
        return;
    }
    pan.maximumNumberOfTouches = 1;
}

static void FIZZConfigureScrollPan(UIView *view) {
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth < 12; depth++) {
        for (UIGestureRecognizer *recognizer in current.gestureRecognizers) {
            FIZZLimitToSingleTouch(recognizer);
        }
        current = current.superview;
    }
}

static void FIZZRestoreScrollPan(UIPinchGestureRecognizer *recognizer) {
    if (!gSuppressedPans) {
        return;
    }
    for (UIPanGestureRecognizer *pan in gSuppressedPans.allObjects) {
        pan.enabled = YES;
    }
    [gSuppressedPans removeAllObjects];
}

// A pan that started before the second finger landed keeps tracking its first
// touch, and while it does the page moves and the search slides in. Every pan on
// the chain is therefore cancelled as soon as the spread begins, and brought
// back when it ends; disabling a recognizer cancels it and stops the
// deceleration.
static void FIZZSuppressScrollPan(UIPinchGestureRecognizer *recognizer) {
    UIView *view = recognizer.view;
    if (!view) {
        return;
    }
    if (!gSuppressedPans) {
        gSuppressedPans = [NSHashTable weakObjectsHashTable];
    }
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth < 12; depth++) {
        for (UIGestureRecognizer *recognizer in current.gestureRecognizers) {
            if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]] || !recognizer.enabled) {
                continue;
            }
            recognizer.enabled = NO;
            [gSuppressedPans addObject:(UIPanGestureRecognizer *)recognizer];
        }
        current = current.superview;
    }
    if (gSuppressedPans.count == 0) {
        return;
    }

    __weak UIPinchGestureRecognizer *weakRecognizer = recognizer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FIZZPanWatchdogInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIPinchGestureRecognizer *strongRecognizer = weakRecognizer;
                       UIGestureRecognizerState state = strongRecognizer.state;
                       if (state == UIGestureRecognizerStatePossible ||
                           state == UIGestureRecognizerStateFailed) {
                           FIZZRestoreScrollPan(strongRecognizer);
                       }
                   });
}

#pragma mark - Spread

// The spread ripples the icons outwards from the screen center and back, and the
// badges of those icons pop with the same beat. Clearing the badge data is left
// until the wave has settled, because SpringBoard drops the badge views as soon
// as the value goes.
static NSUInteger gSpreadGeneration = 0;

static void FIZZRunSpread(UIView *hostView) {
    // Badges on the home screen mean bubbles will burst, which is what tells the
    // one impact Fizz plays apart from the one a plain spread gets.
    BOOL clearingBadges = FIZZFeatureEnabled() && FIZZBadgeHasBadges();
    NSUInteger generation = ++gSpreadGeneration;
    FIZZRippleTiming timing = FIZZIconRippleRun(hostView);
    if (timing.touchdown > 0) {
        // The impact marks the instant the icons are back on their places, which
        // is where they read as landed: on the return leg each icon crosses its
        // own position well before its overshoot tail runs out, so the wave's
        // settle time would be late by that tail. A spread that took over fires
        // its own impact.
        FIZZHapticSettleKind kind = clearingBadges ? FIZZHapticSettleKindCleared
                                                   : FIZZHapticSettleKindEmpty;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timing.touchdown * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (generation != gSpreadGeneration) {
                               return;
                           }
                           FIZZHapticsPlaySettle(kind);
                       });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timing.settle + FIZZClearMargin) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       // A newer spread has taken over since: it clears once its
                       // own wave has settled, so a spread that follows another
                       // one closely is never cut short by this clear.
                       if (generation != gSpreadGeneration) {
                           return;
                       }
                       FIZZBadgeClearAll();
                   });
}

#pragma mark - Finger following

// The pinch recognizer only reports Began once UIKit's own threshold is crossed,
// which is well after the fingers have started to open, so everything before
// that used to be lost and the wave only began once the spread was already
// under way. The touches are measured directly instead: from the second finger
// landing, the span between the two fingers carries the icons outwards.
//
// Nothing else happens while the fingers are still down. The wave, the badges
// and the clear all belong to the release: a spread that is let go with the
// span at or past the trigger distance gets the out-and-back wave and the
// clear, and one that is let go short of it only returns the icons.
static const CGFloat FIZZSpreadTriggerSpan = 40.0;

static BOOL gSpreadFollowing = NO;
static CGFloat gSpreadBaseSpan = 0;
static CGFloat gSpreadSpan = 0;

static NSArray<UITouch *> *FIZZSpreadLiveTouches(UIPinchGestureRecognizer *recognizer, UIEvent *event) {
    NSMutableArray<UITouch *> *live = [NSMutableArray array];
    if (!event) {
        return live;
    }
    // The recognizer's own touches: they are the ones it accepted, so a third
    // finger that it ignored cannot be measured by mistake.
    for (UITouch *touch in [event touchesForGestureRecognizer:recognizer]) {
        if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
            continue;
        }
        [live addObject:touch];
    }
    return live;
}

static CGFloat FIZZSpreadSpan(UIPinchGestureRecognizer *recognizer, NSArray<UITouch *> *touches) {
    UIView *view = recognizer.view;
    if (touches.count < 2 || !view) {
        return 0;
    }
    CGPoint first = [touches[0] locationInView:view];
    CGPoint second = [touches[1] locationInView:view];
    return hypot(first.x - second.x, first.y - second.y);
}

// Where the fingers were when they left the screen. The touch that ended is
// still part of the set during touchesEnded, so the position it was lifted at is
// measured instead of the last one from before the lift.
static CGFloat FIZZSpreadReleaseSpan(UIPinchGestureRecognizer *recognizer, UIEvent *event) {
    UIView *view = recognizer.view;
    if (!view || !event) {
        return 0;
    }
    NSMutableArray<UITouch *> *touches = [NSMutableArray array];
    for (UITouch *touch in [event touchesForGestureRecognizer:recognizer]) {
        if (touch.phase == UITouchPhaseCancelled) {
            continue;
        }
        [touches addObject:touch];
    }
    return FIZZSpreadSpan(recognizer, touches);
}

// The gesture is over: either the fingers were let go with the span at the
// trigger distance, which starts the wave and the clear, or they let go short of
// it and the icons only go back where they came from. A cancelled gesture never
// counts, however far it got.
static void FIZZSpreadFinish(UIPinchGestureRecognizer *recognizer, BOOL released) {
    if (!gSpreadFollowing) {
        FIZZRestoreScrollPan(recognizer);
        return;
    }
    gSpreadFollowing = NO;

    BOOL reached = NO;
    if (released) {
        // A gesture whose touches were never measured has no span to compare;
        // the recognizer's own scale is then the only evidence there is.
        reached = gSpreadSpan > 0 ? (gSpreadSpan - gSpreadBaseSpan) >= FIZZSpreadTriggerSpan
                                  : recognizer.scale > 1.02;
    }
    gSpreadBaseSpan = 0;
    gSpreadSpan = 0;
    FIZZRestoreScrollPan(recognizer);

    if (reached && recognizer.view && FIZZFeatureEnabled()) {
        FIZZRunSpread(recognizer.view);
        return;
    }
    FIZZIconRippleEndFollow(YES);
}

static void FIZZSpreadTrackTouches(UIPinchGestureRecognizer *recognizer, UIEvent *event) {
    if (!FIZZFeatureEnabled()) {
        return;
    }
    UIView *hostView = recognizer.view;
    if (!hostView) {
        return;
    }
    NSArray<UITouch *> *touches = FIZZSpreadLiveTouches(recognizer, event);
    if (touches.count < 2) {
        FIZZSpreadFinish(recognizer, YES);
        return;
    }
    CGFloat span = FIZZSpreadSpan(recognizer, touches);
    if (!gSpreadFollowing) {
        gSpreadFollowing = YES;
        gSpreadBaseSpan = span;
        gSpreadSpan = span;
        FIZZSuppressScrollPan(recognizer);
        FIZZIconRippleBeginFollow(hostView);
        // The fingers are on the glass and the wave is at most a gesture away, so
        // this is the one place the taps are armed from.
        FIZZHapticsPrewarm();
        return;
    }
    // The icons keep following the fingers past the trigger distance, so a
    // spread the user holds open stays where they left it instead of stopping
    // partway; the wave picks that position up when the fingers come off.
    gSpreadSpan = span;
    FIZZIconRippleUpdateFollow((span - gSpreadBaseSpan) / FIZZSpreadTriggerSpan);
}

// Measures the fingers itself before UIKit's own pinch threshold is reached.
@interface FIZZSpreadPinchRecognizer : UIPinchGestureRecognizer
@end

@implementation FIZZSpreadPinchRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    FIZZSpreadTrackTouches(self, event);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // Measured before the pinch state machine runs, so a spread that already
    // crossed the trigger is not started a second time by the recognizer's own
    // Began.
    FIZZSpreadTrackTouches(self, event);
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // The position the fingers were lifted at decides whether the spread
    // counts, so it is measured before the recognizer's state machine can end
    // the gesture.
    CGFloat span = FIZZSpreadReleaseSpan(self, event);
    if (span > 0 && gSpreadFollowing) {
        gSpreadSpan = span;
    }
    [super touchesEnded:touches withEvent:event];
    FIZZSpreadTrackTouches(self, event);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    FIZZSpreadFinish(self, NO);
}

- (void)reset {
    [super reset];
    FIZZSpreadFinish(self, NO);
}

@end

@interface FIZZGestureObserver : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedObserver;
- (UIPinchGestureRecognizer *)installPinchRecognizerOnScrollView:(UIScrollView *)scrollView;
- (void)handlePinch:(UIPinchGestureRecognizer *)recognizer;
@end

@implementation FIZZGestureObserver

+ (instancetype)sharedObserver {
    static FIZZGestureObserver *observer = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        observer = [[FIZZGestureObserver alloc] init];
    });
    return observer;
}

- (UIPinchGestureRecognizer *)installPinchRecognizerOnScrollView:(UIScrollView *)scrollView {
    UIPinchGestureRecognizer *recognizer =
        [[FIZZSpreadPinchRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    recognizer.delegate = self;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    [scrollView addGestureRecognizer:recognizer];
    return recognizer;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handlePinch:(UIPinchGestureRecognizer *)recognizer {
    // The global switch leaves the recognizer installed, so turning it back on
    // takes effect on the next gesture without a respring.
    if (!FIZZFeatureEnabled()) {
        return;
    }
    UIGestureRecognizerState state = recognizer.state;
    if (state == UIGestureRecognizerStateBegan) {
        // The touches normally open the follow leg before this state is
        // reached; this keeps the pan out of the way when they did not, and the
        // release still decides whether the spread counts.
        if (!gSpreadFollowing) {
            gSpreadFollowing = YES;
            gSpreadBaseSpan = 0;
            gSpreadSpan = 0;
            FIZZSuppressScrollPan(recognizer);
        }
    } else if (state == UIGestureRecognizerStateEnded) {
        FIZZSpreadFinish(recognizer, YES);
    } else if (state == UIGestureRecognizerStateCancelled ||
               state == UIGestureRecognizerStateFailed) {
        FIZZSpreadFinish(recognizer, NO);
    }
}

@end

#pragma mark - Scroll view attachment

static void FIZZAttachToScrollView(UIScrollView *scrollView);

static void FIZZEnumerateViews(UIView *view, NSUInteger depth,
                              void (^block)(UIView *candidate, NSUInteger depth)) {
    if (!view || depth > 8) {
        return;
    }
    block(view, depth);
    for (UIView *child in view.subviews) {
        FIZZEnumerateViews(child, depth + 1, block);
    }
}

static void FIZZAttachToExistingScrollViews(void) {
    if (!gAttachedScrollViews) {
        gAttachedScrollViews = [NSHashTable weakObjectsHashTable];
    }
    NSArray<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            FIZZEnumerateViews(window, 0, ^(UIView *candidate, NSUInteger depth) {
                if ([candidate isKindOfClass:[UIScrollView class]] &&
                    [NSStringFromClass([candidate class]) containsString:@"SBIconScrollView"]) {
                    FIZZAttachToScrollView((UIScrollView *)candidate);
                }
            });
        }
    }
}

static void FIZZAttachToScrollView(UIScrollView *scrollView) {
    if (!scrollView) {
        return;
    }
    if (!gAttachedScrollViews) {
        gAttachedScrollViews = [NSHashTable weakObjectsHashTable];
    }
    if ([gAttachedScrollViews containsObject:scrollView]) {
        return;
    }
    if (!gPinchRecognizers) {
        gPinchRecognizers = [NSMapTable weakToStrongObjectsMapTable];
    }

    UIPinchGestureRecognizer *recognizer =
        [[FIZZGestureObserver sharedObserver] installPinchRecognizerOnScrollView:scrollView];
    [gPinchRecognizers setObject:recognizer forKey:scrollView];
    [gAttachedScrollViews addObject:scrollView];
    FIZZConfigureScrollPan(scrollView);
}

#pragma mark - Hooks

static void (*FIZZOriginalRootFolderViewWillAppear)(id, SEL, id) = NULL;
static id (*FIZZOriginalScrollViewInitWithFrame)(id, SEL, CGRect) = NULL;
static void (*FIZZOriginalScrollViewLayoutSubviews)(id, SEL) = NULL;

static void FIZZHookedRootFolderViewWillAppear(id self, SEL _cmd, id controller) {
    if (FIZZOriginalRootFolderViewWillAppear) {
        FIZZOriginalRootFolderViewWillAppear(self, _cmd, controller);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        FIZZAttachToExistingScrollViews();
    });
}

static id FIZZHookedScrollViewInitWithFrame(id self, SEL _cmd, CGRect frame) {
    id scrollView = nil;
    if (FIZZOriginalScrollViewInitWithFrame) {
        scrollView = FIZZOriginalScrollViewInitWithFrame(self, _cmd, frame);
    }
    __weak id weakScrollView = scrollView;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongScrollView = weakScrollView;
        if ([strongScrollView isKindOfClass:[UIScrollView class]]) {
            FIZZAttachToScrollView((UIScrollView *)strongScrollView);
        }
    });
    return scrollView;
}

static void FIZZHookedScrollViewLayoutSubviews(id self, SEL _cmd) {
    if (FIZZOriginalScrollViewLayoutSubviews) {
        FIZZOriginalScrollViewLayoutSubviews(self, _cmd);
    }
    if (![self isKindOfClass:[UIScrollView class]]) {
        return;
    }
    UIScrollView *scrollView = (UIScrollView *)self;
    if (!gAttachedScrollViews || ![gAttachedScrollViews containsObject:scrollView]) {
        return;
    }
    FIZZConfigureScrollPan(scrollView);
    UIPinchGestureRecognizer *recognizer = [gPinchRecognizers objectForKey:scrollView];
    if (recognizer && ![scrollView.gestureRecognizers containsObject:recognizer]) {
        [scrollView addGestureRecognizer:recognizer];
    }
}

static const NSUInteger FIZZGestureHookMaskComplete = 7;
static NSUInteger gGestureHookMask = 0;

static void FIZZInstallHooks(void) {
    Class iconManagerClass = objc_getClass("SBHIconManager");
    Class iconScrollViewClass = objc_getClass("SBIconScrollView");

    if (iconManagerClass && !(gGestureHookMask & 1) &&
        FIZZInstallHook(iconManagerClass, @selector(rootFolderControllerViewWillAppear:),
                       (IMP)FIZZHookedRootFolderViewWillAppear, (IMP *)&FIZZOriginalRootFolderViewWillAppear)) {
        gGestureHookMask |= 1;
    }
    if (iconScrollViewClass && !(gGestureHookMask & 2) &&
        FIZZClassOwnsSelector(iconScrollViewClass, @selector(initWithFrame:)) &&
        FIZZInstallHook(iconScrollViewClass, @selector(initWithFrame:), (IMP)FIZZHookedScrollViewInitWithFrame,
                       (IMP *)&FIZZOriginalScrollViewInitWithFrame)) {
        gGestureHookMask |= 2;
    }
    // Hooking a superclass layoutSubviews would change every scroll view, so the
    // layout pass is only watched when the home screen scroll view owns it.
    if (iconScrollViewClass && !(gGestureHookMask & 4) &&
        FIZZClassOwnsSelector(iconScrollViewClass, @selector(layoutSubviews)) &&
        FIZZInstallHook(iconScrollViewClass, @selector(layoutSubviews), (IMP)FIZZHookedScrollViewLayoutSubviews,
                       (IMP *)&FIZZOriginalScrollViewLayoutSubviews)) {
        gGestureHookMask |= 4;
    }

    if (gGestureHookMask == FIZZGestureHookMaskComplete) {
        return;
    }
    static NSUInteger attempts = 0;
    if (attempts++ >= 100) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       FIZZInstallHooks();
                   });
}

__attribute__((constructor)) static void FIZZInitialize(void) {
    FIZZLogLoadedMarker(APELIN_BUILD_ID);

    // The badge hooks have to be in place before SpringBoard builds its icon
    // model and restores the badges, which happens long before the first main
    // queue block runs. Installing them right here, on the loading thread, is
    // what lets the write gate drop a cleared count during launch.
    FIZZBadgeInstallWatchers();

    dispatch_async(dispatch_get_main_queue(), ^{
        FIZZInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           FIZZAttachToExistingScrollViews();
                       });
    });
}
