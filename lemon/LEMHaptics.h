//
//  LEMHaptics.h
//  Lemon
//
//  The haptic side of the spread. The pattern itself is an AHAP file that lives
//  next to the dylib, so the rhythm can be edited without touching the code.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plays the spread pattern. Returns NO when the haptics switch is off, the
/// device has no haptics hardware, or the pattern could not be played.
BOOL LEMHapticsPlaySpread(void);

/// Loads the pattern and starts the engine ahead of the first spread. Called
/// when the home screen appears; safe to call more than once.
void LEMHapticsPrewarm(void);

NS_ASSUME_NONNULL_END
