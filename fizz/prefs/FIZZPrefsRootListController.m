//
//  FIZZPrefsRootListController.m
//  Fizz
//
//  The Settings pane of Fizz. A banner at the top introduces the package and
//  holds the global switch; below it one unlabelled group holds the remaining
//  two switches.
//
//  Preferences.framework is private and the SDK ships no headers for it, so the
//  two classes the pane builds on are declared here; the bundle leaves
//  PSListController and PSSpecifier unresolved and Settings resolves them when
//  it loads the pane.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>

#import "FIZZPreferences.h"

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
static const NSInteger FIZZSwitchCellType = 6;

@interface FIZZPrefsRootListController : PSListController
@end

#pragma mark - Banner

// The pane's own bundle holds the artwork. ImageIO is used directly instead of
// UIImage imageNamed:inBundle:, so the icon resolves to the exact file that was
// packaged whatever Settings decides to search.
static CGImageRef FIZZCreateBannerIcon(void) {
    NSBundle *bundle = [NSBundle bundleForClass:[FIZZPrefsRootListController class]];
    NSArray<NSString *> *candidates = @[ @"banner@3x", @"banner@2x", @"banner", @"icon@3x" ];
    for (NSString *name in candidates) {
        NSString *path = [bundle pathForResource:name ofType:@"png"];
        if (!path) {
            continue;
        }
        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) {
            continue;
        }
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (image) {
            return image;
        }
    }
    return NULL;
}

static const CGFloat FIZZBannerSideInset = 16.0;
static const CGFloat FIZZBannerTopInset = 12.0;
static const CGFloat FIZZBannerBottomInset = 6.0;
static const CGFloat FIZZBannerPadding = 16.0;
static const CGFloat FIZZBannerIconSide = 50.0;
static const CGFloat FIZZBannerSwitchRowHeight = 31.0;
static const CGFloat FIZZBannerSwitchRowInset = 9.0;

// Padding, icon, gap, divider, gap, switch row, gap.
static const CGFloat FIZZBannerCardHeight = 16.0 + 50.0 + 12.0 + 1.0 + FIZZBannerSwitchRowInset +
                                           FIZZBannerSwitchRowHeight + FIZZBannerSwitchRowInset;
static const CGFloat FIZZBannerHeight = FIZZBannerTopInset + FIZZBannerCardHeight + FIZZBannerBottomInset;

// The card at the top of the pane: the icon, the name of the package, what the
// gesture does in one line, and the global switch on the row under the divider.
@interface FIZZBannerView : UIView
@end

@implementation FIZZBannerView {
    UIView *_card;
    CAGradientLayer *_gradient;
    UIView *_iconView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIView *_divider;
    UILabel *_enabledLabel;
    UISwitch *_enabledSwitch;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.backgroundColor = [UIColor clearColor];
    self.isAccessibilityElement = NO;

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 18.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.masksToBounds = YES;
    _card.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    [self addSubview:_card];

    _gradient = [CAGradientLayer layer];
    _gradient.startPoint = CGPointMake(0.0, 0.0);
    _gradient.endPoint = CGPointMake(1.0, 1.0);
    [_card.layer insertSublayer:_gradient atIndex:0];

    _iconView = [[UIView alloc] initWithFrame:CGRectZero];
    _iconView.backgroundColor = [UIColor clearColor];
    CGImageRef iconImage = FIZZCreateBannerIcon();
    if (iconImage) {
        _iconView.layer.contents = (__bridge id)iconImage;
        _iconView.layer.contentsGravity = kCAGravityResizeAspect;
        CGImageRelease(iconImage);
    }
    [_card addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    _titleLabel.text = @"Fizz";
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.8;
    [_card addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    _subtitleLabel.text = @"双指外扩，角标随图标一起散开";
    _subtitleLabel.adjustsFontSizeToFitWidth = YES;
    _subtitleLabel.minimumScaleFactor = 0.8;
    [_card addSubview:_subtitleLabel];

    _divider = [[UIView alloc] initWithFrame:CGRectZero];
    [_card addSubview:_divider];

    // The global switch is the one setting that belongs with the package itself,
    // so it lives in the card instead of in the list below it. It writes the
    // same domain as the rows do, so nothing else has to know it moved.
    _enabledLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    // Same font as the row titles in the list below, so the switch row reads as
    // one of them rather than as a smaller caption.
    _enabledLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
    _enabledLabel.text = @"启用";
    [_card addSubview:_enabledLabel];

    _enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _enabledSwitch.on = FIZZPreferencesGetBool(FIZZPreferencesEnabledKey, YES);
    [_enabledSwitch addTarget:self
                       action:@selector(enabledSwitchChanged:)
             forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_enabledSwitch];

    [self updateColors];
    return self;
}

- (UIColor *)accentColor {
    if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        return [UIColor colorWithRed:0.310 green:0.882 blue:0.792 alpha:1.0];
    }
    return [UIColor colorWithRed:0.055 green:0.573 blue:0.510 alpha:1.0];
}

- (void)updateColors {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    if (dark) {
        _gradient.colors = @[ (__bridge id)[UIColor colorWithRed:0.098 green:0.110 blue:0.157 alpha:1.0].CGColor,
                              (__bridge id)[UIColor colorWithRed:0.055 green:0.129 blue:0.118 alpha:1.0].CGColor ];
        _card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.07].CGColor;
    } else {
        _gradient.colors = @[ (__bridge id)[UIColor colorWithRed:0.957 green:0.973 blue:1.000 alpha:1.0].CGColor,
                              (__bridge id)[UIColor colorWithRed:0.906 green:0.984 blue:0.965 alpha:1.0].CGColor ];
        _card.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.05].CGColor;
    }
    _titleLabel.textColor = [UIColor labelColor];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _enabledLabel.textColor = [UIColor labelColor];
    _enabledSwitch.onTintColor = self.accentColor;
    _divider.backgroundColor = [UIColor separatorColor];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [self updateColors];
        [CATransaction commit];
    }
}

- (void)enabledSwitchChanged:(UISwitch *)sender {
    CFPreferencesSetAppValue((__bridge CFStringRef)FIZZPreferencesEnabledKey,
                             (__bridge CFPropertyListRef) @(sender.isOn),
                             (__bridge CFStringRef)FIZZPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)FIZZPreferencesDomain);
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.bounds);
    _card.frame = CGRectMake(FIZZBannerSideInset, FIZZBannerTopInset,
                             width - FIZZBannerSideInset * 2.0, FIZZBannerCardHeight);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradient.frame = _card.bounds;
    [CATransaction commit];

    CGFloat cardWidth = CGRectGetWidth(_card.bounds);
    CGFloat textLeft = FIZZBannerPadding + FIZZBannerIconSide + 14.0;
    CGFloat textWidth = cardWidth - textLeft - FIZZBannerPadding;

    _iconView.frame = CGRectMake(FIZZBannerPadding, FIZZBannerPadding,
                                 FIZZBannerIconSide, FIZZBannerIconSide);
    _titleLabel.frame = CGRectMake(textLeft, FIZZBannerPadding - 1.0, textWidth, 26.0);
    _subtitleLabel.frame = CGRectMake(textLeft, FIZZBannerPadding + 26.0, textWidth, 16.0);

    CGFloat dividerY = FIZZBannerPadding + FIZZBannerIconSide + 12.0;
    _divider.frame = CGRectMake(FIZZBannerPadding, dividerY,
                                cardWidth - FIZZBannerPadding * 2.0, 1.0 / UIScreen.mainScreen.scale);

    CGFloat rowTop = dividerY + FIZZBannerSwitchRowInset;
    CGSize switchSize = [_enabledSwitch sizeThatFits:CGSizeMake(cardWidth, FIZZBannerSwitchRowHeight)];
    _enabledSwitch.frame = CGRectMake(cardWidth - FIZZBannerPadding - switchSize.width,
                                      rowTop + (FIZZBannerSwitchRowHeight - switchSize.height) / 2.0,
                                      switchSize.width, switchSize.height);

    CGFloat labelWidth = CGRectGetMinX(_enabledSwitch.frame) - FIZZBannerPadding - 12.0;
    _enabledLabel.frame = CGRectMake(FIZZBannerPadding, rowTop, labelWidth, FIZZBannerSwitchRowHeight);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, FIZZBannerHeight);
}

@end

#pragma mark - Controller

@implementation FIZZPrefsRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"Fizz";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // The table is built while the pane loads, so the banner is installed once
    // the first run loop turn is over and the table has a width.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self fizz_installBanner];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self fizz_installBanner];
}

static UITableView *FIZZFindTableView(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) {
        return (UITableView *)view;
    }
    for (UIView *subview in view.subviews) {
        UITableView *found = FIZZFindTableView(subview);
        if (found) {
            return found;
        }
    }
    return nil;
}

// The banner is the table's header view, so it scrolls away with the list
// instead of covering it. Preferences rebuilds the table on reload, hence the
// check on every layout pass rather than a single install.
- (void)fizz_installBanner {
    UITableView *table = FIZZFindTableView(self.view);
    if (!table) {
        return;
    }
    CGFloat width = CGRectGetWidth(table.bounds);
    if (width <= 0.0) {
        return;
    }
    FIZZBannerView *banner = (FIZZBannerView *)table.tableHeaderView;
    if (![banner isKindOfClass:[FIZZBannerView class]]) {
        banner = [[FIZZBannerView alloc] initWithFrame:CGRectMake(0, 0, width, FIZZBannerHeight)];
        table.tableHeaderView = banner;
        return;
    }
    if (CGRectGetWidth(banner.frame) != width) {
        CGRect frame = banner.frame;
        frame.size.width = width;
        frame.size.height = FIZZBannerHeight;
        banner.frame = frame;
        table.tableHeaderView = banner;
    }
}

// Each row stores itself the same way: the specifier carries its own key and
// the cell calls back into the two methods below.
- (PSSpecifier *)switchNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:)
                                                            detail:nil
                                                              cell:FIZZSwitchCellType
                                                              edit:nil];
    [specifier setProperty:key forKey:@"key"];
    return specifier;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        // One group, no title: the banner already says what this page is about,
        // so only the badge footer needs to stay.
        PSSpecifier *rows = [PSSpecifier groupSpecifierWithName:@""];
        [rows setProperty:@"App 打开或退到后台时仍会重新上报角标。打开本项后，与已清除数字相同的旧值会被忽略，"
                          @"新数字照常显示；关闭后旧数字可能再次出现。"
                 forKey:@"footerText"];

        _specifiers = [@[
            rows, [self switchNamed:@"触感反馈" key:FIZZPreferencesHapticsKey],
            [self switchNamed:@"角标维持" key:FIZZPreferencesKeepClearedKey]
        ] mutableCopy];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    return @(FIZZPreferencesGetBool(key, YES));
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) {
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef) @([value boolValue]),
                             (__bridge CFStringRef)FIZZPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)FIZZPreferencesDomain);
}

@end
