//
//  FIZZIconGen.m
//  Fizz
//
//  Draws the Settings icon for Fizz: one full-size master image, then the
//  three rounded icons the preference bundle ships, masked with Apple's
//  continuous corner curve. Run from the project root, so that the output
//  paths below resolve inside the repository.
//
//  clang -arch arm64e -miphoneos-version-min=15.0 -fobjc-arc -O2 \
//        -framework Foundation -framework CoreGraphics -framework QuartzCore \
//        -framework ImageIO -o "$TMPDIR/fizz-icon-gen" scripts/icon/FIZZIconGen.m
//  ldid -S "$TMPDIR/fizz-icon-gen"
//  "$TMPDIR/fizz-icon-gen"
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>

static const CGFloat FIZZMasterSide = 1024.0;

// Corner radius of the iOS app icon grid, as a share of the icon side.
static const CGFloat FIZZCornerRatio = 0.2237;

#pragma mark - Contexts

static CGContextRef FIZZCreateContext(CGFloat side)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)side, (size_t)side, 8, 0, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextSetShouldAntialias(context, YES);
    CGContextSetAllowsAntialiasing(context, YES);
    CGContextClearRect(context, CGRectMake(0, 0, side, side));
    return context;
}

#pragma mark - Colours and primitives

static CGColorRef FIZZColor(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[4] = { red, green, blue, alpha };
    CGColorRef color = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return color;
}

static CGColorRef FIZZColorWithAlpha(CGColorRef color, CGFloat alpha)
{
    const CGFloat *components = CGColorGetComponents(color);
    return FIZZColor(components[0], components[1], components[2], alpha);
}

static void FIZZFillCircle(CGContextRef context, CGPoint center, CGFloat radius, CGColorRef color)
{
    CGContextSaveGState(context);
    CGContextSetFillColorWithColor(context, color);
    CGContextAddArc(context, center.x, center.y, radius, 0, (CGFloat)M_PI * 2, 0);
    CGContextFillPath(context);
    CGContextRestoreGState(context);
}

// One arc of a ring, drawn with round caps so both ends of the gap read as a
// deliberate stop rather than a cut.
static void FIZZStrokeArc(CGContextRef context, CGPoint center, CGFloat radius, CGFloat width,
                          CGColorRef color, CGFloat startRadians, CGFloat endRadians)
{
    CGContextSaveGState(context);
    CGContextSetStrokeColorWithColor(context, color);
    CGContextSetLineWidth(context, width);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextAddArc(context, center.x, center.y, radius, startRadians, endRadians, 0);
    CGContextStrokePath(context);
    CGContextRestoreGState(context);
}

static void FIZZDrawRadialGlow(CGContextRef context, CGPoint center, CGFloat radius, CGColorRef color)
{
    CGColorRef edge = FIZZColorWithAlpha(color, 0.0);
    const void *colors[] = { (void *)color, (void *)edge };
    CFArrayRef array = CFArrayCreate(NULL, colors, 2, &kCFTypeArrayCallBacks);
    CGFloat locations[2] = { 0.0, 1.0 };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, array, locations);
    CGContextSaveGState(context);
    CGContextAddArc(context, center.x, center.y, radius, 0, (CGFloat)M_PI * 2, 0);
    CGContextClip(context);
    CGContextDrawRadialGradient(context, gradient, center, 0, center, radius, 0);
    CGContextRestoreGState(context);
    CGGradientRelease(gradient);
    CFRelease(array);
    CGColorSpaceRelease(space);
    CGColorRelease(edge);
}

static void FIZZDrawLinearGradient(CGContextRef context, CGPoint from, CGPoint to,
                                   CGColorRef start, CGColorRef end)
{
    const void *colors[] = { (void *)start, (void *)end };
    CFArrayRef array = CFArrayCreate(NULL, colors, 2, &kCFTypeArrayCallBacks);
    CGFloat locations[2] = { 0.0, 1.0 };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, array, locations);
    CGContextDrawLinearGradient(context, gradient, from, to, 0);
    CGGradientRelease(gradient);
    CFRelease(array);
    CGColorSpaceRelease(space);
}

#pragma mark - Artwork

// The mark is one badge and the wave it pushes out: a small solid dot in the
// middle, three rings around it, each thinner and fainter than the last, and
// each opening a wider gap towards the upper right where three bubbles have
// already left. The tile is dark ink with two very quiet auras, so the white
// mark carries the whole icon without anything else competing with it.
static void FIZZDrawArtwork(CGContextRef context, CGFloat side)
{
    // Ink: a touch of blue at the top left, almost black at the bottom right.
    CGColorRef inkTop = FIZZColor(0.137, 0.161, 0.239, 1.0);
    CGColorRef inkBottom = FIZZColor(0.027, 0.035, 0.055, 1.0);
    FIZZDrawLinearGradient(context, CGPointMake(0, side), CGPointMake(side, 0), inkTop, inkBottom);

    // Auras, well under half strength: teal behind the mark, a cool blue at the
    // top edge. Both are what give the tile depth instead of a flat fill.
    CGColorRef teal = FIZZColor(0.161, 0.851, 0.760, 0.17);
    CGColorRef blue = FIZZColor(0.298, 0.416, 1.000, 0.13);
    FIZZDrawRadialGlow(context, CGPointMake(side * 0.54, side * 0.46), side * 0.62, teal);
    FIZZDrawRadialGlow(context, CGPointMake(side * 0.20, side * 0.88), side * 0.52, blue);

    // Light falls from the top, which keeps the lower half of the tile quiet.
    CGColorRef sheenTop = FIZZColor(1, 1, 1, 0.070);
    CGColorRef sheenBottom = FIZZColor(1, 1, 1, 0.0);
    FIZZDrawLinearGradient(context, CGPointMake(0, side), CGPointMake(0, side * 0.42),
                           sheenTop, sheenBottom);

    CGPoint center = CGPointMake(side * 0.5, side * 0.5);
    CGColorRef white = FIZZColor(1, 1, 1, 1);

    // Rings. The gap faces the upper right; it widens with every ring, so the
    // three read as one motion outwards rather than three separate circles.
    static const CGFloat ringRadius[3] = { 0.150, 0.232, 0.315 };
    static const CGFloat ringWidth[3] = { 0.033, 0.023, 0.015 };
    static const CGFloat ringAlpha[3] = { 0.94, 0.58, 0.34 };
    static const CGFloat ringGap[3] = { 40.0, 58.0, 78.0 };
    // The outer rings lean towards the teal of the aura, so the mark has a
    // colour of its own instead of being plain white lines on ink.
    static const CGFloat ringTint[3][3] = {
        { 1.000, 1.000, 1.000 },
        { 0.812, 0.976, 0.953 },
        { 0.639, 0.925, 0.878 },
    };
    static const CGFloat gapAngle = 50.0;
    for (NSUInteger index = 0; index < 3; index++) {
        CGFloat start = (CGFloat)((gapAngle + ringGap[index] / 2.0) * M_PI / 180.0);
        CGFloat end = (CGFloat)((gapAngle - ringGap[index] / 2.0) * M_PI / 180.0);
        CGColorRef ring = FIZZColor(ringTint[index][0], ringTint[index][1], ringTint[index][2],
                                    ringAlpha[index]);
        FIZZStrokeArc(context, center, side * ringRadius[index], side * ringWidth[index],
                      ring, start, end);
        CGColorRelease(ring);
    }

    // The badge itself, small and solid, and the bubbles that got away: they sit
    // on the axis of the gaps, shrinking as they travel.
    CGColorRef badge = FIZZColorWithAlpha(white, 0.97);
    FIZZFillCircle(context, center, side * 0.055, badge);
    CGColorRelease(badge);

    static const CGFloat bubbleRadius[3] = { 0.191, 0.273, 0.355 };
    static const CGFloat bubbleSize[3] = { 0.0145, 0.0100, 0.0065 };
    static const CGFloat bubbleAlpha[3] = { 0.72, 0.44, 0.24 };
    CGFloat angle = (CGFloat)(gapAngle * M_PI / 180.0);
    for (NSUInteger index = 0; index < 3; index++) {
        CGPoint point = CGPointMake(center.x + cos(angle) * side * bubbleRadius[index],
                                    center.y + sin(angle) * side * bubbleRadius[index]);
        CGColorRef bubble = FIZZColorWithAlpha(white, bubbleAlpha[index]);
        FIZZFillCircle(context, point, side * bubbleSize[index], bubble);
        CGColorRelease(bubble);
    }

    CGColorRelease(white);
    CGColorRelease(sheenBottom);
    CGColorRelease(sheenTop);
    CGColorRelease(blue);
    CGColorRelease(teal);
    CGColorRelease(inkBottom);
    CGColorRelease(inkTop);
}

#pragma mark - Output

static BOOL FIZZWritePNG(CGImageRef image, NSString *path)
{
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                                                      CFSTR("public.png"), 1, NULL);
    if (!destination) {
        return NO;
    }
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return written;
}

// Renders the master into a square of the given side and cuts it with the
// continuous corner curve, so the result has the same silhouette as an app icon.
static CGImageRef FIZZCreateRoundedIcon(CGImageRef master, CGFloat side)
{
    CGContextRef scaledContext = FIZZCreateContext(side);
    CGContextDrawImage(scaledContext, CGRectMake(0, 0, side, side), master);
    CGImageRef scaled = CGBitmapContextCreateImage(scaledContext);
    CGContextRelease(scaledContext);

    CALayer *layer = [CALayer layer];
    layer.bounds = CGRectMake(0, 0, side, side);
    layer.position = CGPointMake(side / 2, side / 2);
    layer.contents = (__bridge id)scaled;
    layer.contentsScale = 1.0;
    layer.masksToBounds = YES;
    layer.cornerRadius = side * FIZZCornerRatio;
    layer.cornerCurve = kCACornerCurveContinuous;

    CGContextRef outputContext = FIZZCreateContext(side);
    // CALayer.renderInContext: draws into a flipped space, so flip it back
    // before asking for the layer, or the icon comes out upside down.
    CGContextTranslateCTM(outputContext, 0, side);
    CGContextScaleCTM(outputContext, 1, -1);
    [layer renderInContext:outputContext];
    CGImageRef icon = CGBitmapContextCreateImage(outputContext);
    CGContextRelease(outputContext);
    CGImageRelease(scaled);
    return icon;
}

static void FIZZSamplePixel(CGContextRef context, CGFloat side, CGFloat xShare, CGFloat yShare,
                            const char *label)
{
    size_t bytesPerRow = CGBitmapContextGetBytesPerRow(context);
    NSUInteger column = (NSUInteger)(side * xShare);
    NSUInteger row = (NSUInteger)(side * yShare);
    unsigned char *pixel = (unsigned char *)CGBitmapContextGetData(context) + row * bytesPerRow + column * 4;
    printf("sample %-10s rgba %3u %3u %3u %3u\n", label, pixel[0], pixel[1], pixel[2], pixel[3]);
}

int main(void)
{
    @autoreleasepool {
        NSString *root = NSFileManager.defaultManager.currentDirectoryPath;

        CGContextRef masterContext = FIZZCreateContext(FIZZMasterSide);
        FIZZDrawArtwork(masterContext, FIZZMasterSide);
        CGImageRef master = CGBitmapContextCreateImage(masterContext);
        CGContextRelease(masterContext);

        NSString *artworkDirectory = [root stringByAppendingPathComponent:@"artwork"];
        [NSFileManager.defaultManager createDirectoryAtPath:artworkDirectory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
        NSString *masterPath = [artworkDirectory stringByAppendingPathComponent:@"Fizz-icon-1024.png"];
        if (!FIZZWritePNG(master, masterPath)) {
            fprintf(stderr, "failed to write %s\n", masterPath.UTF8String);
            return 1;
        }
        printf("master %s\n", masterPath.UTF8String);

        NSString *iconDirectory = [[root stringByAppendingPathComponent:@"fizz"]
                                   stringByAppendingPathComponent:@"prefs"];
        NSArray<NSString *> *names = @[ @"icon.png", @"icon@2x.png", @"icon@3x.png" ];
        NSArray<NSNumber *> *sides = @[ @29.0, @58.0, @87.0 ];
        // The pane draws the banner at 50 points, so the assets carry exactly
        // 1x, 2x and 3x of that size; a larger file would only be shrunk again.
        NSArray<NSString *> *bannerNames = @[ @"banner.png", @"banner@2x.png", @"banner@3x.png" ];
        NSArray<NSNumber *> *bannerSides = @[ @50.0, @100.0, @150.0 ];
        for (NSUInteger index = 0; index < bannerNames.count; index++) {
            names = [names arrayByAddingObject:bannerNames[index]];
            sides = [sides arrayByAddingObject:bannerSides[index]];
        }
        for (NSUInteger index = 0; index < names.count; index++) {
            CGFloat side = sides[index].doubleValue;
            CGImageRef icon = FIZZCreateRoundedIcon(master, side);
            NSString *path = [iconDirectory stringByAppendingPathComponent:names[index]];
            if (!FIZZWritePNG(icon, path)) {
                fprintf(stderr, "failed to write %s\n", path.UTF8String);
                return 1;
            }
            printf("icon %s %gx%g\n", path.UTF8String, side, side);
            CGImageRelease(icon);
        }

        // The badge must be at the middle of the icon, the innermost ring must be
        // crossed above it, the upper right must hold a bubble, and the outermost
        // corner must be fully transparent.
        CGContextRef probe = FIZZCreateContext(87.0);
        CGImageRef probeIcon = FIZZCreateRoundedIcon(master, 87.0);
        CGContextDrawImage(probe, CGRectMake(0, 0, 87, 87), probeIcon);
        CGImageRelease(probeIcon);
        FIZZSamplePixel(probe, 87.0, 0.50, 0.50, "badge");
        FIZZSamplePixel(probe, 87.0, 0.50, 0.65, "ring-1");
        FIZZSamplePixel(probe, 87.0, 0.50, 0.78, "gap");
        FIZZSamplePixel(probe, 87.0, 0.66, 0.70, "bubble");
        FIZZSamplePixel(probe, 87.0, 0.01, 0.01, "corner");
        CGContextRelease(probe);

        CGImageRelease(master);
    }
    return 0;
}
