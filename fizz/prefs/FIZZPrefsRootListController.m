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
- (void)tableView:(UITableView *)tableView
    willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

// PSCellType: PSSwitchCell = 6, PSButtonCell = 13.
static const NSInteger FIZZSwitchCellType = 6;
static const NSInteger FIZZButtonCellType = 13;

// The credit row opens the studio page, the same place the studio's other
// panes send it.
static NSString *const FIZZSupportURL = @"https://havoc.app/search/82Flex";

@interface FIZZPrefsRootListController : PSListController
@end

// Every visible string lives in the pane's own bundle, so the system language
// decides what is shown. NSLocalizedString cannot be used here: it looks in the
// main bundle, which is Settings, not this pane.
static NSString *FIZZLocalizedString(NSString *key, NSString *fallback) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = [NSBundle bundleForClass:[FIZZPrefsRootListController class]];
    });
    return [bundle localizedStringForKey:key value:fallback table:@"Localizable"];
}

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
static const CGFloat FIZZBannerPadding = 16.0;
static const CGFloat FIZZBannerIconSide = 50.0;
static const CGFloat FIZZBannerTitleHeight = 26.0;
static const CGFloat FIZZBannerSubtitleHeight = 16.0;
static const CGFloat FIZZBannerSwitchRowHeight = 31.0;
static const CGFloat FIZZBannerSwitchRowInset = 9.0;
static const CGFloat FIZZBannerDividerGap = 12.0;

// The switch row under the divider: gap, row, gap.
static const CGFloat FIZZBannerSwitchBlockHeight = FIZZBannerSwitchRowInset + FIZZBannerSwitchRowHeight +
                                                  FIZZBannerSwitchRowInset;

// The space the banner leaves under its card. iOS 17 adds about 22 points of its
// own between the table header and the first section, iOS 16 puts the section
// straight under it, so the banner carries that distance itself there to keep
// the same gap between the card and the rows below on both.
static CGFloat FIZZBannerBottomInset(void) {
    if (@available(iOS 17.0, *)) {
        return 6.0;
    }
    return 28.0;
}

// Top inset, card with the taller of the icon and the text, divider and switch.
static CGFloat FIZZBannerHeightForContent(CGFloat contentHeight) {
    return FIZZBannerTopInset + FIZZBannerPadding + contentHeight + FIZZBannerDividerGap + 1.0 +
           FIZZBannerSwitchBlockHeight + FIZZBannerBottomInset();
}


// One accent for every switch in the pane: the global switch in the card and
// the rows below it share a tint instead of the system green.
static UIColor *FIZZAccentColor(UITraitCollection *traits) {
    if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
        return [UIColor colorWithRed:0.310 green:0.882 blue:0.792 alpha:1.0];
    }
    return [UIColor colorWithRed:0.055 green:0.573 blue:0.510 alpha:1.0];
}

// The switches in the list are built by PSSwitchCell, so they are tinted after
// the fact by walking the cell that is about to be shown.
static void FIZZTintSwitchesInView(UIView *view, UIColor *tint) {
    if ([view isKindOfClass:[UISwitch class]]) {
        ((UISwitch *)view).onTintColor = tint;
        return;
    }
    for (UIView *subview in view.subviews) {
        FIZZTintSwitchesInView(subview, tint);
    }
}

// The card at the top of the pane: the icon, the name of the package, what the
// gesture does in one line, and the global switch on the row under the divider.
@interface FIZZBannerView : UIView
// Height of the whole header for a given width, the subtitle wrapping included.
- (CGFloat)heightForWidth:(CGFloat)width;
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
    _subtitleLabel.text = FIZZLocalizedString(@"banner_subtitle", @"Spread two fingers to send the badges out with the icons");
    // A longer translation wraps onto a second line and the card grows taller,
    // instead of shrinking the text until it no longer reads.
    _subtitleLabel.numberOfLines = 0;
    _subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
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
    _enabledLabel.text = FIZZLocalizedString(@"enabled", @"Enable");
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
    return FIZZAccentColor(self.traitCollection);
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

- (CGFloat)textWidthForCardWidth:(CGFloat)cardWidth {
    CGFloat textLeft = FIZZBannerPadding + FIZZBannerIconSide + 14.0;
    return MAX(0.0, cardWidth - textLeft - FIZZBannerPadding);
}

// One line is the minimum the label reserves; a wrapped subtitle asks for more
// and the card, the divider and the switch row below it all move down with it.
- (CGFloat)subtitleHeightForWidth:(CGFloat)width {
    NSString *text = _subtitleLabel.text ?: @"";
    CGRect rect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{ NSFontAttributeName : _subtitleLabel.font }
                                     context:nil];
    return MAX(FIZZBannerSubtitleHeight, ceil(CGRectGetHeight(rect)));
}

- (CGFloat)contentHeightForCardWidth:(CGFloat)cardWidth {
    CGFloat textHeight = FIZZBannerTitleHeight +
                         [self subtitleHeightForWidth:[self textWidthForCardWidth:cardWidth]];
    return MAX(FIZZBannerIconSide, textHeight);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    if (width <= 0.0) {
        return 0.0;
    }
    CGFloat contentHeight = [self contentHeightForCardWidth:width - FIZZBannerSideInset * 2.0];
    return FIZZBannerHeightForContent(contentHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat cardWidth = width - FIZZBannerSideInset * 2.0;
    CGFloat textLeft = FIZZBannerPadding + FIZZBannerIconSide + 14.0;
    CGFloat textWidth = [self textWidthForCardWidth:cardWidth];
    CGFloat textHeight = FIZZBannerTitleHeight + [self subtitleHeightForWidth:textWidth];
    CGFloat contentHeight = MAX(FIZZBannerIconSide, textHeight);
    CGFloat cardHeight = FIZZBannerPadding + contentHeight + FIZZBannerDividerGap + 1.0 +
                         FIZZBannerSwitchBlockHeight;

    _card.frame = CGRectMake(FIZZBannerSideInset, FIZZBannerTopInset, cardWidth, cardHeight);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradient.frame = _card.bounds;
    [CATransaction commit];

    // Title and subtitle are one block, its centre on the icon's midline, so the
    // pair reads as vertically aligned with the artwork beside it.
    CGFloat textTop = FIZZBannerPadding + (contentHeight - textHeight) / 2.0;
    _iconView.frame = CGRectMake(FIZZBannerPadding,
                                 FIZZBannerPadding + (contentHeight - FIZZBannerIconSide) / 2.0,
                                 FIZZBannerIconSide, FIZZBannerIconSide);
    _titleLabel.frame = CGRectMake(textLeft, textTop, textWidth, FIZZBannerTitleHeight);
    _subtitleLabel.frame = CGRectMake(textLeft, textTop + FIZZBannerTitleHeight,
                                      textWidth, textHeight - FIZZBannerTitleHeight);

    CGFloat dividerY = FIZZBannerPadding + contentHeight + FIZZBannerDividerGap;
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
    return CGSizeMake(size.width, [self heightForWidth:size.width]);
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

// A switch to dark mode repaints the banner through its own callback and the
// list rows through the tint pass in fizz_installBanner.
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self.view setNeedsLayout];
    }
}

// PSListController does not implement every table delegate method on this
// system, so a super call is made only where the method really exists:
// messaging a missing superclass method aborts the whole Preferences process.
- (void)tableView:(UITableView *)tableView
    willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) {
        [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
    FIZZTintSwitchesInView(cell, FIZZAccentColor(self.traitCollection));
}

// The credit row is the only row of the second group. Preferences does not
// dispatch a button action for a specifier built in code on this system, so the
// tap is handled here instead of through the specifier's "action" property.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && indexPath.row == 0) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self fizzSupport:nil];
        return;
    }
    if ([PSListController instancesRespondToSelector:_cmd]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
    }
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
    // Rows already on screen do not get another willDisplayCell pass when the
    // pane widens or the appearance changes.
    UIColor *tint = FIZZAccentColor(self.traitCollection);
    for (UITableViewCell *cell in table.visibleCells) {
        FIZZTintSwitchesInView(cell, tint);
    }
    FIZZBannerView *banner = (FIZZBannerView *)table.tableHeaderView;
    if (![banner isKindOfClass:[FIZZBannerView class]]) {
        banner = [[FIZZBannerView alloc] initWithFrame:CGRectMake(0, 0, width, 0)];
        banner.frame = CGRectMake(0, 0, width, [banner heightForWidth:width]);
        table.tableHeaderView = banner;
        return;
    }
    // The height follows the width, because the subtitle wraps, so both are
    // compared and the table is told again when either moved.
    CGFloat height = [banner heightForWidth:width];
    if (CGRectGetWidth(banner.frame) != width || CGRectGetHeight(banner.frame) != height) {
        banner.frame = CGRectMake(0, 0, width, height);
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
        // so only the badge footer needs to stay. The footer names the row it
        // talks about, since the group holds more than one switch now.
        PSSpecifier *rows = [PSSpecifier groupSpecifierWithName:@""];
        [rows setProperty:FIZZLocalizedString(@"badges_footer",
                                              @"Apps republish their badges when they open or move to the background. "
                                              @"While “Keep Cleared” is on, a republished count that matches the cleared "
                                              @"one is ignored and a new count still shows; while it is off, the old "
                                              @"number may come back.")
                 forKey:@"footerText"];

        // The studio credit closes the pane the way it closes the studio's other
        // panes: an unlabelled group whose footer asks for support, and a button
        // that opens the studio page.
        PSSpecifier *support = [PSSpecifier groupSpecifierWithName:@""];
        [support setProperty:FIZZLocalizedString(@"support_footer",
                                                 @"This tweak was generated with the Apelin no-code platform.")
                   forKey:@"footerText"];

        PSSpecifier *supportButton =
            [PSSpecifier preferenceSpecifierNamed:FIZZLocalizedString(@"support_button",
                                                                      @"Made with ♥ by OwnGoal Studio")
                                           target:self
                                              set:NULL
                                              get:NULL
                                           detail:nil
                                             cell:FIZZButtonCellType
                                             edit:nil];
        [supportButton setProperty:@"fizzSupport:" forKey:@"action"];

        _specifiers = [@[
            rows, [self switchNamed:FIZZLocalizedString(@"haptics", @"Haptics") key:FIZZPreferencesHapticsKey],
            [self switchNamed:FIZZLocalizedString(@"keep_cleared", @"Keep Cleared")
                          key:FIZZPreferencesKeepClearedKey],
            support, supportButton
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

// PSButtonCell hands its tap to the selector named by the "action" property of
// the specifier, the same way a plist-declared button does.
- (void)fizzSupport:(PSSpecifier *)specifier {
    NSURL *url = [NSURL URLWithString:FIZZSupportURL];
    if (!url) {
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end
