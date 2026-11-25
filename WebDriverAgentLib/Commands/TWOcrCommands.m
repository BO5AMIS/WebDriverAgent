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
 * Every route runs on the main queue (FBWebServer), and so does this one: the main thread is busy while Vision
 * reads (about 0.1-0.3 s "fast", 0.5-1.5 s "accurate" on a recent iPhone), and nothing else is answered meanwhile.
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
  ];
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
  if (@available(iOS 13.0, *)) {
    return [self readWithFastLevel:isFast languages:languages];
  }
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"tapwright ocr: text recognition needs iOS 13 or later"
                                                                          traceback:nil]);
}

+ (id<FBResponsePayload>)readWithFastLevel:(BOOL)isFast
                                 languages:(nullable NSArray<NSString *> *)languages
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
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:picture
                                                                      orientation:[self propertyOrientationOf:imageOrientation]
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

  return FBResponseWithObject(@{
    @"screen": @[TWOcrTenth(points.width), TWOcrTenth(points.height)],
    @"ms": @{@"shot": TWOcrMilliseconds(began, shot), @"ocr": TWOcrMilliseconds(shot, read)},
    @"level": isFast ? @"fast" : @"accurate",
    @"lines": lines.copy,
  });
}

@end

#endif
