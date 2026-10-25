//
//  LEMBadgeClearer.h
//  Lemon
//
//  Clears every application badge on the home screen: the badge value the
//  application object carries and the badge view that draws it.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Pops the badges of one icon in step with its ripple beat: the same duration
/// and the same delay the icon itself got, so each badge puffs up like a bubble
/// and bursts as its icon comes to rest. Called by the ripple for every icon it
/// animates.
void LEMBadgePopWithRipple(UIView *iconView, NSTimeInterval duration, NSTimeInterval delay);

/// Clears the badge value of every leaf icon and settles the views popped above.
/// Must be called on the main queue, once the ripple has finished, so the pop is
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
