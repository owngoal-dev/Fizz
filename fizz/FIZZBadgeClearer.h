//
//  FIZZBadgeClearer.h
//  Fizz
//
//  Clears every application badge on the home screen: the badge value the
//  application object carries and the badge view that draws it.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Pops the badges of one icon in step with its ripple beat: the same delay the
/// icon itself got, over half of its beat, so each badge grows while it fades out
/// and the last one is long gone as its icon comes to rest. Called by the ripple
/// for every icon it animates.
void FIZZBadgePopWithRipple(UIView *iconView, NSTimeInterval duration, NSTimeInterval delay);

/// Clears the badge value of every leaf icon and settles the views popped above.
/// Must be called on the main queue, once the ripple has finished, so the pop is
/// seen to its end instead of being cut short by the reload it triggers.
void FIZZBadgeClearAll(void);

/// YES when at least one leaf icon carries a badge right now, so the next clear
/// has something to wipe. Read by the spread to know whether any badge will
/// fade out, and so whether the tap is due.
BOOL FIZZBadgeHasBadges(void);

/// The share of its icon's beat a badge takes to fade out. The bubbles are gone
/// well before their icons have finished returning, which is what the tap marks.
extern const NSTimeInterval FIZZBadgePopBeatShare;

/// Installs the badge hooks: the reuse resets of the badge view, the gate that
/// drops a badge count Fizz has already cleared, and the observation of every
/// other badge write. Safe to call more than once and from the loading thread;
/// call it before SpringBoard restores its badges.
void FIZZBadgeInstallWatchers(void);

NS_ASSUME_NONNULL_END
