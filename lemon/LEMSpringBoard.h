//
//  LEMSpringBoard.h
//  Lemon
//
//  The SpringBoard classes Lemon reaches by name. SpringBoard ships no headers,
//  so only the members Lemon uses are declared here; the classes are looked up
//  at runtime because they do not exist outside SpringBoard.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBApplication : NSObject
- (nullable NSString *)bundleIdentifier;
- (nullable id)badgeValue;
- (void)setBadgeValue:(nullable id)value;
- (void)remoteBadgeValueDidChange;
@end

@interface SBIcon : NSObject
- (nullable id)badgeNumberOrString;
- (void)setBadge:(nullable id)badge;
- (void)noteBadgeDidChange;
- (nullable SBApplication *)application;
@end

@interface SBIconModel : NSObject
- (NSArray *)leafIcons;
@end

@interface SBHIconManager : NSObject
- (SBIconModel *)iconModel;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (SBHIconManager *)iconManager;
@end

@interface SBIconBadgeView : UIView
- (void)prepareForReuse;
- (void)configureForIcon:(SBIcon *)icon infoProvider:(id)provider;
- (void)configureAnimatedForIcon:(SBIcon *)icon infoProvider:(id)provider animator:(id)animator;
@end

NS_ASSUME_NONNULL_END
