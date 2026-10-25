//
//  FIZZHaptics.h
//  Fizz
//
//  One system impact at the instant the icons land back in place. What the
//  spread did on its way out picks which impact: a plain spread gets a light
//  tap, a spread whose badges burst gets a heavier one, so the two read apart in
//  the hand.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FIZZHapticSettleKind) {
    /// A spread with no badges to clear: one soft tap as the icons land.
    FIZZHapticSettleKindEmpty = 0,
    /// A spread whose badges popped away: a rigid, crisper tap at the same instant.
    FIZZHapticSettleKindCleared = 1,
};

/// Plays the impact that marks the icons coming to rest. Call on the main queue.
/// Returns NO when the haptics switch is off.
BOOL FIZZHapticsPlaySettle(FIZZHapticSettleKind kind);

/// Arms the feedback generators when a spread gesture starts, so the impact does
/// not pay the warm-up delay at the end of the wave. Safe to call more than once.
void FIZZHapticsPrewarm(void);

NS_ASSUME_NONNULL_END
