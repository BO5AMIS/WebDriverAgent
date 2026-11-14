/**
 * Tapwright: what a touch at a point lands on (route version 5).
 *
 * GET /wda/tw/hit?x=<x>&y=<y>   (and GET /session/:sessionId/wda/tw/hit)
 *   x, y   the point, in portrait screen points (what POST /wda/tw/tap takes).
 *   The accessibility element iOS finds at that point, which is what a touch there is delivered to, with the values
 *   the compact tree (TWTreeCommands.m) gives the same element:
 *     {"t": the element type without "XCUIElementType", "n": name, "l": label, "r": [x, y, width, height],
 *      "pid": its application's process id, "b": that application's bundle id,
 *      "via": "element" | "app", "ms": {"hit": n, "read": n}}
 *   "n", "l" and "b" are left out when there is none.
 *   How: XCTest's daemon is asked for the element at the point (_XCT_requestElementAtPoint, the question WDA's own
 *   active application detection asks: FBActiveAppDetectionPoint), waiting at most 0.3 s. Its values are read from a
 *   snapshot of that one element ("element"); when that can't be had, from a snapshot of its application, where it is
 *   found by its accessibility identity ("app"). Each snapshot may take at most TWHitReadTimeout seconds.
 *   Errors: "invalid argument" for a point that isn't two finite numbers; otherwise an "unsupported operation" error
 *   whose message starts "tapwright hit:" when nothing could be told (no element answered, or its values couldn't be
 *   read). The client then touches without this check.
 *
 * Nothing here touches the phone or waits for the application to be idle.
 *
 * Kept in this one file so the fork rebases cleanly onto upstream.
 */

#import <Foundation/Foundation.h>

#import "FBActiveAppDetectionPoint.h"
#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBElementTypeTransformer.h"
#import "FBElementUtils.h"
#import "FBLogger.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCAXClientProxy.h"
#import "FBXCElementSnapshot.h"
#import "FBXCElementSnapshotWrapper.h"
#import "NSString+FBXMLSafeString.h"
#import "XCTestPrivateSymbols.h"
#import "XCUIApplication.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"

#if !TARGET_OS_TV && !TARGET_OS_WATCH

static const NSTimeInterval TWHitReadTimeout = 2.0; // seconds one snapshot (of the element, or of its app) may take
static NSString *const TWHitRefused = @"tapwright hit:";

NS_ASSUME_NONNULL_BEGIN

@interface TWHitCommands : NSObject <FBCommandHandler>
@end

NS_ASSUME_NONNULL_END

/** Milliseconds between two CFAbsoluteTime readings, rounded. */
static NSNumber *TWMilliseconds(CFAbsoluteTime from, CFAbsoluteTime to)
{
  return @(round((to - from) * 1000.0));
}

/** A string as /source writes it (and so the compact tree): without the characters XML 1.0 forbids. */
static NSString *_Nullable TWSafe(NSString *_Nullable string)
{
  return nil == string ? nil : [string fb_xmlSafeStringWithReplacement:@""];
}

/** Does the object answer what a snapshot is read for here? (A snapshot request may answer something else.) */
static BOOL TWLooksLikeSnapshot(id _Nullable object)
{
  return nil != object
    && [object respondsToSelector:@selector(elementType)]
    && [object respondsToSelector:@selector(frame)]
    && [object respondsToSelector:@selector(children)]
    && [object respondsToSelector:@selector(accessibilityElement)];
}

/** A snapshot with what this route sends: a real element type and a frame with an area. */
static BOOL TWUsable(id<FBXCElementSnapshot> _Nullable snapshot)
{
  if (!TWLooksLikeSnapshot(snapshot)) {
    return NO;
  }
  CGRect frame = snapshot.frame;
  return XCUIElementTypeAny != snapshot.elementType
    && isfinite(frame.origin.x) && isfinite(frame.origin.y)
    && isfinite(frame.size.width) && isfinite(frame.size.height)
    && frame.size.width > 0 && frame.size.height > 0;
}

@implementation TWHitCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/tw/hit"] respondWithTarget:self action:@selector(handleHit:)],
    [[FBRoute GET:@"/wda/tw/hit"].withoutSession respondWithTarget:self action:@selector(handleHit:)],
  ];
}

/** A query parameter as a finite number, or nil. */
+ (nullable NSNumber *)coordinate:(nullable id)value
{
  if ([value isKindOfClass:NSNumber.class]) {
    return isfinite([(NSNumber *)value doubleValue]) ? (NSNumber *)value : nil;
  }
  if (![value isKindOfClass:NSString.class]) {
    return nil;
  }
  NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
  double number = 0;
  if (![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number)) {
    return nil;
  }
  return @(number);
}

+ (id<FBResponsePayload>)refuse:(NSString *)why
{
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:[NSString stringWithFormat:@"%@ %@", TWHitRefused, why]
                                                                          traceback:nil]);
}

+ (id<FBResponsePayload>)handleHit:(FBRouteRequest *)request
{
  NSNumber *x = [self coordinate:request.parameters[@"x"]];
  NSNumber *y = [self coordinate:request.parameters[@"y"]];
  if (nil == x || nil == y) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"x and y must be finite numbers (screen points)"
                                                                       traceback:nil]);
  }
  CGPoint point = CGPointMake((CGFloat)x.doubleValue, (CGFloat)y.doubleValue);

  CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
  id<FBXCAccessibilityElement> hit = nil;
  @try {
    hit = [FBActiveAppDetectionPoint axElementWithPoint:point];
  } @catch (NSException *e) {
    return [self refuse:[NSString stringWithFormat:@"the element at the point can't be asked for (%@)", e.reason ?: e.name]];
  }
  CFAbsoluteTime asked = CFAbsoluteTimeGetCurrent();
  if (nil == hit) {
    return [self refuse:@"no element answered at the point"];
  }

  int pid = hit.processIdentifier;
  XCUIApplication *application = pid > 0
    ? [[FBXCAXClientProxy sharedClient] monitoredApplicationWithProcessIdentifier:pid]
    : nil;
  NSString *via = @"element";
  id<FBXCElementSnapshot> snapshot = [self snapshotOfElement:hit];
  if (!TWUsable(snapshot)) {
    via = @"app";
    snapshot = nil == application ? nil : [self snapshotOf:hit inApplication:application];
  }
  CFAbsoluteTime readAt = CFAbsoluteTimeGetCurrent();
  if (!TWUsable(snapshot)) {
    return [self refuse:@"the element at the point couldn't be read"];
  }

  FBXCElementSnapshotWrapper *element = [FBXCElementSnapshotWrapper ensureWrapped:(id<FBXCElementSnapshot>)snapshot];
  CGRect frame = element.wdFrame;
  NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithCapacity:8];
  answer[@"t"] = [FBElementTypeTransformer shortStringWithElementType:snapshot.elementType];
  NSString *name = TWSafe(element.wdName);
  if (nil != name) {
    answer[@"n"] = name;
  }
  NSString *label = TWSafe(element.wdLabel);
  if (nil != label) {
    answer[@"l"] = label;
  }
  answer[@"r"] = @[@((double)CGRectGetMinX(frame)), @((double)CGRectGetMinY(frame)),
                   @((double)CGRectGetWidth(frame)), @((double)CGRectGetHeight(frame))];
  answer[@"pid"] = @(pid);
  NSString *bundle = TWSafe(application.bundleID);
  if (bundle.length > 0) {
    answer[@"b"] = bundle;
  }
  answer[@"via"] = via;
  answer[@"ms"] = @{@"hit": TWMilliseconds(began, asked), @"read": TWMilliseconds(asked, readAt)};
  return FBResponseWithObject(answer.copy);
}

/** A snapshot of the element alone (it and its children), with XCTest's standard attributes; nil when it can't be
 *  had (those attribute names aren't known on this XCTest, the request failed, or it took too long). */
+ (nullable id<FBXCElementSnapshot>)snapshotOfElement:(id<FBXCAccessibilityElement>)hit
{
  Class snapshotClass = NSClassFromString(@"XCElementSnapshot");
  SEL names = @selector(sanitizedElementSnapshotHierarchyAttributesForAttributes:isMacOS:);
  if (nil == snapshotClass || ![snapshotClass respondsToSelector:names]) {
    return nil; // (FBStandardAttributeNames would assert or throw inside its dispatch_once)
  }
  NSArray<NSString *> *attributes = FBStandardAttributeNames();
  if (0 == attributes.count) {
    return nil;
  }
  __block id<FBXCElementSnapshot> snapshot = nil;
  BOOL inTime = [[FBXCAXClientProxy sharedClient] withAXTimeout:TWHitReadTimeout do:^{
    @try {
      NSError *error = nil;
      id result = [[FBXCAXClientProxy sharedClient] snapshotForElement:hit
                                                             attributes:attributes
                                                                inDepth:NO
                                                                  error:&error];
      if (TWLooksLikeSnapshot(result)) {
        snapshot = (id<FBXCElementSnapshot>)result;
      } else if (nil != error) {
        [FBLogger logFmt:@"%@ the element's own snapshot failed: %@", TWHitRefused, error.localizedDescription];
      }
    } @catch (NSException *e) {
      [FBLogger logFmt:@"%@ the element's own snapshot raised %@: %@", TWHitRefused, e.name, e.reason];
    }
  } error:nil];
  return inTime ? snapshot : nil;
}

/** The element in a snapshot of its application, found by its accessibility identity; nil when it isn't there. */
+ (nullable id<FBXCElementSnapshot>)snapshotOf:(id<FBXCAccessibilityElement>)hit
                                 inApplication:(XCUIApplication *)application
{
  __block id<FBXCElementSnapshot> root = nil;
  BOOL inTime = [[FBXCAXClientProxy sharedClient] withAXTimeout:TWHitReadTimeout do:^{
    @try {
      root = [application fb_standardSnapshot];
    } @catch (NSException *e) {
      [FBLogger logFmt:@"%@ the application's snapshot raised %@: %@", TWHitRefused, e.name, e.reason];
    }
  } error:nil];
  if (!inTime || !TWLooksLikeSnapshot(root)) {
    return nil;
  }
  NSMutableArray<id<FBXCElementSnapshot>> *stack = [NSMutableArray arrayWithObject:(id<FBXCElementSnapshot>)root];
  while (stack.count > 0) {
    id<FBXCElementSnapshot> node = stack.lastObject;
    [stack removeLastObject];
    id<FBXCAccessibilityElement> its = node.accessibilityElement;
    if (nil != its && FBIsAXElementEqualToOther(its, hit)) {
      return node;
    }
    NSArray<id<FBXCElementSnapshot>> *children = node.children;
    if (children.count > 0) {
      [stack addObjectsFromArray:children];
    }
  }
  return nil;
}

@end

#endif
