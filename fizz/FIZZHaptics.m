//
//  FIZZHaptics.m
//  Fizz
//
//  Two system impacts and nothing else, one per kind of spread. Both fire at the
//  instant the icons settle back onto their home positions, so the spread is
//  silent while the fingers are out and answers once it is over.
//
//  The difference between them is the style: a spread that cleared badges lands
//  with a hard, crisp click, and one that only rippled the icons with a soft tap.
//  UIKit's feedback generators are the system taps; each is created once, kept
//  alive, and armed when a spread gesture starts, which is the only prewarming
//  Fizz does.
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
        // Rigid is a hard, crisp click; soft is a quiet dull tap. A burst of
        // badges gets the click, a spread that only moved the icons the tap.
        UIImpactFeedbackStyle style = cleared ? UIImpactFeedbackStyleRigid : UIImpactFeedbackStyleSoft;
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
    [FIZZHapticsGenerator(kind) impactOccurred];
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
