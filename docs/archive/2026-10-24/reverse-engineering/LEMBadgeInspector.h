//
//  LEMBadgeInspector.h
//  Lemon
//
//  One-shot runtime dump of the SpringBoard badge machinery, used to pick the
//  right selectors before the badge clearing is implemented.
//

#import <Foundation/Foundation.h>

/// Logs the badge related classes, selectors, properties and ivars that are
/// present in the host process. Call on the main queue.
void LEMBadgeDumpRuntime(void);

/// Logs every SpringBoard selector whose name mentions a badge, plus the icon
/// view tree of the home screen with the badge state of each icon. Call on the
/// main queue, after the home screen exists.
void LEMBadgeDumpSelectors(void);
void LEMBadgeDumpIconTree(void);

/// Logs the badge value each leaf icon currently carries and what its
/// application object reports. Call on the main queue.
void LEMBadgeDumpState(void);

/// Logs the LaunchServices side of the badge: which classes in the
/// LaunchServices image have badge selectors, and what the application proxy
/// and the application workspace expose. A badge that comes back after an app
/// relaunches is kept somewhere outside SpringBoard's own objects, so this is
/// where its data source has to be found. Call on the main queue.
void LEMBadgeDumpLaunchServices(void);

/// Writes the icon state SpringBoard would archive to /var/log/lemon/iconstate.xml,
/// so the caller can see whether the badge is part of the persisted state. Call on
/// the main queue.
void LEMBadgeDumpIconStateArchive(void);
