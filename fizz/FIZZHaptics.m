//
//  FIZZHaptics.m
//  Fizz
//
//  One system impact and nothing else. The tap is played at the instant the last
//  badge bubble is gone, so the spread itself carries no haptic at all.
//
//  UIKit's feedback generator is the system tap: it is created once, kept alive
//  and prepared again after every play, so the next gesture finds it ready.
//

#import "FIZZHaptics.h"

#import "FIZZPreferences.h"

#import <UIKit/UIKit.h>

static UIImpactFeedbackGenerator *gGenerator = nil;

// The generator belongs to the main queue, like every other UIKit object, and is
// only ever reached from there.
static UIImpactFeedbackGenerator *FIZZHapticsGenerator(void) {
    if (!gGenerator) {
        gGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }
    return gGenerator;
}

BOOL FIZZHapticsPlayTap(void) {
    if (!FIZZHapticsEnabled()) {
        return NO;
    }
    UIImpactFeedbackGenerator *generator = FIZZHapticsGenerator();
    [generator impactOccurred];
    // Armed again right away, so a second spread inside the tail of this one does
    // not wait for the hardware to wake up.
    [generator prepare];
    return YES;
}

void FIZZHapticsPrewarm(void) {
    if (!FIZZHapticsEnabled()) {
        return;
    }
    [FIZZHapticsGenerator() prepare];
}
