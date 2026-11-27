/**
 * Tapwright: what a touch at a point lands on (route version 6; the lookup under an accessibility timeout: 16).
 *
 * GET /wda/tw/hit?x=<x>&y=<y>[&how=client|daemon]   (and GET /session/:sessionId/wda/tw/hit)
 *   x, y   the point, in portrait screen points (what POST /wda/tw/tap takes).
 *   how    (version 16) "client" (the default): the accessibility client of this process is asked for the element at
 *          the point (-[XCAXClient_iOS accessibilityElementForElementAtPoint:error:]) with the AX timeout set to
 *          TWHitAskTimeout (-[FBXCAXClientProxy withAXTimeout:do:error:]): the request is bounded and over when the
 *          route answers. "daemon": the version 6 way, kept for measuring (below). A runner whose XCTest lacks the
 *          client's lookup, or where the timeout can't be set, asks the daemon way and says so ("how": "daemon").
 *   The accessibility element iOS finds at that point, which is what a touch there is delivered to, with the values
 *   the compact tree (TWTreeCommands.m) gives the same element:
 *     {"t": the element type without "XCUIElementType", "n": name, "l": label, "r": [x, y, width, height],
 *      "pid": its application's process id, "b": that application's bundle id,
 *      "via": "element" | "app", "identity": "verified", "ms": {"hit": n, "read": n}, "how": "client" | "daemon"}
 *   "n", "l" and "b" are left out when there is none.
 *   How ("daemon"): XCTest's daemon is asked for the element at the point (_XCT_requestElementAtPoint, the question
 *   WDA's own active application detection asks: FBActiveAppDetectionPoint), waiting at most 0.3 s. Nothing bounds
 *   that request itself: when the app at the point doesn't answer, it stays with the accessibility server at the
 *   default AX timeout (60 s) and every accessibility question asked after it waits behind it (the phone, 2026-11-28:
 *   a video app's feed held it for more than 80 s; the line to the runner was then lost). Its values are read from a
 *   snapshot of that one element ("element"); when that can't be had, from a snapshot of its application, where it is
 *   found by its accessibility identity ("app"). Each snapshot may take at most TWHitReadTimeout seconds.
 *   Errors: "invalid argument" for a point that isn't two finite numbers; otherwise an "unsupported operation" error
 *   whose message starts "tapwright hit:" when nothing could be told (no element answered, or its values couldn't be
 *   read). A version-6 client refuses every failed proof; it never continues unchecked. (Version 16) "no element
 *   answered at the point" is followed by the lookup's own time and way, and the underlying error's short name when
 *   there was one: "tapwright hit: no element answered at the point (hit 304 ms, client, kAXErrorIPCTimeout)". The
 *   client judges by that time ("the app didn't answer in time" against "nothing is there right now"), not by its
 *   own clock across the link.
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
// (version 16) seconds the point lookup may take: the daemon way's own wait, now the accessibility request's timeout
static const NSTimeInterval TWHitAskTimeout = 0.3;
static NSString *const TWHitRefused = @"tapwright hit:";
static NSString *const TWHitNothing = @"no element answered at the point";

// (version 16) shared with the unit tests and the tree route (TWTreeCommands.m)
NSString *_Nullable TWShortErrorName(NSError *_Nullable error);
NSString *TWNothingWhy(NSNumber *milliseconds, NSString *how, NSString *_Nullable errorName);
id<FBXCAccessibilityElement> _Nullable TWElementAtPoint(CGPoint point, NSString *_Nullable __autoreleasing *_Nullable how);

NS_ASSUME_NONNULL_BEGIN

@interface TWHitCommands : NSObject <FBCommandHandler>
@end

NS_ASSUME_NONNULL_END

/** Milliseconds between two CFAbsoluteTime readings, rounded. */
static NSNumber *TWMilliseconds(CFAbsoluteTime from, CFAbsoluteTime to)
{
  return @(round((to - from) * 1000.0));
}

/**
 * (version 16) The short name of the error a point lookup gave: the "kAXError..." name in its description when there
 * is one (what the tree route's reasons show), else "domain code"; nil without an error.
 */
NSString *_Nullable TWShortErrorName(NSError *_Nullable error)
{
  if (nil == error) {
    return nil;
  }
  NSString *text = error.localizedDescription ?: @"";
  NSRange found = [text rangeOfString:@"kAXError[A-Za-z]+" options:NSRegularExpressionSearch];
  if (NSNotFound != found.location) {
    return [text substringWithRange:found];
  }
  return [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code];
}

/** (version 16) The words of a lookup that found nothing: the version 6 words first, then the time and the way. */
NSString *TWNothingWhy(NSNumber *milliseconds, NSString *how, NSString *_Nullable errorName)
{
  return nil == errorName
    ? [NSString stringWithFormat:@"%@ (hit %@ ms, %@)", TWHitNothing, milliseconds, how]
    : [NSString stringWithFormat:@"%@ (hit %@ ms, %@, %@)", TWHitNothing, milliseconds, how, errorName];
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
  NSString *how = [self howFrom:request.parameters[@"how"]];

  CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
  id<FBXCAccessibilityElement> hit = nil;
  NSString *errorName = nil;
  @try {
    hit = [self elementAt:point how:&how errorName:&errorName];
  } @catch (NSException *e) {
    return [self refuse:[NSString stringWithFormat:@"the element at the point can't be asked for (%@)", e.reason ?: e.name]];
  }
  CFAbsoluteTime asked = CFAbsoluteTimeGetCurrent();
  if (nil == hit) {
    return [self refuse:TWNothingWhy(TWMilliseconds(began, asked), how, errorName)];
  }

  int pid = hit.processIdentifier;
  XCUIApplication *application = pid > 0
    ? [[FBXCAXClientProxy sharedClient] monitoredApplicationWithProcessIdentifier:pid]
    : nil;
  NSString *via = nil;
  id<FBXCElementSnapshot> snapshot = [self verifiedSnapshotOf:hit inApplication:application via:&via];
  CFAbsoluteTime readAt = CFAbsoluteTimeGetCurrent();
  if (nil == snapshot) {
    // This fixed code is terminal in the companion Python client. An unbound snapshot must never be returned
    // with the original hit's pid/bundle, or treated as an unavailable optional hit test.
    return [self refuse:@"identity_unproven"];
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
  answer[@"identity"] = @"verified";
  answer[@"ms"] = @{@"hit": TWMilliseconds(began, asked), @"read": TWMilliseconds(asked, readAt)};
  answer[@"how"] = how;
  return FBResponseWithObject(answer.copy);
}

/** (version 16) TWNothingWhy and TWShortErrorName as class methods (what the unit tests reach, as with the rest). */
+ (NSString *)nothingWhyAfter:(NSNumber *)milliseconds how:(NSString *)how errorName:(nullable NSString *)errorName
{
  return TWNothingWhy(milliseconds, how, errorName);
}

+ (nullable NSString *)shortErrorName:(nullable NSError *)error
{
  return TWShortErrorName(error);
}

/** (version 16) The way a request asks: "daemon" when it says so, else "client". */
+ (NSString *)howFrom:(nullable id)value
{
  return [value isKindOfClass:NSString.class] && [(NSString *)value isEqualToString:@"daemon"] ? @"daemon" : @"client";
}

/**
 * (version 16) The element at the point, the way `how` says ("client" or "daemon"); `how` comes back as the way it
 * was asked: the client way falls back to the daemon way when this XCTest lacks the client's lookup or the AX timeout
 * can't be set (logged). `errorName`: the client lookup's error, when it said why nothing answered.
 */
+ (nullable id<FBXCAccessibilityElement>)elementAt:(CGPoint)point
                                               how:(NSString *_Nonnull __autoreleasing *_Nonnull)how
                                         errorName:(NSString *_Nullable __autoreleasing *_Nullable)errorName
{
  if (![*how isEqualToString:@"daemon"]) {
    BOOL asked = NO;
    id<FBXCAccessibilityElement> element = [self clientElementAt:point asked:&asked errorName:errorName];
    if (asked) {
      *how = @"client";
      return element;
    }
    [FBLogger logFmt:@"%@ the client's own point lookup can't be made here: asking XCTest's daemon", TWHitRefused];
  }
  *how = @"daemon";
  return [self daemonElementAt:point];
}

/**
 * (version 16) The client's own point lookup, inside -withAXTimeout:do:error: (TWHitAskTimeout), which waits for its
 * block: the request is over when this returns. `asked` NO (nothing asked) when the selector is missing or the timeout
 * couldn't be installed.
 */
+ (nullable id<FBXCAccessibilityElement>)clientElementAt:(CGPoint)point
                                                   asked:(BOOL *)asked
                                               errorName:(NSString *_Nullable __autoreleasing *_Nullable)errorName
{
  FBXCAXClientProxy *client = [FBXCAXClientProxy sharedClient];
  if (![client tw_canAskElementAtPoint]) {
    return nil;
  }
  __block id<FBXCAccessibilityElement> element = nil;
  __block NSError *lookupError = nil;
  __block NSString *raised = nil;
  __block BOOL ran = NO;
  NSError *installError = nil;
  [client withAXTimeout:TWHitAskTimeout do:^{
    ran = YES;
    @try {
      NSError *error = nil;
      element = [client tw_elementAtPoint:point error:&error];
      lookupError = error;
    } @catch (NSException *e) {
      raised = e.name;
    }
  } error:&installError];
  if (!ran) {
    [FBLogger logFmt:@"%@ the AX timeout for the point lookup can't be set: %@", TWHitRefused, installError];
    return nil;
  }
  *asked = YES;
  if (nil == element && NULL != errorName) {
    *errorName = TWShortErrorName(lookupError) ?: raised;
  }
  return element;
}

/** The version 6 lookup (XCTest's daemon, 0.3 s of waiting, the request itself unbounded). */
+ (nullable id<FBXCAccessibilityElement>)daemonElementAt:(CGPoint)point
{
  return [FBActiveAppDetectionPoint axElementWithPoint:point];
}


/** Bind attributes to the same AX element AND process whose identity the point lookup returned. */
+ (BOOL)snapshot:(id<FBXCElementSnapshot>)snapshot matchesHit:(id<FBXCAccessibilityElement>)hit
{
  @try {
    return TWUsable(snapshot) && nil != snapshot.accessibilityElement
      && FBIsAXElementEqualToOther(snapshot.accessibilityElement, hit);
  } @catch (NSException *exception) {
    return NO;
  }
}

+ (nullable id<FBXCElementSnapshot>)verifiedSnapshotOf:(id<FBXCAccessibilityElement>)hit
                                        inApplication:(nullable XCUIApplication *)application
                                                  via:(NSString * _Nullable __autoreleasing *)via
{
  id<FBXCElementSnapshot> snapshot = nil;
  @try {
    snapshot = [self snapshotOfElement:hit];
  } @catch (NSException *exception) {
    // A failed direct read still has the exact-identity application-tree fallback.
  }
  if ([self snapshot:snapshot matchesHit:hit]) {
    *via = @"element";
    return snapshot;
  }
  @try {
    snapshot = nil == application ? nil : [self snapshotOf:hit inApplication:application];
  } @catch (NSException *exception) {
    snapshot = nil;
  }
  if ([self snapshot:snapshot matchesHit:hit]) {
    *via = @"app";
    return snapshot;
  }
  return nil;
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

/**
 * (version 16) The element at a point, the bounded way (the client's lookup, falling back to the daemon's): for the
 * front route's own point lookup (TWTreeCommands.m). `how` (may be NULL): the way it was asked.
 */
id<FBXCAccessibilityElement> _Nullable TWElementAtPoint(CGPoint point, NSString *_Nullable __autoreleasing *_Nullable how)
{
  NSString *way = @"client";
  id<FBXCAccessibilityElement> element = [TWHitCommands elementAt:point how:&way errorName:nil];
  if (NULL != how) {
    *how = way;
  }
  return element;
}

#endif
