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

#pragma mark - Drawing primitives

static void FIZZFillCircle(CGContextRef context, CGPoint center, CGFloat radius,
                           CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[4] = { red, green, blue, alpha };
    CGColorRef color = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    CGContextSetFillColorWithColor(context, color);
    CGContextAddArc(context, center.x, center.y, radius, 0, (CGFloat)M_PI * 2, 0);
    CGContextFillPath(context);
    CGColorRelease(color);
}

static void FIZZStrokeCircle(CGContextRef context, CGPoint center, CGFloat radius,
                             CGFloat lineWidth, CGFloat alpha)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[4] = { 1, 1, 1, alpha };
    CGColorRef color = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    CGContextSetStrokeColorWithColor(context, color);
    CGContextSetLineWidth(context, lineWidth);
    CGContextAddArc(context, center.x, center.y, radius, 0, (CGFloat)M_PI * 2, 0);
    CGContextStrokePath(context);
    CGColorRelease(color);
}

#pragma mark - Artwork

// The badge sits low and left; the ripple it pushes outwards closes around it,
// and the badge itself is already breaking up into bubbles drifting up and
// right. Every coordinate is a share of the side, so the same drawing reads the
// same at any size.
static void FIZZDrawArtwork(CGContextRef context, CGFloat side)
{
    static const CGFloat gradientComponents[8] = {
        0.42, 0.29, 0.96, 1.00,
        0.05, 0.72, 0.85, 1.00,
    };
    static const CGFloat gradientLocations[2] = { 0.0, 1.0 };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, gradientComponents,
                                                                 gradientLocations, 2);
    CGColorSpaceRelease(space);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 0), CGPointMake(side, side), 0);
    CGGradientRelease(gradient);

    CGPoint center = CGPointMake(side * 0.45, side * 0.45);

    static const CGFloat ringRadii[3] = { 0.21, 0.29, 0.37 };
    static const CGFloat ringAlphas[3] = { 0.90, 0.55, 0.28 };
    for (NSUInteger index = 0; index < 3; index++) {
        FIZZStrokeCircle(context, center, side * ringRadii[index], side * 0.020, ringAlphas[index]);
    }

    FIZZFillCircle(context, center, side * 0.125, 1.00, 0.27, 0.23, 1.00);
    FIZZStrokeCircle(context, center, side * 0.125, side * 0.012, 0.90);

    // Bubbles: horizontal and vertical offset from the badge, radius, alpha.
    static const CGFloat bubbles[5][3] = {
        { 0.170, 0.220, 0.048 },
        { 0.270, 0.310, 0.032 },
        { 0.350, 0.200, 0.020 },
        { 0.100, 0.330, 0.022 },
        { 0.220, 0.100, 0.016 },
    };
    static const CGFloat bubbleAlphas[5] = { 0.95, 0.70, 0.50, 0.55, 0.40 };
    for (NSUInteger index = 0; index < 5; index++) {
        CGPoint point = CGPointMake(center.x + side * bubbles[index][0],
                                    center.y + side * bubbles[index][1]);
        FIZZFillCircle(context, point, side * bubbles[index][2], 1, 1, 1, bubbleAlphas[index]);
    }
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
    printf("sample %-8s rgba %3u %3u %3u %3u\n", label, pixel[0], pixel[1], pixel[2], pixel[3]);
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

        // Orientation and corner check on the largest icon: the badge centre
        // must sit in the middle of the icon and the outermost corner must be
        // fully transparent, otherwise the mask or the flip is wrong.
        CGContextRef probe = FIZZCreateContext(87.0);
        CGImageRef probeIcon = FIZZCreateRoundedIcon(master, 87.0);
        CGContextDrawImage(probe, CGRectMake(0, 0, 87, 87), probeIcon);
        CGImageRelease(probeIcon);
        FIZZSamplePixel(probe, 87.0, 0.45, 0.45, "badge");
        FIZZSamplePixel(probe, 87.0, 0.72, 0.24, "bubble");
        FIZZSamplePixel(probe, 87.0, 0.72, 0.76, "bubble-flip");
        FIZZSamplePixel(probe, 87.0, 0.01, 0.01, "corner");
        CGContextRelease(probe);

        CGImageRelease(master);
    }
    return 0;
}
