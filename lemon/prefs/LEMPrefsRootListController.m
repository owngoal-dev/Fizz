//
//  LEMPrefsRootListController.m
//  Lemon
//
//  The Settings pane of Lemon. It holds three switches and nothing else: the
//  global switch, the haptics switch, and the switch that decides whether a
//  cleared badge stays cleared when its application publishes the old count
//  again.
//
//  Preferences.framework is private and the SDK ships no headers for it, so the
//  two classes the pane builds on are declared here; the bundle leaves
//  PSListController and PSSpecifier unresolved and Settings resolves them when
//  it loads the pane.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "LEMPreferences.h"

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                 target:(id)target
                                    set:(SEL)setter
                                    get:(SEL)getter
                                 detail:(Class)detail
                                   cell:(NSInteger)cell
                                   edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

// PSListController renders the array in its own `_specifiers` ivar, so the pane
// fills that ivar and not one of its own. The declaration below makes the
// compiler reference the ivar offset Preferences exports, the same way the
// other panes on this device do.
@interface PSListController : UIViewController {
    NSMutableArray *_specifiers;
}
- (NSArray *)specifiers;
@end

// PSCellType: PSSwitchCell = 6.
static const NSInteger LEMSwitchCellType = 6;

@interface LEMPrefsRootListController : PSListController
@end

@implementation LEMPrefsRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"Lemon";
    }
    return self;
}

// Both switches are stored the same way: the specifier carries its own key and
// the cell calls back into the two methods below.
- (PSSpecifier *)switchNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:)
                                                            detail:nil
                                                              cell:LEMSwitchCellType
                                                              edit:nil];
    [specifier setProperty:key forKey:@"key"];
    return specifier;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        PSSpecifier *gestures = [PSSpecifier groupSpecifierWithName:@"手势"];
        [gestures setProperty:@"主屏幕双指外扩：图标向外扩散，同时清除所有角标，并按涟漪节奏播放自定义触感。"
                             @"关闭后手势不再响应。"
                       forKey:@"footerText"];

        PSSpecifier *badges = [PSSpecifier groupSpecifierWithName:@"角标"];
        [badges setProperty:@"App 打开或退到后台时仍会重新上报角标。打开本项后，与已清除数字相同的旧值会被忽略，"
                             @"新数字照常显示；关闭后旧数字可能再次出现。"
                    forKey:@"footerText"];

        _specifiers = [@[
            gestures, [self switchNamed:@"启用" key:LEMPreferencesEnabledKey],
            [self switchNamed:@"触感反馈" key:LEMPreferencesHapticsKey], badges,
            [self switchNamed:@"角标维持" key:LEMPreferencesKeepClearedKey]
        ] mutableCopy];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    return @(LEMPreferencesGetBool(key, YES));
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) {
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef) @([value boolValue]),
                             (__bridge CFStringRef)LEMPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)LEMPreferencesDomain);
}

@end
