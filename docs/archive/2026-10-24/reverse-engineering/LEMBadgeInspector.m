//
//  LEMBadgeInspector.m
//  Lemon
//
//  Dumps what the running SpringBoard knows about badges: which classes carry
//  "Badge" in their name, which selectors mention a badge, and how the badge is
//  hosted inside an icon view. The dump drives the implementation of badge
//  clearing, so every line is a plain list the log can be grepped for.
//

#import "LEMBadgeInspector.h"

#import "LEMLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

static BOOL LEMNameMatches(NSString *name, NSString *filter) {
    if (filter.length == 0) {
        return YES;
    }
    return [name rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *LEMMethodList(Class cls, BOOL classMethods, NSString *filter) {
    Class target = classMethods ? object_getClass((id)cls) : cls;
    if (!target) {
        return @"(none)";
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        if (LEMNameMatches(name, filter)) {
            [names addObject:name];
        }
    }
    if (methods) {
        free(methods);
    }
    if (names.count == 0) {
        return @"(none)";
    }
    [names sortUsingSelector:@selector(compare:)];
    return [names componentsJoinedByString:@", "];
}

static NSString *LEMPropertyList(Class cls, NSString *filter) {
    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = [NSString stringWithUTF8String:property_getName(properties[index])];
        if (LEMNameMatches(name, filter)) {
            [names addObject:name];
        }
    }
    if (properties) {
        free(properties);
    }
    if (names.count == 0) {
        return @"(none)";
    }
    [names sortUsingSelector:@selector(compare:)];
    return [names componentsJoinedByString:@", "];
}

static NSString *LEMIvarList(Class cls, NSString *filter) {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[index])];
        if (LEMNameMatches(name, filter)) {
            [names addObject:name];
        }
    }
    if (ivars) {
        free(ivars);
    }
    if (names.count == 0) {
        return @"(none)";
    }
    [names sortUsingSelector:@selector(compare:)];
    return [names componentsJoinedByString:@", "];
}

static NSString *LEMSuperclasses(Class cls) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    Class current = class_getSuperclass(cls);
    while (current && names.count < 6) {
        [names addObject:NSStringFromClass(current)];
        current = class_getSuperclass(current);
    }
    return [names componentsJoinedByString:@" < "];
}

static void LEMDumpClass(Class cls, NSString *filter) {
    if (!cls) {
        LEMLog(@"badge-parser missing");
        return;
    }
    LEMLog(@"badge-parser class=%@ super=%@", NSStringFromClass(cls), LEMSuperclasses(cls));
    LEMLog(@"badge-parser   instance[%@]: %@", filter ?: @"all", LEMMethodList(cls, NO, filter));
    LEMLog(@"badge-parser   class[%@]: %@", filter ?: @"all", LEMMethodList(cls, YES, filter));
    LEMLog(@"badge-parser   properties[%@]: %@", filter ?: @"all", LEMPropertyList(cls, filter));
    LEMLog(@"badge-parser   ivars[%@]: %@", filter ?: @"all", LEMIvarList(cls, filter));
}

void LEMBadgeDumpRuntime(void) {
    LEMLog(@"badge-dump start");

    // Classes whose name mentions a badge: the view that draws it, the manager
    // that feeds it, and anything else SpringBoard uses.
    int classCount = objc_getClassList(NULL, 0);
    if (classCount > 0) {
        Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
        if (classes) {
            classCount = objc_getClassList(classes, classCount);
            for (int index = 0; index < classCount; index++) {
                Class cls = classes[index];
                const char *name = class_getName(cls);
                if (name && strstr(name, "Badge")) {
                    LEMLog(@"badge-class %s super=%s instance=%@", name,
                           class_getSuperclass(cls) ? class_getName(class_getSuperclass(cls)) : "nil",
                           LEMMethodList(cls, NO, nil));
                }
            }
            free(classes);
        }
    }

    NSArray<NSString *> *candidates = @[
        @"SBIcon",
        @"SBIconView",
        @"SBIconBadgeView",
        @"SBApplicationIcon",
        @"SBApplication",
        @"SBLeafIcon",
        @"SBIconModel",
        @"SBIconListModel",
        @"SBIconListView",
        @"SBHIconManager",
        @"SBHIconModel",
        @"SBRootFolderController",
        @"LSApplicationProxy",
        @"LSApplicationWorkspace",
    ];
    for (NSString *name in candidates) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) {
            LEMLog(@"badge-parser missing class=%@", name);
            continue;
        }
        LEMDumpClass(cls, @"badge");
    }

    LEMLog(@"badge-dump done");
}

void LEMBadgeDumpSelectors(void) {
    LEMLog(@"badge-selector-dump start");

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        LEMLog(@"badge-selector-dump empty");
        return;
    }
    Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) {
        return;
    }
    classCount = objc_getClassList(classes, classCount);

    NSUInteger matched = 0;
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        const char *image = class_getImageName(cls);
        if (!image || !strstr(image, "SpringBoard")) {
            continue;
        }
        NSString *instance = LEMMethodList(cls, NO, @"badge");
        NSString *classMethods = LEMMethodList(cls, YES, @"badge");
        BOOL hasInstance = ![instance isEqualToString:@"(none)"];
        BOOL hasClass = ![classMethods isEqualToString:@"(none)"];
        if (!hasInstance && !hasClass) {
            continue;
        }
        matched++;
        LEMLog(@"badge-selector %@ instance=%@ class=%@", NSStringFromClass(cls),
               hasInstance ? instance : @"-", hasClass ? classMethods : @"-");
    }
    free(classes);

    LEMLog(@"badge-selector-dump done classes=%lu", (unsigned long)matched);
}

static id LEMSafeValue(id object, NSString *key) {
    if (!object) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return @"(throw)";
    }
}

static void LEMDumpSubviewTree(UIView *view, NSUInteger depth) {
    if (!view || depth > 3) {
        return;
    }
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    BOOL badge = [NSStringFromClass([view class]) containsString:@"Badge"];
    LEMLog(@"%@%@%@ frame=%@ alpha=%.2f hidden=%d userInteraction=%d",
           badge ? @"badge-view " : @"icon-tree ", indent, NSStringFromClass([view class]),
           NSStringFromCGRect(view.frame), view.alpha, view.hidden, view.userInteractionEnabled);
    for (UIView *child in view.subviews) {
        LEMDumpSubviewTree(child, depth + 1);
    }
}

static void LEMEnumerateIconViews(UIView *view, NSUInteger depth,
                                  Class iconViewClass, NSMutableArray<UIView *> *icons) {
    if (!view || depth > 10) {
        return;
    }
    if (iconViewClass && [view isKindOfClass:iconViewClass]) {
        [icons addObject:view];
    }
    for (UIView *child in view.subviews) {
        LEMEnumerateIconViews(child, depth + 1, iconViewClass, icons);
    }
}

void LEMBadgeDumpIconTree(void) {
    Class iconViewClass = objc_getClass("SBIconView");
    if (!iconViewClass) {
        LEMLog(@"icon-tree missing SBIconView");
        return;
    }

    UIWindow *iconWindow = nil;
    NSUInteger bestCount = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *found = [NSMutableArray array];
            LEMEnumerateIconViews(candidate, 0, iconViewClass, found);
            LEMLog(@"icon-tree window=%@ level=%.1f icons=%lu", NSStringFromClass([candidate class]),
                   candidate.windowLevel, (unsigned long)found.count);
            if (found.count > bestCount) {
                bestCount = found.count;
                iconWindow = candidate;
            }
        }
    }
    if (!iconWindow) {
        LEMLog(@"icon-tree no window with icons");
        return;
    }

    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    LEMEnumerateIconViews(iconWindow, 0, iconViewClass, icons);
    LEMLog(@"icon-tree start window=%@ icons=%lu", NSStringFromClass([iconWindow class]),
           (unsigned long)icons.count);

    NSUInteger withBadge = 0;
    for (UIView *iconView in icons) {
        id icon = LEMSafeValue(iconView, @"icon");
        id badgeNumber = LEMSafeValue(icon, @"badgeNumberOrString");
        id badgeString = LEMSafeValue(iconView, @"badgeString");
        if (badgeNumber || badgeString) {
            withBadge++;
        }
        LEMLog(@"icon-tree icon=%@ badgeString=%@ iconClass=%@ badgeNumberOrString=%@ "
               @"override=%@ frameInWindow=%@",
               NSStringFromClass([iconView class]), badgeString, NSStringFromClass([icon class]),
               badgeNumber, LEMSafeValue(iconView, @"overrideBadgeNumberOrString"),
               NSStringFromCGRect([iconView convertRect:iconView.bounds toView:iconWindow]));
        LEMDumpSubviewTree(iconView, 0);
    }

    LEMLog(@"icon-tree done icons=%lu withBadge=%lu", (unsigned long)icons.count,
           (unsigned long)withBadge);
}

void LEMBadgeDumpState(void) {
    LEMLog(@"badge-state start");

    Class iconViewClass = objc_getClass("SBIconView");
    if (iconViewClass) {
        LEMLog(@"badge-state SBIconView ivars[all]: %@", LEMIvarList(iconViewClass, nil));
        LEMLog(@"badge-state SBIconView instance[accessory]: %@",
               LEMMethodList(iconViewClass, NO, @"accessory"));
        LEMLog(@"badge-state SBIconView properties[all]: %@", LEMPropertyList(iconViewClass, nil));
    }

    id controller = nil;
    Class controllerClass = objc_getClass("SBIconController");
    if (controllerClass && [controllerClass respondsToSelector:@selector(sharedInstance)]) {
        controller = [controllerClass performSelector:@selector(sharedInstance)];
    }
    id iconManager = LEMSafeValue(controller, @"iconManager");
    id iconModel = LEMSafeValue(iconManager, @"iconModel");
    LEMLog(@"badge-state controller=%@ iconManager=%@ iconModel=%@",
           controller ? NSStringFromClass([controller class]) : @"nil",
           iconManager ? NSStringFromClass([iconManager class]) : @"nil",
           iconModel ? NSStringFromClass([iconModel class]) : @"nil");
    LEMLog(@"badge-state iconModel class=%@ leaves=%lu",
           iconModel ? NSStringFromClass([iconModel class]) : @"nil",
           (unsigned long)[LEMSafeValue(iconModel, @"leafIcons") count]);

    // Whether the badge is archived with the icon state decides how a cleared
    // badge has to be written back; these are the selectors that would do it.
    for (NSString *name in @[ @"SBIconModel", @"SBHIconModel", @"SBIconStateArchiver" ]) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) {
            LEMLog(@"badge-state missing class=%@", name);
            continue;
        }
        for (NSString *filter in @[ @"state", @"save", @"archive", @"badge", @"sync" ]) {
            NSString *instance = LEMMethodList(cls, NO, filter);
            NSString *classMethods = LEMMethodList(cls, YES, filter);
            BOOL hasInstance = ![instance isEqualToString:@"(none)"];
            BOOL hasClass = ![classMethods isEqualToString:@"(none)"];
            if (!hasInstance && !hasClass) {
                continue;
            }
            LEMLog(@"badge-state %@[%@] instance=%@ class=%@", name, filter,
                   hasInstance ? instance : @"-", hasClass ? classMethods : @"-");
        }
    }

    NSArray<id> *leafIcons = LEMSafeValue(iconModel, @"leafIcons");
    LEMLog(@"badge-state leafIcons=%lu", (unsigned long)leafIcons.count);

    NSUInteger badged = 0;
    for (id icon in leafIcons) {
        id badge = LEMSafeValue(icon, @"badgeNumberOrString");
        if (!badge) {
            continue;
        }
        badged++;
        id application = LEMSafeValue(icon, @"application");
        id bundleIdentifier = LEMSafeValue(application, @"bundleIdentifier");
        LEMLog(@"badge-state badge icon=%@ bundle=%@ badgeNumberOrString=%@ app=%@ badgeValue=%@ valid=%@",
               NSStringFromClass([icon class]), bundleIdentifier, badge,
               application ? NSStringFromClass([application class]) : @"nil",
               LEMSafeValue(application, @"badgeValue"),
               LEMSafeValue(application, @"isBadgeValueValid"));
    }

    LEMLog(@"badge-state done leafIcons=%lu badged=%lu",
           (unsigned long)leafIcons.count, (unsigned long)badged);
}

void LEMBadgeDumpLaunchServices(void) {
    LEMLog(@"badge-ls-dump start");

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        LEMLog(@"badge-ls-dump empty");
        return;
    }
    Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) {
        return;
    }
    classCount = objc_getClassList(classes, classCount);

    // Any class the LaunchServices image registers that talks about a badge is
    // a candidate for the store that outlives SpringBoard's own objects.
    NSUInteger matched = 0;
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        const char *image = class_getImageName(cls);
        if (!image || !strstr(image, "LaunchServices")) {
            continue;
        }
        NSString *instance = LEMMethodList(cls, NO, @"badge");
        NSString *classMethods = LEMMethodList(cls, YES, @"badge");
        BOOL hasInstance = ![instance isEqualToString:@"(none)"];
        BOOL hasClass = ![classMethods isEqualToString:@"(none)"];
        if (!hasInstance && !hasClass) {
            continue;
        }
        matched++;
        LEMLog(@"badge-ls-selector %@ instance=%@ class=%@", NSStringFromClass(cls),
               hasInstance ? instance : @"-", hasClass ? classMethods : @"-");
    }
    free(classes);
    LEMLog(@"badge-ls-dump selectors=%lu", (unsigned long)matched);

    // Full method lists of the two objects that could own the stored badge.
    for (NSString *name in @[ @"LSApplicationProxy", @"LSApplicationWorkspace",
                              @"LSApplicationRecord" ]) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) {
            LEMLog(@"badge-ls-dump missing class=%@", name);
            continue;
        }
        LEMLog(@"badge-ls-dump %@ instance=%@", name, LEMMethodList(cls, NO, nil));
        LEMLog(@"badge-ls-dump %@ class=%@", name, LEMMethodList(cls, YES, nil));
    }

    LEMLog(@"badge-ls-dump done");
}

void LEMBadgeDumpIconStateArchive(void) {
    id controller = nil;
    Class controllerClass = objc_getClass("SBIconController");
    if (controllerClass && [controllerClass respondsToSelector:@selector(sharedInstance)]) {
        controller = [controllerClass performSelector:@selector(sharedInstance)];
    }
    id iconManager = LEMSafeValue(controller, @"iconManager");
    id iconModel = LEMSafeValue(iconManager, @"iconModel");
    id state = LEMSafeValue(iconModel, @"desiredIconState");
    if (![state isKindOfClass:[NSDictionary class]]) {
        LEMLog(@"badge-state-archive skipped model=%@ state=%@",
               iconModel ? NSStringFromClass([iconModel class]) : @"nil",
               state ? NSStringFromClass([state class]) : @"nil");
        return;
    }

    NSString *path = @"/var/log/lemon/iconstate.xml";
    NSData *data = nil;
    @try {
        data = [NSPropertyListSerialization dataWithPropertyList:state
                                                          format:NSPropertyListXMLFormat_v1_0
                                                         options:0
                                                           error:NULL];
    } @catch (NSException *exception) {
        data = nil;
    }
    if (!data) {
        NSString *text = [state description];
        data = [text dataUsingEncoding:NSUTF8StringEncoding];
    }
    BOOL written = [data writeToFile:path atomically:YES];
    LEMLog(@"badge-state-archive written=%d bytes=%lu path=%@", written,
           (unsigned long)data.length, path);
}
