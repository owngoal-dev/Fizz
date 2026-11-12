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
// middle, two rings around it, the outer one thinner and fainter, both opening
// the same gap towards the upper right on one ray, with a bubble seated in it.
// Two rings only: at 29 pt a third one turned the tile into a target with rings
// inside rings, and the two that remain still read as one mark spreading out.
// The tile stays dark ink with two very quiet auras, so the pale mark carries the
// icon on its own.
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

    // Rings. The gap faces the upper right, and both rings open the same visual
    // gap so the two openings sit on one ray through the center; each arc is
    // drawn wider by its own round caps, which are what eat back into the gap.
    static const CGFloat ringRadius[2] = { 0.192, 0.330 };
    static const CGFloat ringWidth[2] = { 0.056, 0.040 };
    static const CGFloat ringAlpha[2] = { 0.84, 0.48 };
    static const CGFloat gapVisual = 44.0;
    // The outer ring leans towards the teal of the aura, so the mark has a colour
    // of its own instead of being plain white lines on ink.
    static const CGFloat ringTint[2][3] = {
        { 1.000, 1.000, 1.000 },
        { 0.760, 0.941, 0.914 },
    };
    static const CGFloat gapAngle = 50.0;
    for (NSUInteger index = 0; index < 2; index++) {
        CGFloat radius = side * ringRadius[index];
        CGFloat capHalfWidth = side * ringWidth[index] / 2.0;
        CGFloat capDegrees = 2.0 * asin(capHalfWidth / radius) * 180.0 / M_PI;
        CGFloat gap = gapVisual + capDegrees;
        CGFloat start = (CGFloat)((gapAngle + gap / 2.0) * M_PI / 180.0);
        CGFloat end = (CGFloat)((gapAngle - gap / 2.0) * M_PI / 180.0);
        CGColorRef ring = FIZZColor(ringTint[index][0], ringTint[index][1], ringTint[index][2],
                                    ringAlpha[index]);
        FIZZStrokeArc(context, center, radius, side * ringWidth[index], ring, start, end);
        CGColorRelease(ring);
    }

    // The badge itself, solid, and the one bubble seated in the mouth of the
    // outer ring's gap, on the ring's own radius, so the mark reads as one piece
    // instead of a ring with a dot drifting off in the corner.
    CGColorRef badge = FIZZColorWithAlpha(white, 0.90);
    FIZZFillCircle(context, center, side * 0.082, badge);
    CGColorRelease(badge);

    CGFloat angle = (CGFloat)(gapAngle * M_PI / 180.0);
    CGPoint bubble = CGPointMake(center.x + cos(angle) * side * 0.334,
                                 center.y + sin(angle) * side * 0.334);
    CGColorRef bubbleColor = FIZZColor(0.840, 0.960, 0.945, 0.68);
    FIZZFillCircle(context, bubble, side * 0.050, bubbleColor);
    CGColorRelease(bubbleColor);

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

        // The badge must be at the middle of the icon, both rings must be crossed
        // above it, the upper right must hold a bubble, and the outermost corner
        // must be fully transparent.
        CGContextRef probe = FIZZCreateContext(87.0);
        CGImageRef probeIcon = FIZZCreateRoundedIcon(master, 87.0);
        CGContextDrawImage(probe, CGRectMake(0, 0, 87, 87), probeIcon);
        CGImageRelease(probeIcon);
        FIZZSamplePixel(probe, 87.0, 0.50, 0.50, "badge");
        FIZZSamplePixel(probe, 87.0, 0.50, 0.672, "ring-inner");
        FIZZSamplePixel(probe, 87.0, 0.50, 0.830, "ring-outer");
        FIZZSamplePixel(probe, 87.0, 0.715, 0.244, "bubble-gap");
        FIZZSamplePixel(probe, 87.0, 0.01, 0.01, "corner");
        CGContextRelease(probe);

        CGImageRelease(master);
    }
    return 0;
}
