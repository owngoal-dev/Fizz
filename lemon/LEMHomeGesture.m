//
//  LEMHomeGesture.m
//  Lemon
//
//  The home screen side of Lemon: a pinch recognizer on the home screen icon
//  scroll view, the pan arbitration that keeps a two-finger spread from dragging
//  the page, and the ripple and badge clearing the spread triggers.
//

#import "LEMBadgeClearer.h"
#import "LEMHaptics.h"
#import "LEMIconRipple.h"
#import "LEMHook.h"
#import "LEMLog.h"
#import "LEMPreferences.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "dev"
#endif

// The clear runs just after the last icon and badge have come to rest.
static const NSTimeInterval LEMClearMargin = 0.02;
// A pan that was already tracking a first touch is disabled for the duration of
// the pinch; this bounds how long it can stay disabled if the pinch never ends.
static const NSTimeInterval LEMPanWatchdogInterval = 3.0;

static NSHashTable<UIScrollView *> *gAttachedScrollViews = nil;
static NSMapTable<UIScrollView *, UIPinchGestureRecognizer *> *gPinchRecognizers = nil;
static NSHashTable<UIPanGestureRecognizer *> *gSuppressedPans = nil;

#pragma mark - Pan arbitration

// The home screen scroll view pans with one or two fingers by default, so a
// two-finger spread also drags the icon page. Limiting the pan to a single
// touch keeps every two-finger contact out of it.
static void LEMConfigureScrollPan(UIPanGestureRecognizer *pan) {
    if (pan && pan.maximumNumberOfTouches != 1) {
        pan.maximumNumberOfTouches = 1;
    }
}

static void LEMRestoreScrollPan(UIPinchGestureRecognizer *recognizer) {
    UIView *view = recognizer.view;
    if (![view isKindOfClass:[UIScrollView class]]) {
        return;
    }
    UIPanGestureRecognizer *pan = ((UIScrollView *)view).panGestureRecognizer;
    if (!pan || !gSuppressedPans || ![gSuppressedPans containsObject:pan]) {
        return;
    }
    [gSuppressedPans removeObject:pan];
    pan.enabled = YES;
}

// A pan that started before the second finger landed keeps tracking its first
// touch. Disabling the recognizer cancels it and stops the deceleration; it is
// re-enabled when the pinch ends.
static void LEMSuppressScrollPan(UIPinchGestureRecognizer *recognizer) {
    UIView *view = recognizer.view;
    if (![view isKindOfClass:[UIScrollView class]]) {
        return;
    }
    UIPanGestureRecognizer *pan = ((UIScrollView *)view).panGestureRecognizer;
    if (!pan || !pan.enabled) {
        return;
    }
    if (!gSuppressedPans) {
        gSuppressedPans = [NSHashTable weakObjectsHashTable];
    }
    if ([gSuppressedPans containsObject:pan]) {
        return;
    }
    pan.enabled = NO;
    [gSuppressedPans addObject:pan];

    __weak UIPinchGestureRecognizer *weakRecognizer = recognizer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LEMPanWatchdogInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIPinchGestureRecognizer *strongRecognizer = weakRecognizer;
                       UIGestureRecognizerState state = strongRecognizer.state;
                       if (state == UIGestureRecognizerStatePossible ||
                           state == UIGestureRecognizerStateFailed) {
                           LEMRestoreScrollPan(strongRecognizer);
                       }
                   });
}

#pragma mark - Spread

// The spread ripples the icons outwards from the screen center and back, and the
// badges of those icons fade with the same beat. Clearing the badge data is left
// until the wave has settled, because SpringBoard drops the badge views as soon
// as the value goes.
static void LEMRunSpread(UIPinchGestureRecognizer *recognizer) {
    // The haptic variant is chosen before the ripple starts: badges on the home
    // screen mean the clear is queued, and that variant ends with the cut and
    // the low thud for the wipe.
    BOOL clearingBadges = LEMFeatureEnabled() && LEMBadgeHasBadges();
    LEMHapticsPlaySpread(clearingBadges);
    NSTimeInterval settle = LEMIconRippleRun(recognizer.view);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((settle + LEMClearMargin) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       LEMBadgeClearAll();
                   });
}

@interface LEMGestureObserver : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedObserver;
- (UIPinchGestureRecognizer *)installPinchRecognizerOnScrollView:(UIScrollView *)scrollView;
- (void)handlePinch:(UIPinchGestureRecognizer *)recognizer;
@end

@implementation LEMGestureObserver

+ (instancetype)sharedObserver {
    static LEMGestureObserver *observer = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        observer = [[LEMGestureObserver alloc] init];
    });
    return observer;
}

- (UIPinchGestureRecognizer *)installPinchRecognizerOnScrollView:(UIScrollView *)scrollView {
    UIPinchGestureRecognizer *recognizer =
        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
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
    if (!LEMFeatureEnabled()) {
        return;
    }
    UIGestureRecognizerState state = recognizer.state;
    if (state == UIGestureRecognizerStateBegan) {
        LEMSuppressScrollPan(recognizer);
        if (recognizer.scale > 1.0) {
            LEMRunSpread(recognizer);
        }
    } else if (state == UIGestureRecognizerStateEnded ||
               state == UIGestureRecognizerStateCancelled) {
        LEMRestoreScrollPan(recognizer);
    }
}

@end

#pragma mark - Scroll view attachment

static void LEMAttachToScrollView(UIScrollView *scrollView);

static void LEMEnumerateViews(UIView *view, NSUInteger depth,
                              void (^block)(UIView *candidate, NSUInteger depth)) {
    if (!view || depth > 8) {
        return;
    }
    block(view, depth);
    for (UIView *child in view.subviews) {
        LEMEnumerateViews(child, depth + 1, block);
    }
}

static void LEMAttachToExistingScrollViews(void) {
    if (!gAttachedScrollViews) {
        gAttachedScrollViews = [NSHashTable weakObjectsHashTable];
    }
    NSArray<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            LEMEnumerateViews(window, 0, ^(UIView *candidate, NSUInteger depth) {
                if ([candidate isKindOfClass:[UIScrollView class]] &&
                    [NSStringFromClass([candidate class]) containsString:@"SBIconScrollView"]) {
                    LEMAttachToScrollView((UIScrollView *)candidate);
                }
            });
        }
    }
}

static void LEMAttachToScrollView(UIScrollView *scrollView) {
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
        [[LEMGestureObserver sharedObserver] installPinchRecognizerOnScrollView:scrollView];
    [gPinchRecognizers setObject:recognizer forKey:scrollView];
    [gAttachedScrollViews addObject:scrollView];
    LEMConfigureScrollPan(scrollView.panGestureRecognizer);
}

#pragma mark - Hooks

static void (*LEMOriginalRootFolderViewWillAppear)(id, SEL, id) = NULL;
static id (*LEMOriginalScrollViewInitWithFrame)(id, SEL, CGRect) = NULL;
static void (*LEMOriginalScrollViewLayoutSubviews)(id, SEL) = NULL;

static void LEMHookedRootFolderViewWillAppear(id self, SEL _cmd, id controller) {
    if (LEMOriginalRootFolderViewWillAppear) {
        LEMOriginalRootFolderViewWillAppear(self, _cmd, controller);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        LEMAttachToExistingScrollViews();
        LEMHapticsPrewarm();
    });
}

static id LEMHookedScrollViewInitWithFrame(id self, SEL _cmd, CGRect frame) {
    id scrollView = nil;
    if (LEMOriginalScrollViewInitWithFrame) {
        scrollView = LEMOriginalScrollViewInitWithFrame(self, _cmd, frame);
    }
    __weak id weakScrollView = scrollView;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongScrollView = weakScrollView;
        if ([strongScrollView isKindOfClass:[UIScrollView class]]) {
            LEMAttachToScrollView((UIScrollView *)strongScrollView);
        }
    });
    return scrollView;
}

static void LEMHookedScrollViewLayoutSubviews(id self, SEL _cmd) {
    if (LEMOriginalScrollViewLayoutSubviews) {
        LEMOriginalScrollViewLayoutSubviews(self, _cmd);
    }
    if (![self isKindOfClass:[UIScrollView class]]) {
        return;
    }
    UIScrollView *scrollView = (UIScrollView *)self;
    if (!gAttachedScrollViews || ![gAttachedScrollViews containsObject:scrollView]) {
        return;
    }
    LEMConfigureScrollPan(scrollView.panGestureRecognizer);
    UIPinchGestureRecognizer *recognizer = [gPinchRecognizers objectForKey:scrollView];
    if (recognizer && ![scrollView.gestureRecognizers containsObject:recognizer]) {
        [scrollView addGestureRecognizer:recognizer];
    }
}

static const NSUInteger LEMGestureHookMaskComplete = 7;
static NSUInteger gGestureHookMask = 0;

static void LEMInstallHooks(void) {
    Class iconManagerClass = objc_getClass("SBHIconManager");
    Class iconScrollViewClass = objc_getClass("SBIconScrollView");

    if (iconManagerClass && !(gGestureHookMask & 1) &&
        LEMInstallHook(iconManagerClass, @selector(rootFolderControllerViewWillAppear:),
                       (IMP)LEMHookedRootFolderViewWillAppear, (IMP *)&LEMOriginalRootFolderViewWillAppear)) {
        gGestureHookMask |= 1;
    }
    if (iconScrollViewClass && !(gGestureHookMask & 2) &&
        LEMClassOwnsSelector(iconScrollViewClass, @selector(initWithFrame:)) &&
        LEMInstallHook(iconScrollViewClass, @selector(initWithFrame:), (IMP)LEMHookedScrollViewInitWithFrame,
                       (IMP *)&LEMOriginalScrollViewInitWithFrame)) {
        gGestureHookMask |= 2;
    }
    // Hooking a superclass layoutSubviews would change every scroll view, so the
    // layout pass is only watched when the home screen scroll view owns it.
    if (iconScrollViewClass && !(gGestureHookMask & 4) &&
        LEMClassOwnsSelector(iconScrollViewClass, @selector(layoutSubviews)) &&
        LEMInstallHook(iconScrollViewClass, @selector(layoutSubviews), (IMP)LEMHookedScrollViewLayoutSubviews,
                       (IMP *)&LEMOriginalScrollViewLayoutSubviews)) {
        gGestureHookMask |= 4;
    }

    if (gGestureHookMask == LEMGestureHookMaskComplete) {
        return;
    }
    static NSUInteger attempts = 0;
    if (attempts++ >= 100) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       LEMInstallHooks();
                   });
}

__attribute__((constructor)) static void LEMInitialize(void) {
    LEMLogLoadedMarker(APELIN_BUILD_ID);

    // The badge hooks have to be in place before SpringBoard builds its icon
    // model and restores the badges, which happens long before the first main
    // queue block runs. Installing them right here, on the loading thread, is
    // what lets the write gate drop a cleared count during launch.
    LEMBadgeInstallWatchers();

    dispatch_async(dispatch_get_main_queue(), ^{
        LEMInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           LEMAttachToExistingScrollViews();
                       });
    });
}
