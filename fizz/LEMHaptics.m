//
//  LEMHaptics.m
//  Fizz
//
//  One system impact and nothing else. The tap is played at the instant the last
//  badge bubble is gone, so the spread itself carries no haptic at all.
//
//  UIKit's feedback generator is the system tap: it is created once, kept alive
//  and prepared again after every play, so the next gesture finds it ready.
//

#import "LEMHaptics.h"

#import "LEMPreferences.h"

#import <UIKit/UIKit.h>

static UIImpactFeedbackGenerator *gGenerator = nil;

// The generator belongs to the main queue, like every other UIKit object, and is
// only ever reached from there.
static UIImpactFeedbackGenerator *LEMHapticsGenerator(void) {
    if (!gGenerator) {
        gGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }
    return gGenerator;
}

BOOL LEMHapticsPlayTap(void) {
    if (!LEMHapticsEnabled()) {
        return NO;
    }
    UIImpactFeedbackGenerator *generator = LEMHapticsGenerator();
    [generator impactOccurred];
    // Armed again right away, so a second spread inside the tail of this one does
    // not wait for the hardware to wake up.
    [generator prepare];
    return YES;
}

void LEMHapticsPrewarm(void) {
    if (!LEMHapticsEnabled()) {
        return;
    }
    [LEMHapticsGenerator() prepare];
}
