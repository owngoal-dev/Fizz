//
//  FIZZHaptics.m
//  Fizz
//
//  Two system impacts and nothing else, one per kind of spread. Both fire at the
//  instant the icons settle back onto their home positions, so the spread is
//  silent while the fingers are out and answers once it is over.
//
//  The difference between them is the style: a spread that cleared badges lands
//  with a heavier impact than one that only rippled the icons. UIKit's feedback
//  generators are the system taps; each is created once, kept alive and prepared
//  again after every play, so the next gesture finds it ready.
//

#import "FIZZHaptics.h"

#import "FIZZPreferences.h"

#import <UIKit/UIKit.h>

static UIImpactFeedbackGenerator *gEmptyGenerator = nil;
static UIImpactFeedbackGenerator *gClearedGenerator = nil;

// The generators belong to the main queue, like every other UIKit object, and
// are only ever reached from there.
static UIImpactFeedbackGenerator *FIZZHapticsGenerator(FIZZHapticSettleKind kind) {
    BOOL cleared = (kind == FIZZHapticSettleKindCleared);
    UIImpactFeedbackGenerator *generator = cleared ? gClearedGenerator : gEmptyGenerator;
    if (!generator) {
        // Light is a short, crisp click; heavy is a solid thump that is clearly a
        // different thing in the hand, which is what a burst of badges deserves.
        UIImpactFeedbackStyle style = cleared ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleLight;
        generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
        if (cleared) {
            gClearedGenerator = generator;
        } else {
            gEmptyGenerator = generator;
        }
    }
    return generator;
}

BOOL FIZZHapticsPlaySettle(FIZZHapticSettleKind kind) {
    if (!FIZZHapticsEnabled()) {
        return NO;
    }
    UIImpactFeedbackGenerator *generator = FIZZHapticsGenerator(kind);
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
    // Which kind comes next is not known before the release, so both are warmed.
    [FIZZHapticsGenerator(FIZZHapticSettleKindEmpty) prepare];
    [FIZZHapticsGenerator(FIZZHapticSettleKindCleared) prepare];
}
