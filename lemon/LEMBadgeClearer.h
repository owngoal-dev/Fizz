//
//  LEMBadgeClearer.h
//  Lemon
//
//  Clears every application badge on the home screen: the badge value the
//  application object carries and the badge view that draws it.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Fades the badges of one icon in step with its ripple beat: the same duration,
/// the same delay the icon itself got, and fully faded by `outKeyTime`. Called by
/// the ripple for every icon it animates.
void LEMBadgeFadeWithRipple(UIView *iconView, NSTimeInterval duration, NSTimeInterval delay,
                            CGFloat outKeyTime);

/// Clears the badge value of every leaf icon and settles the views faded above.
/// Must be called on the main queue, once the ripple has finished, so the fade is
/// seen to its end instead of being cut short by the reload it triggers.
void LEMBadgeClearAll(void);

/// YES when at least one leaf icon carries a badge right now, so the next clear
/// has something to wipe. Read by the spread to pick the haptic variant.
BOOL LEMBadgeHasBadges(void);

/// Installs the badge hooks: the reuse resets of the badge view, the gate that
/// drops a badge count Lemon has already cleared, and the observation of every
/// other badge write. Safe to call more than once and from the loading thread;
/// call it before SpringBoard restores its badges.
void LEMBadgeInstallWatchers(void);

NS_ASSUME_NONNULL_END
