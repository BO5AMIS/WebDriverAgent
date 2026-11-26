/**
 * Tapwright: the text on the screen, read from a screenshot on the device (route version 9).
 *
 * GET /wda/tw/ocr?level=fast|accurate&languages=en-US,ar-SA   (and GET /session/:sessionId/wda/tw/ocr)
 *   level      "accurate" (the default) or "fast". "fast" also turns Vision's language correction off.
 *   languages  optional, comma-separated BCP 47 codes in order of preference (Vision's recognitionLanguages); when
 *              absent Vision uses its own default (English). Which languages a level supports is Vision's business:
 *              an unsupported one fails the read (see Errors).
 *   A screenshot is taken the way GET /screenshot takes it (XCTest's daemon, no accessibility question to any app),
 *   and Apple Vision's VNRecognizeTextRequest reads it:
 *     {"screen": [w, h], "ms": {"shot": n, "ocr": n}, "level": "fast"|"accurate",
 *      "lines": [{"text": "...", "rect": [x, y, width, height], "confidence": c}, ...]}
 *   screen  the screen in points as the picture shows it upright (landscape when the interface is: iOS stores the
 *           screenshot portrait and says how to turn it in the image's metadata, which is honoured here);
 *   rect    in those points, top-left origin, rounded to 0.1 (Vision's boxes are normalised with a bottom-left
 *           origin; they are converted);
 *   confidence  Vision's, 0-1, for the line's best candidate.
 *   Lines are sorted top to bottom, then left to right.
 *   Errors: "invalid argument" for a level other than fast/accurate or an empty language; "unable to capture screen"
 *   when the screenshot fails; otherwise an "unknown error" whose message starts "tapwright ocr:" (Vision failed,
 *   e.g. an unsupported language); "unsupported operation" before iOS 13.
 *
 *   (version 11) `image=1` (also "true"; "0"/"false" or no `image` is the version 10 answer, unchanged), with
 *   `width` and `quality` as for GET /wda/tw/shot below: the answer also carries the very picture the text was read
 *   from, made as GET /wda/tw/shot makes it, and how long that took:
 *     {..., "jpeg": "<base64>", "size": [w, h], "ms": {"shot": n, "ocr": n, "encode": n}}
 *   Vision always reads the full-resolution screenshot; `width` only scales the picture that is sent. `width` and
 *   `quality` are not looked at without `image=1`. Errors: "invalid argument" for another `image`, a bad `width` or
 *   `quality`; an "unknown error" "tapwright ocr: the picture could not be encoded".
 *
 * GET /wda/tw/shot?width=<px>&quality=<1-100>   (and GET /session/:sessionId/wda/tw/shot)   (version 11)
 *   The screen as a JPEG, taken the way the OCR read takes it (XCTest's daemon, no accessibility question to any
 *   app), turned upright (the orientation iOS writes into the screenshot's metadata, as the OCR read honours it):
 *     {"jpeg": "<base64>", "size": [w, h], "screen": [w, h], "ms": {"shot": n, "encode": n}}
 *   width    pixels of the picture sent, a whole number; clamped to 120..the screenshot's own upright width; the
 *            height follows the screen's proportions (rounded). Default: the screenshot's own pixels.
 *   quality  JPEG quality, a whole number 1-100 (default 70).
 *   size     [w, h] in pixels of the picture sent; screen  [w, h] the screen in points, upright (as the OCR read's);
 *   ms       shot: the daemon's screenshot; encode: turning, scaling, encoding and base64.
 *   When nothing needs turning or scaling (portrait, no `width`), the daemon's own JPEG, taken at `quality`, is sent
 *   as it is (encode is then about the base64 alone). Otherwise the screenshot is taken at quality 80 or more and
 *   drawn upright at `size` (UIGraphicsImageRenderer, as FBImageProcessor scales the MJPEG stream), then encoded at
 *   `quality`.
 *   Errors: "invalid argument" for a `width` that isn't a whole number from 1 or a `quality` that isn't 1-100;
 *   "unable to capture screen" when the screenshot fails; an "unknown error" "tapwright shot: ..." when it can't
 *   be encoded.
 *
 * Every route runs on the main queue (FBWebServer), and so do these: the main thread is busy while Vision
 * reads (about 0.1-0.3 s "fast", 0.5-1.5 s "accurate" on a recent iPhone), or while a picture is encoded, and
 * nothing else is answered meanwhile.
 *
 * Kept in this one file so the fork rebases cleanly onto upstream.
 */

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Vision/Vision.h>

#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBScreen.h"
#import "FBScreenshot.h"
#import "XCUIScreen.h"

#if !TARGET_OS_TV && !TARGET_OS_WATCH

static const NSTimeInterval TWOcrShotTimeout = 10.0; // seconds the screenshot may take
static const CGFloat TWOcrShotQuality = 0.8; // JPEG: smaller and quicker than PNG, and plenty for text
static const NSInteger TWShotDefaultQuality = 70; // (version 11) of the picture sent, 1-100
static const NSInteger TWShotMinWidth = 120; // pixels: the narrowest picture sent
static const NSInteger TWShotRedrawnQuality = 80; // the least quality a screenshot that is redrawn is taken at

NS_ASSUME_NONNULL_BEGIN

@interface TWOcrCommands : NSObject <FBCommandHandler>
@end

NS_ASSUME_NONNULL_END

/** Milliseconds between two systemUptime readings, rounded. */
static NSNumber *TWOcrMilliseconds(NSTimeInterval from, NSTimeInterval to)
{
  return @(round((to - from) * 1000.0));
}

/** A coordinate rounded to 0.1 point. */
static NSNumber *TWOcrTenth(CGFloat value)
{
  double v = (double)value;
  return @(isfinite(v) ? round(v * 10.0) / 10.0 : 0.0);
}

@implementation TWOcrCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/tw/ocr"] respondWithTarget:self action:@selector(handleOcr:)],
    [[FBRoute GET:@"/wda/tw/ocr"].withoutSession respondWithTarget:self action:@selector(handleOcr:)],
    [[FBRoute GET:@"/wda/tw/shot"] respondWithTarget:self action:@selector(handleShot:)],
    [[FBRoute GET:@"/wda/tw/shot"].withoutSession respondWithTarget:self action:@selector(handleShot:)],
  ];
}

#pragma mark - The picture's parameters and size (pure, unit tested; version 11)

/** A whole number from `min` to `max`, from a query string ("400") or a JSON number (400, not 400.5); nil for
 *  anything else. */
+ (nullable NSNumber *)wholeNumberFrom:(nullable id)value min:(long long)min max:(long long)max
{
  long long number = 0;
  if ([value isKindOfClass:NSString.class]) {
    NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
    if (![scanner scanLongLong:&number] || !scanner.isAtEnd) {
      return nil;
    }
  } else if ([value isKindOfClass:NSNumber.class]) {
    double real = [(NSNumber *)value doubleValue];
    if (!(isfinite(real) && real >= (double)min && real <= (double)max && real == floor(real))) {
      return nil;
    }
    number = (long long)real;
  } else {
    return nil;
  }
  return (number >= min && number <= max) ? @(number) : nil;
}

/** The `width` parameter: 0 (the screenshot's own width) when absent, else a whole number of pixels from 1 (it is
 *  clamped later, by +sentSizeOf:width:); nil when it is something else. */
+ (nullable NSNumber *)pictureWidthFrom:(nullable id)value
{
  return nil == value ? @0 : [self wholeNumberFrom:value min:1 max:(long long)INT_MAX];
}

/** The `quality` parameter: 70 when absent, else a whole number 1-100; nil when it is something else. */
+ (nullable NSNumber *)pictureQualityFrom:(nullable id)value
{
  return nil == value ? @(TWShotDefaultQuality) : [self wholeNumberFrom:value min:1 max:100];
}

/** The OCR read's `image`: NO when absent, "1"/"true" (any case) or the number 1 YES, "0"/"false" or 0 NO; nil for
 *  anything else. */
+ (nullable NSNumber *)imageFlagFrom:(nullable id)value
{
  if (nil == value) {
    return @NO;
  }
  if ([value isKindOfClass:NSString.class]) {
    NSString *text = [(NSString *)value lowercaseString];
    if ([text isEqualToString:@"1"] || [text isEqualToString:@"true"]) {
      return @YES;
    }
    if ([text isEqualToString:@"0"] || [text isEqualToString:@"false"]) {
      return @NO;
    }
    return nil;
  }
  NSNumber *number = [self wholeNumberFrom:value min:0 max:1];
  if (nil == number) {
    return nil;
  }
  return 1 == number.longLongValue ? @YES : @NO;
}

/** The pixel size of the picture sent for an upright screenshot of `upright` pixels: `width` (0: the screenshot's
 *  own) clamped to 120..the screenshot's width, the height in the same proportion, rounded, at least 1. */
+ (CGSize)sentSizeOf:(CGSize)upright width:(NSInteger)width
{
  double fullWidth = round((double)upright.width);
  double fullHeight = round((double)upright.height);
  if (!(isfinite(fullWidth) && isfinite(fullHeight) && fullWidth >= 1 && fullHeight >= 1)) {
    return CGSizeZero;
  }
  if (width <= 0) {
    return CGSizeMake((CGFloat)fullWidth, (CGFloat)fullHeight);
  }
  double sentWidth = MIN(MAX((double)width, (double)TWShotMinWidth), fullWidth);
  double sentHeight = MAX(round(fullHeight * sentWidth / fullWidth), 1.0);
  return CGSizeMake((CGFloat)sentWidth, (CGFloat)sentHeight);
}

/** The quality (1-100) a screenshot is asked for: the picture's own when it is sent as taken (no `width`), else
 *  at least TWShotRedrawnQuality, so that the picture is not made lossy twice at a low quality. */
+ (NSInteger)shotQualityFor:(NSInteger)quality width:(NSInteger)width
{
  return width <= 0 ? quality : MAX(quality, TWShotRedrawnQuality);
}

#pragma mark - The picture (version 11)

/**
 * The JPEG sent for the screenshot `image` (decoded from `data`, which the daemon encoded at `shotQuality`, 1-100):
 * `data` itself when it is already upright, `size` pixels and of `quality`; else the picture drawn upright at
 * `size` the way FBImageProcessor scales the MJPEG stream (UIGraphicsImageRenderer drawing the UIImage, whose
 * imageOrientation, read from the screenshot's metadata, turns it upright), at one pixel per point so that `size`
 * is in pixels, and encoded at `quality`. nil when it can't be made.
 */
+ (nullable NSData *)jpegOf:(UIImage *)image
                       data:(NSData *)data
                shotQuality:(NSInteger)shotQuality
                       size:(CGSize)size
                    quality:(NSInteger)quality
{
  CGImageRef picture = image.CGImage;
  if (NULL == picture || size.width < 1 || size.height < 1) {
    return nil;
  }
  BOOL isAsTaken = UIImageOrientationUp == image.imageOrientation
    && (size_t)size.width == CGImageGetWidth(picture)
    && (size_t)size.height == CGImageGetHeight(picture)
    && shotQuality == quality;
  if (isAsTaken) {
    return data;
  }
  UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
  format.scale = 1;
  format.opaque = YES;
  format.preferredRange = UIGraphicsImageRendererFormatRangeStandard; // 8 bits a channel: JPEG has no more
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
  return [renderer JPEGDataWithCompressionQuality:(CGFloat)quality / 100
                                          actions:^(UIGraphicsImageRendererContext * _Nonnull context) {
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
  }];
}

+ (id<FBResponsePayload>)handleShot:(FBRouteRequest *)request
{
  NSNumber *width = [self pictureWidthFrom:request.parameters[@"width"]];
  if (nil == width) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"width must be a whole number of pixels (it is clamped to 120..the screen's width)"
                                                                       traceback:nil]);
  }
  NSNumber *quality = [self pictureQualityFrom:request.parameters[@"quality"]];
  if (nil == quality) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"quality must be a whole number from 1 to 100"
                                                                       traceback:nil]);
  }

  NSError *error = nil;
  XCUIScreen *screen = [FBScreen currentScreenWithError:&error];
  if (nil == screen) {
    return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.localizedDescription ?: @"the screen can't be told"
                                                                             traceback:nil]);
  }
  NSInteger shotQuality = [self shotQualityFor:quality.integerValue width:width.integerValue];
  NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
  NSData *data = [FBScreenshot takeInOriginalResolutionWithScreenID:screen.displayID
                                                 compressionQuality:(CGFloat)shotQuality / 100
                                                                uti:UTTypeJPEG
                                                            timeout:TWOcrShotTimeout
                                                              error:&error];
  NSTimeInterval shot = NSProcessInfo.processInfo.systemUptime;
  UIImage *image = nil == data ? nil : [UIImage imageWithData:(NSData *)data];
  CGImageRef picture = image.CGImage;
  if (nil == image || NULL == picture) {
    return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.localizedDescription ?: @"the screenshot could not be read"
                                                                             traceback:nil]);
  }

  CGSize pixels = CGSizeMake((CGFloat)CGImageGetWidth(picture), (CGFloat)CGImageGetHeight(picture));
  CGSize upright = [self uprightSizeOf:pixels orientation:image.imageOrientation];
  CGSize points = [self pointSizeOf:upright scale:screen.scale];
  CGSize size = [self sentSizeOf:upright width:width.integerValue];
  NSData *jpeg = [self jpegOf:(UIImage *)image
                         data:(NSData *)data
                  shotQuality:shotQuality
                         size:size
                      quality:quality.integerValue];
  NSString *encoded = [jpeg base64EncodedStringWithOptions:0];
  NSTimeInterval done = NSProcessInfo.processInfo.systemUptime;
  if (nil == encoded) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"tapwright shot: the picture could not be encoded"
                                                               traceback:nil]);
  }
  return FBResponseWithObject(@{
    @"jpeg": (NSString *)encoded,
    @"size": @[@((NSInteger)size.width), @((NSInteger)size.height)],
    @"screen": @[TWOcrTenth(points.width), TWOcrTenth(points.height)],
    @"ms": @{@"shot": TWOcrMilliseconds(began, shot), @"encode": TWOcrMilliseconds(shot, done)},
  });
}

/** The upright screenshot's size in points: pixels / the screen's scale (1 when the scale isn't a positive
 *  number). */
+ (CGSize)pointSizeOf:(CGSize)upright scale:(double)scale
{
  if (!(isfinite(scale) && scale > 0)) {
    scale = 1;
  }
  return CGSizeMake((CGFloat)((double)upright.width / scale), (CGFloat)((double)upright.height / scale));
}

#pragma mark - Geometry (pure, unit tested)

/** The orientation Vision is told for a picture UIKit shows with `orientation` (the same numbering as EXIF's). */
+ (CGImagePropertyOrientation)propertyOrientationOf:(UIImageOrientation)orientation
{
  switch (orientation) {
    case UIImageOrientationUp:
      return kCGImagePropertyOrientationUp;
    case UIImageOrientationDown:
      return kCGImagePropertyOrientationDown;
    case UIImageOrientationLeft:
      return kCGImagePropertyOrientationLeft;
    case UIImageOrientationRight:
      return kCGImagePropertyOrientationRight;
    case UIImageOrientationUpMirrored:
      return kCGImagePropertyOrientationUpMirrored;
    case UIImageOrientationDownMirrored:
      return kCGImagePropertyOrientationDownMirrored;
    case UIImageOrientationLeftMirrored:
      return kCGImagePropertyOrientationLeftMirrored;
    case UIImageOrientationRightMirrored:
      return kCGImagePropertyOrientationRightMirrored;
  }
  return kCGImagePropertyOrientationUp;
}

/** The picture's size once it is turned upright: width and height swap for the four turned orientations. */
+ (CGSize)uprightSizeOf:(CGSize)size orientation:(UIImageOrientation)orientation
{
  switch (orientation) {
    case UIImageOrientationLeft:
    case UIImageOrientationRight:
    case UIImageOrientationLeftMirrored:
    case UIImageOrientationRightMirrored:
      return CGSizeMake(size.height, size.width);
    case UIImageOrientationUp:
    case UIImageOrientationDown:
    case UIImageOrientationUpMirrored:
    case UIImageOrientationDownMirrored:
      return size;
  }
  return size;
}

/** A Vision box (normalised to 0-1, bottom-left origin, in the upright picture) in points of a screen of `size`
 *  points, top-left origin. */
+ (CGRect)screenRectOfNormalizedBox:(CGRect)box inSize:(CGSize)size
{
  return CGRectMake(box.origin.x * size.width,
                    (1 - box.origin.y - box.size.height) * size.height,
                    box.size.width * size.width,
                    box.size.height * size.height);
}

#pragma mark - The route

+ (nullable NSArray<NSString *> *)languagesFrom:(nullable id)value valid:(BOOL *)valid
{
  *valid = YES;
  if (nil == value) {
    return nil;
  }
  if (![value isKindOfClass:NSString.class]) {
    *valid = NO;
    return nil;
  }
  NSMutableArray<NSString *> *languages = [NSMutableArray array];
  for (NSString *part in [(NSString *)value componentsSeparatedByString:@","]) {
    NSString *language = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (0 == language.length) {
      *valid = NO;
      return nil;
    }
    [languages addObject:language];
  }
  return languages.copy;
}

+ (id<FBResponsePayload>)handleOcr:(FBRouteRequest *)request
{
  id levelValue = request.parameters[@"level"];
  if (nil != levelValue && !([levelValue isKindOfClass:NSString.class]
                             && ([levelValue isEqualToString:@"fast"] || [levelValue isEqualToString:@"accurate"]))) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"level must be fast or accurate"
                                                                       traceback:nil]);
  }
  BOOL isFast = [levelValue isKindOfClass:NSString.class] && [levelValue isEqualToString:@"fast"];
  BOOL isValid = YES;
  NSArray<NSString *> *languages = [self languagesFrom:request.parameters[@"languages"] valid:&isValid];
  if (!isValid) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"languages must be comma-separated language codes, e.g. en-US,ar-SA"
                                                                       traceback:nil]);
  }
  // (version 11) the picture the text is read from, only when asked; `width` and `quality` only matter then
  NSNumber *wantsImage = [self imageFlagFrom:request.parameters[@"image"]];
  if (nil == wantsImage) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"image must be 1 or 0"
                                                                       traceback:nil]);
  }
  NSNumber *width = @0;
  NSNumber *quality = @(TWShotDefaultQuality);
  if (wantsImage.boolValue) {
    width = [self pictureWidthFrom:request.parameters[@"width"]];
    if (nil == width) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"width must be a whole number of pixels (it is clamped to 120..the screen's width)"
                                                                         traceback:nil]);
    }
    quality = [self pictureQualityFrom:request.parameters[@"quality"]];
    if (nil == quality) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"quality must be a whole number from 1 to 100"
                                                                         traceback:nil]);
    }
  }
  if (@available(iOS 13.0, *)) {
    return [self readWithFastLevel:isFast
                         languages:languages
                        wantsImage:wantsImage.boolValue
                             width:width.integerValue
                           quality:quality.integerValue];
  }
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"tapwright ocr: text recognition needs iOS 13 or later"
                                                                          traceback:nil]);
}

+ (id<FBResponsePayload>)readWithFastLevel:(BOOL)isFast
                                 languages:(nullable NSArray<NSString *> *)languages
                                wantsImage:(BOOL)wantsImage
                                     width:(NSInteger)width
                                   quality:(NSInteger)quality
{
  // (only called behind @available(iOS 13.0, *); the deployment target is iOS 15 anyway)
  NSError *error = nil;
  XCUIScreen *screen = [FBScreen currentScreenWithError:&error];
  if (nil == screen) {
    return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.localizedDescription ?: @"the screen can't be told"
                                                                             traceback:nil]);
  }
  NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
  NSData *data = [FBScreenshot takeInOriginalResolutionWithScreenID:screen.displayID
                                                 compressionQuality:TWOcrShotQuality
                                                                uti:UTTypeJPEG
                                                            timeout:TWOcrShotTimeout
                                                              error:&error];
  NSTimeInterval shot = NSProcessInfo.processInfo.systemUptime;
  UIImage *image = nil == data ? nil : [UIImage imageWithData:(NSData *)data];
  CGImageRef picture = image.CGImage;
  if (NULL == picture) {
    return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.localizedDescription ?: @"the screenshot could not be read"
                                                                             traceback:nil]);
  }

  UIImageOrientation imageOrientation = image.imageOrientation;
  CGSize pixels = CGSizeMake((CGFloat)CGImageGetWidth(picture), (CGFloat)CGImageGetHeight(picture));
  CGSize upright = [self uprightSizeOf:pixels orientation:imageOrientation];
  double scale = screen.scale;
  if (!(isfinite(scale) && scale > 0)) {
    scale = 1;
  }
  CGSize points = CGSizeMake((CGFloat)((double)upright.width / scale), (CGFloat)((double)upright.height / scale));

  VNRecognizeTextRequest *recognition = [[VNRecognizeTextRequest alloc] init];
  recognition.recognitionLevel = isFast ? VNRequestTextRecognitionLevelFast : VNRequestTextRecognitionLevelAccurate;
  recognition.usesLanguageCorrection = !isFast;
  if (nil != languages) {
    recognition.recognitionLanguages = (NSArray<NSString *> *)languages;
  }
  // (version 12) A turned screenshot is drawn upright first, the way the JPEG that is sent is drawn, and Vision
  // reads that picture as it is. Told the screenshot's orientation instead, Vision found the text in the right
  // places but read it upside down in both landscape turns (iPhone 14 Pro Max, iOS 26.5: Calculator's "789" came
  // back as "68L"). Only a turned screenshot pays for the drawing.
  // (version 13) Version 12's drawing fixed one landscape turn and not the other (the same pixels on screen). Now
  // the upright picture is made as the one that is sent (a JPEG drawn by jpegOf, proven upright in both turns by
  // reading it on a computer) and decoded again, so Vision reads those very pixels, with no orientation to be told.
  // `turn` in the answer says what the screenshot's orientation was and how it was read (0 as taken, 1 from the
  // upright JPEG, 2 from the drawing when that JPEG couldn't be made).
  CGImageRef toRead = picture;
  CGImagePropertyOrientation toldOrientation = [self propertyOrientationOf:imageOrientation];
  UIImage *turned = nil;
  NSInteger howRead = 0;
  if (UIImageOrientationUp != imageOrientation && upright.width >= 1 && upright.height >= 1) {
    NSData *uprightData = [self jpegOf:(UIImage *)image
                                  data:(NSData *)data
                           shotQuality:-1
                                  size:upright
                               quality:92];
    turned = nil == uprightData ? nil : [UIImage imageWithData:(NSData *)uprightData];
    if (NULL != turned.CGImage && UIImageOrientationUp == turned.imageOrientation) {
      toRead = turned.CGImage;
      toldOrientation = kCGImagePropertyOrientationUp;
      howRead = 1;
    } else {
      UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
      format.scale = 1;
      format.opaque = YES;
      format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
      UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:upright format:format];
      turned = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [image drawInRect:CGRectMake(0, 0, upright.width, upright.height)];
      }];
      if (NULL != turned.CGImage) {
        toRead = turned.CGImage;
        toldOrientation = kCGImagePropertyOrientationUp;
        howRead = 2;
      }
    }
  }
  NSArray<NSNumber *> *turn = @[@((NSInteger)imageOrientation), @(howRead)];
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:toRead
                                                                      orientation:toldOrientation
                                                                          options:@{}];
  NSError *visionError = nil;
  BOOL isRead = NO;
  @try {
    isRead = [handler performRequests:@[recognition] error:&visionError];
  } @catch (NSException *e) {
    // Vision raises for some bad parameters (e.g. a language list it can't take) instead of failing
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:[NSString stringWithFormat:@"tapwright ocr: %@", e.reason ?: e.name]
                                                               traceback:nil]);
  }
  NSTimeInterval read = NSProcessInfo.processInfo.systemUptime;
  if (!isRead) {
    NSString *why = visionError.localizedDescription ?: @"Vision could not read the screenshot";
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:[NSString stringWithFormat:@"tapwright ocr: %@", why]
                                                               traceback:nil]);
  }

  NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
  NSArray *results = recognition.results;
  for (id result in results) {
    if (![result isKindOfClass:VNRecognizedTextObservation.class]) {
      continue;
    }
    VNRecognizedTextObservation *observation = (VNRecognizedTextObservation *)result;
    VNRecognizedText *best = [observation topCandidates:1].firstObject;
    if (nil == best || 0 == best.string.length) {
      continue;
    }
    CGRect rect = [self screenRectOfNormalizedBox:observation.boundingBox inSize:points];
    [lines addObject:@{
      @"text": best.string,
      @"rect": @[TWOcrTenth(rect.origin.x), TWOcrTenth(rect.origin.y),
                 TWOcrTenth(rect.size.width), TWOcrTenth(rect.size.height)],
      @"confidence": @(round((double)best.confidence * 1000.0) / 1000.0),
    }];
  }
  [lines sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSArray<NSNumber *> *a = first[@"rect"];
    NSArray<NSNumber *> *b = second[@"rect"];
    NSComparisonResult byTop = [a[1] compare:b[1]];
    return NSOrderedSame == byTop ? [a[0] compare:b[0]] : byTop;
  }];

  if (!wantsImage) {
    // exactly the version 10 answer
    return FBResponseWithObject(@{
      @"screen": @[TWOcrTenth(points.width), TWOcrTenth(points.height)],
      @"ms": @{@"shot": TWOcrMilliseconds(began, shot), @"ocr": TWOcrMilliseconds(shot, read)},
      @"level": isFast ? @"fast" : @"accurate",
      @"lines": lines.copy,
      @"turn": turn,
    });
  }

  // (version 11) the very screenshot Vision read, sent as GET /wda/tw/shot sends its picture
  NSTimeInterval encoding = NSProcessInfo.processInfo.systemUptime;
  CGSize size = [self sentSizeOf:upright width:width];
  NSData *jpeg = [self jpegOf:(UIImage *)image
                         data:(NSData *)data
                  shotQuality:(NSInteger)round(TWOcrShotQuality * 100)
                         size:size
                      quality:quality];
  NSString *encoded = [jpeg base64EncodedStringWithOptions:0];
  NSTimeInterval done = NSProcessInfo.processInfo.systemUptime;
  if (nil == encoded) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"tapwright ocr: the picture could not be encoded"
                                                               traceback:nil]);
  }
  return FBResponseWithObject(@{
    @"screen": @[TWOcrTenth(points.width), TWOcrTenth(points.height)],
    @"ms": @{@"shot": TWOcrMilliseconds(began, shot), @"ocr": TWOcrMilliseconds(shot, read),
             @"encode": TWOcrMilliseconds(encoding, done)},
    @"turn": turn,
    @"level": isFast ? @"fast" : @"accurate",
    @"lines": lines.copy,
    @"jpeg": (NSString *)encoded,
    @"size": @[@((NSInteger)size.width), @((NSInteger)size.height)],
  });
}

@end

#endif
