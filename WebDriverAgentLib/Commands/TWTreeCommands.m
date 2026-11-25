/**
 * Tapwright: a compact read of the screen (route version 4), bounded in time (route version 9), and the screen's
 * size without reading any app (route version 9).
 *
 * GET /wda/tw/tree?since=<token>&budget=<ms>&path=<direct|xctest>   (and GET /session/:sessionId/wda/tw/tree)
 *   The tree that GET /source?format=xml&excluded_attributes=visible,accessible gives on the same path, read from the
 *   same application with the same attributes and the same attribute values, with only what Tapwright's list reads,
 *   as compact JSON:
 *     {"token": "<32 hex digits>", "tree": <node>, "tier": "full"|"shallow"|"root", "truncated": true|false,
 *      "why": "<why the tiers before this one gave nothing>" (only when there was such a tier),
 *      "ms": {"app": n, "wait": n, "snapshot": n, "build": n, "budget": n}}
 *   A node is {"t": the element type without "XCUIElementType", "v": value, "n": name, "l": label,
 *              "p": placeholderValue, "tr": traits, "r": [x, y, width, height], "d": 1 when it is not enabled,
 *              "c": [its children's nodes], and on an application "pid": its process id and "b": its bundle id;
 *              from version 5, "f": 1 on the element that has the keyboard focus (XCTest's hasKeyboardFocus)}.
 *   A key is left out where /source leaves the attribute out; "tr" also when the traits are empty, and "c" when there
 *   are no children. "r" is [0, 0, 0, 0] when a frame isn't finite (/source writes "nan" there, which reads as no
 *   frame). Strings are the ones /source writes: without the characters XML 1.0 forbids.
 *   `token` is a digest of the whole answer's tree (and of its tier when that isn't "full"). When `since` is that
 *   token nothing changed since that read, and the answer is
 *   {"token": <the same>, "unchanged": true, "tier": ..., "truncated": ..., "ms": {...}} without the tree.
 *   `ms` says where the time went: finding the application, the idle wait (none with animationCoolOffTimeout 0), the
 *   snapshots (all tiers tried), building this answer, and the budget that was used.
 *
 *   (version 9) The read answers within about `budget` milliseconds (clamped to 500-20000; anything that isn't a
 *   number is an "invalid argument" error). Without `budget` (a client older than version 9) the read is made the
 *   version 8 way: `path` "xctest" and the longest budget. In tiers:
 *     "full"     the whole tree (as deep as snapshotMaxDepth allows, as before), its accessibility request bounded
 *                to the first 60 % of the budget;
 *     "shallow"  when "full" failed or ran out of time: at most 15 levels deep and 20 children per element, with
 *                what is left of the budget but a reserve for "root";
 *     "root"     when that failed too: the application alone, {"t": "Application", "r": the screen's frame (as
 *                GET /wda/tw/screen gives it), "pid", "b"}, found without asking the app anything, so a frozen
 *                app is still named. When no application can be told at all, "pid" and "b" are left out.
 *   "truncated" is false for "full", true for "shallow" (elements may be missing below the limits) and for "root".
 *   `path` (default "direct") picks how the snapshot is asked for: "direct" asks XCTest's accessibility client for
 *   the application's tree in one request (droidrun's WebDriverAgent PR #43); "xctest" asks the way /source does
 *   (XCUIElement's snapshot), kept to compare the two on a device.
 *
 *   How the time is bounded. Each tier runs inside -[FBXCAXClientProxy withAXTimeout:do:error:] (as the hit route
 *   does), which sets XCTest's process-wide AXTimeout for the tier and puts the previous value back afterwards, so
 *   one accessibility request can't wait longer than its tier. XCTest's own retries can't multiply that wait:
 *   "direct" makes exactly one request (-[XCAXClient_iOS requestSnapshotForElement:...], no XCTest retry loop
 *   around it), and for both paths TWSetSnapshotRequestDeadline sets the tier's end as a deadline in WDA's swizzle
 *   of that request (XCAXClient_iOS+FBSnapshotReqParams.m), so any request made after it (an XCTest retry, or
 *   another request of the same read) fails at once without asking the app, and the #1210 responsiveness check
 *   (accessibilityDeadline) waits no longer than it. The "root" tier asks no accessibility question of the app:
 *   its application was found before the first tier (or, failing that, through XCTest's daemon, at most 0.3 s).
 *   Caveat (FBXCAXClientProxy.h): a request that timed out keeps running in the AX server, so the next read may
 *   wait behind it; it is bounded the same way, and the client sees "shallow" or "root" instead of a hang.
 *
 * GET /wda/tw/screen   (and GET /session/:sessionId/wda/tw/screen)   (version 9)
 *   The screen, read without asking any app:
 *     {"width": w, "height": h, "scale": s, "orientation": o, "source": "interface"|"device"|"unknown",
 *      "pixels": [pw, ph]}
 *   width and height are points in the current orientation (what /window/size gives for a full-screen app);
 *   pixels the screen's own size in pixels (portrait panel). orientation is the UIInterfaceOrientation (1 portrait,
 *   2 upside down, 3 landscape right, 4 landscape left; 0 when it can't be told, and then the size is portrait),
 *   from XCTest's daemon ("interface"), else from the device's orientation ("device").
 *   The size comes from XCUIScreen, as GET /wda/screen computes it (bounds / scale), never from the runner's own
 *   UIScreen: on a device the runner app is letterboxed (droidrun saw 320x480), so UIScreen.mainScreen.bounds is
 *   not the screen.
 *
 * GET /wda/tw/version answers 4 from this version on, 5 once "f" is sent (see TWFastTapCommands.m), 9 once the tree
 * is bounded and the screen and OCR routes exist.
 *
 * Kept in this one file so the fork rebases cleanly onto upstream.
 */

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "FBActiveAppDetectionPoint.h"
#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBConfiguration.h"
#import "FBElement.h"
#import "FBElementHelpers.h"
#import "FBElementTypeTransformer.h"
#import "FBLogger.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBRunLoopSpinner.h"
#import "FBSession.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCAXClientProxy.h"
#import "FBXCElementSnapshot.h"
#import "FBXCElementSnapshotWrapper.h"
#import "FBXPath.h"
#import "NSString+FBXMLSafeString.h"
#import "XCAXClient_iOS+FBSnapshotReqParams.h"
#import "XCTestPrivateSymbols.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIDevice.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCUIScreen.h"

static const NSUInteger TWTokenBytes = 16; // of the SHA-256 digest: 128 bits

static const double TWTreeDefaultBudgetMs = 3000;
static const double TWTreeMinBudgetMs = 500;
static const double TWTreeMaxBudgetMs = 20000;
static const double TWTreeFullShare = 0.6; // of the budget, for finding the app and the "full" tier
static const NSTimeInterval TWTreeMinTier = 0.25; // seconds a tier needs to be worth trying
static const int TWShallowDepth = 15;
static const int TWShallowChildren = 20;
static const NSUInteger TWWhyLength = 300; // characters of "why" at most
static NSString *const TWTierFull = @"full";
static NSString *const TWTierShallow = @"shallow";
static NSString *const TWTierRoot = @"root";

NS_ASSUME_NONNULL_BEGIN

// /source's own steps (FBXPath.m), so this read is the same as /source's: the idle wait before it, and the snapshot
@interface FBXPath (TWTree)
+ (id<FBXCElementSnapshot>)snapshotWithRoot:(id<FBElement>)root useNative:(BOOL)useNative;
+ (void)waitUntilStableWithElement:(id<FBElement>)root;
@end

@interface TWTreeCommands : NSObject <FBCommandHandler>
@end

NS_ASSUME_NONNULL_END

/** The characters XML 1.0 forbids: the set NSString+FBXMLSafeString.m removes. */
static NSCharacterSet *TWUnsafeCharacters(void)
{
  static NSMutableCharacterSet *unsafe;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    unsafe = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x9, 1)];
    [unsafe addCharactersInRange:NSMakeRange(0xA, 1)];
    [unsafe addCharactersInRange:NSMakeRange(0xD, 1)];
    [unsafe addCharactersInRange:NSMakeRange(0x20, 0xD7FF - 0x20 + 1)];
    [unsafe addCharactersInRange:NSMakeRange(0xE000, 0xFFFD - 0xE000 + 1)];
    [unsafe addCharactersInRange:NSMakeRange(0x10000, 0x10FFFF - 0x10000 + 1)];
    [unsafe invert];
  });
  return unsafe;
}

/** A string into the digest: whether there is one, its length in UTF-8 bytes, and those bytes. */
static void TWDigestString(CC_SHA256_CTX *context, NSString *string)
{
  uint8_t present = nil == string ? 0 : 1;
  CC_SHA256_Update(context, &present, (CC_LONG)sizeof(present));
  if (nil == string) {
    return;
  }
  NSData *bytes = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  uint64_t length = (uint64_t)bytes.length;
  CC_SHA256_Update(context, &length, (CC_LONG)sizeof(length));
  if (bytes.length > 0) {
    CC_SHA256_Update(context, bytes.bytes, (CC_LONG)bytes.length);
  }
}

/** The digest's first TWTokenBytes bytes as hex: the answer's token. */
static NSString *TWTokenOf(CC_SHA256_CTX *context)
{
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, context);
  NSMutableString *token = [NSMutableString stringWithCapacity:TWTokenBytes * 2];
  for (NSUInteger i = 0; i < TWTokenBytes; i++) {
    [token appendFormat:@"%02x", (unsigned int)digest[i]];
  }
  return token.copy;
}

/** Milliseconds between two systemUptime readings, rounded. */
static NSNumber *TWTreeMilliseconds(NSTimeInterval from, NSTimeInterval to)
{
  return @(round((to - from) * 1000.0));
}

static NSTimeInterval TWNow(void)
{
  return NSProcessInfo.processInfo.systemUptime;
}

/** Does the object answer what a snapshot is read for here? (A snapshot request may answer something else.) */
static BOOL TWTreeLooksLikeSnapshot(id _Nullable object)
{
  return nil != object
    && [object respondsToSelector:@selector(elementType)]
    && [object respondsToSelector:@selector(frame)]
    && [object respondsToSelector:@selector(children)]
    && [object respondsToSelector:@selector(accessibilityElement)];
}

@implementation TWTreeCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/tw/tree"] respondWithTarget:self action:@selector(handleTree:)],
    [[FBRoute GET:@"/wda/tw/tree"].withoutSession respondWithTarget:self action:@selector(handleTree:)],
    [[FBRoute GET:@"/wda/tw/screen"] respondWithTarget:self action:@selector(handleScreen:)],
    [[FBRoute GET:@"/wda/tw/screen"].withoutSession respondWithTarget:self action:@selector(handleScreen:)],
  ];
}

#pragma mark - The budget (pure, unit tested)

/** The `budget` parameter (milliseconds) in seconds, clamped to 0.5-20 s; 3 s when absent; nil when it isn't a
 *  finite number. */
+ (nullable NSNumber *)budgetSecondsFrom:(nullable id)value
{
  double ms = TWTreeDefaultBudgetMs;
  if ([value isKindOfClass:NSNumber.class]) {
    ms = [(NSNumber *)value doubleValue];
  } else if ([value isKindOfClass:NSString.class]) {
    NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
    if (![scanner scanDouble:&ms] || !scanner.isAtEnd) {
      return nil;
    }
  } else if (nil != value) {
    return nil;
  }
  if (!isfinite(ms)) {
    return nil;
  }
  ms = MIN(MAX(ms, TWTreeMinBudgetMs), TWTreeMaxBudgetMs);
  return @(ms / 1000.0);
}

/** Seconds from the read's start by which finding the application and the "full" tier must be done. */
+ (NSTimeInterval)fullShareOf:(NSTimeInterval)budget
{
  return budget * TWTreeFullShare;
}

/** Seconds kept for the "root" tier at the end of the budget. */
+ (NSTimeInterval)rootReserveOf:(NSTimeInterval)budget
{
  return MIN(MAX(budget * 0.1, 0.2), 1.0);
}

/** Seconds the "shallow" tier may take when `elapsed` seconds of `budget` are gone; 0 when too little is left to
 *  be worth trying. */
+ (NSTimeInterval)shallowTimeoutOf:(NSTimeInterval)budget elapsed:(NSTimeInterval)elapsed
{
  NSTimeInterval left = budget - elapsed - [self rootReserveOf:budget];
  return left >= TWTreeMinTier ? left : 0;
}

#pragma mark - The tree

+ (id<FBResponsePayload>)handleTree:(FBRouteRequest *)request
{
  NSNumber *budgetSeconds = [self budgetSecondsFrom:request.parameters[@"budget"]];
  if (nil == budgetSeconds) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"budget must be a number of milliseconds (500-20000)"
                                                                       traceback:nil]);
  }
  id pathValue = request.parameters[@"path"];
  if (nil != pathValue && !([pathValue isKindOfClass:NSString.class]
                            && ([pathValue isEqualToString:@"direct"] || [pathValue isEqualToString:@"xctest"]))) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"path must be direct or xctest"
                                                                       traceback:nil]);
  }
  // A request without `budget` comes from a client older than version 9 (Tapwright 1.x): it gets what version 8
  // gave it, XCTest's own snapshot, with the longest budget, so that it never takes a shallow tree for the screen.
  BOOL isLegacy = nil == request.parameters[@"budget"];
  BOOL isDirect = isLegacy ? [pathValue isEqual:@"direct"] : (nil == pathValue || [pathValue isEqualToString:@"direct"]);
  NSTimeInterval budget = isLegacy ? TWTreeMaxBudgetMs / 1000.0 : budgetSeconds.doubleValue;
  id since = request.parameters[@"since"];
  NSMutableArray<NSString *> *why = [NSMutableArray array];

  NSTimeInterval began = TWNow();
  NSTimeInterval fullEnd = began + [self fullShareOf:budget];

  // the application /source reads (FBDebugCommands.m), found before the first tier so that "root" can name it
  __block XCUIApplication *application = nil;
  __block NSString *appFailure = nil;
  [[FBXCAXClientProxy sharedClient] withAXTimeout:MAX(fullEnd - TWNow(), TWTreeMinTier) do:^{
    @try {
      application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
    } @catch (NSException *e) {
      appFailure = e.reason ?: e.name;
    }
  } error:nil];
  if (nil == application) {
    [why addObject:[NSString stringWithFormat:@"app: %@", appFailure ?: @"the application in front could not be told"]];
  }
  NSTimeInterval found = TWNow();

  // the idle wait /source makes first, kept to a quarter of the budget
  NSTimeInterval coolOff = FBConfiguration.sharedInstance.animationCoolOffTimeout;
  if (nil != application && coolOff > 0) {
    @try {
      [application fb_waitUntilStableWithTimeout:MIN(coolOff, budget * 0.25)];
    } @catch (NSException *e) {
      [FBLogger logFmt:@"Tapwright tree: the idle wait raised %@: %@", e.name, e.reason];
    }
  }
  NSTimeInterval stable = TWNow();

  NSString *tier = nil;
  id<FBXCElementSnapshot> snapshot = nil;
  if (nil != application) {
    NSString *failure = nil;
    NSTimeInterval fullTimeout = fullEnd - stable;
    if (fullTimeout >= TWTreeMinTier) {
      snapshot = [self snapshotOf:(XCUIApplication *)application direct:isDirect timeout:fullTimeout failure:&failure];
    } else {
      failure = @"no time left";
    }
    if (nil != snapshot) {
      tier = TWTierFull;
    } else {
      [why addObject:[NSString stringWithFormat:@"full: %@", failure]];
      failure = nil;
      NSTimeInterval shallowTimeout = [self shallowTimeoutOf:budget elapsed:TWNow() - began];
      if (shallowTimeout > 0) {
        snapshot = [self shallowSnapshotOf:(XCUIApplication *)application
                                    direct:isDirect
                                   timeout:shallowTimeout
                                   failure:&failure];
      } else {
        failure = @"no time left";
      }
      if (nil != snapshot) {
        tier = TWTierShallow;
      } else {
        [why addObject:[NSString stringWithFormat:@"shallow: %@", failure]];
      }
    }
  }
  NSTimeInterval taken = TWNow();

  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  NSDictionary *tree = nil;
  if (nil != snapshot) {
    if (![tier isEqualToString:TWTierFull]) {
      TWDigestString(&context, tier);
    }
    tree = [self nodeOf:(id<FBXCElementSnapshot>)snapshot context:&context];
  } else {
    tier = TWTierRoot;
    TWDigestString(&context, tier);
    NSTimeInterval left = budget - (taken - began);
    tree = [self rootNodeOf:application wait:MIN(MAX(left, 0.1), 0.5) context:&context];
  }
  NSString *token = TWTokenOf(&context);
  NSTimeInterval built = TWNow();

  NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithCapacity:7];
  answer[@"token"] = token;
  answer[@"tier"] = tier;
  answer[@"truncated"] = [tier isEqualToString:TWTierFull] ? @NO : @YES;
  if (why.count > 0) {
    NSString *text = [why componentsJoinedByString:@"; "];
    answer[@"why"] = text.length > TWWhyLength ? [text substringToIndex:TWWhyLength] : text;
  }
  answer[@"ms"] = @{
    @"app": TWTreeMilliseconds(began, found),
    @"wait": TWTreeMilliseconds(found, stable),
    @"snapshot": TWTreeMilliseconds(stable, taken),
    @"build": TWTreeMilliseconds(taken, built),
    @"budget": @(round(budget * 1000.0)),
  };
  if ([since isKindOfClass:NSString.class] && [(NSString *)since isEqualToString:token]) {
    answer[@"unchanged"] = @YES;
  } else {
    answer[@"tree"] = tree;
  }
  return FBResponseWithObject(answer.copy);
}

/** XCTest's standard attribute names for a direct snapshot; nil when this XCTest can't tell them. */
+ (nullable NSArray<NSString *> *)standardAttributes
{
  Class snapshotClass = NSClassFromString(@"XCElementSnapshot");
  SEL names = @selector(sanitizedElementSnapshotHierarchyAttributesForAttributes:isMacOS:);
  if (nil == snapshotClass || ![snapshotClass respondsToSelector:names]) {
    return nil; // (FBStandardAttributeNames would assert or throw inside its dispatch_once)
  }
  NSArray<NSString *> *attributes = FBStandardAttributeNames();
  return attributes.count > 0 ? attributes : nil;
}

/**
 * A snapshot of the application's tree, taken within `timeout` seconds (see "How the time is bounded" at the top),
 * or nil with `failure` saying why. `direct`: one request of XCTest's accessibility client for the application's
 * element; otherwise (or when that can't be asked on this XCTest) the snapshot /source takes.
 */
+ (nullable id<FBXCElementSnapshot>)snapshotOf:(XCUIApplication *)application
                                        direct:(BOOL)direct
                                       timeout:(NSTimeInterval)timeout
                                       failure:(NSString * _Nullable __autoreleasing *)failure
{
  NSArray<NSString *> *attributes = direct ? [self standardAttributes] : nil;
  __block id<FBXCElementSnapshot> snapshot = nil;
  __block NSString *problem = nil;
  NSError *timeoutError = nil;
  NSTimeInterval started = TWNow();
  TWSetSnapshotRequestDeadline(started + timeout);
  BOOL inTime = NO;
  @try {
    inTime = [[FBXCAXClientProxy sharedClient] withAXTimeout:timeout do:^{
      @try {
        // the application's own element (XCTest's process tracker knows it; asked inside the bounded scope anyway)
        id<FBXCAccessibilityElement> element = nil == attributes
          ? nil
          : (id<FBXCAccessibilityElement>)application.accessibilityElement;
        if (nil != element) {
          NSError *error = nil;
          id result = [[FBXCAXClientProxy sharedClient] snapshotForElement:(id<FBXCAccessibilityElement>)element
                                                                 attributes:attributes
                                                                    inDepth:YES
                                                                      error:&error];
          if (TWTreeLooksLikeSnapshot(result)) {
            snapshot = (id<FBXCElementSnapshot>)result;
          } else {
            problem = error.localizedDescription ?: @"the snapshot request gave no snapshot";
          }
        } else {
          id result = [FBXPath snapshotWithRoot:application
                                      useNative:FBConfiguration.sharedInstance.includeHittableInPageSource];
          if (TWTreeLooksLikeSnapshot(result)) {
            snapshot = (id<FBXCElementSnapshot>)result;
          } else {
            problem = @"the snapshot request gave no snapshot";
          }
        }
      } @catch (NSException *e) {
        problem = e.reason ?: e.name;
      }
    } error:&timeoutError];
  } @finally {
    TWSetSnapshotRequestDeadline(0);
  }
  if (nil != snapshot) {
    return snapshot; // (even when it came a moment after the timeout: it is whole)
  }
  if (nil != failure) {
    NSTimeInterval took = TWNow() - started;
    if (nil != problem) {
      *failure = [NSString stringWithFormat:@"%@ (after %.0f ms)", problem, took * 1000.0];
    } else if (!inTime && nil != timeoutError) {
      *failure = [NSString stringWithFormat:@"the AX timeout could not be set: %@", timeoutError.localizedDescription];
    } else {
      *failure = [NSString stringWithFormat:@"no answer within %.0f ms", timeout * 1000.0];
    }
  }
  return nil;
}

/** As snapshotOf:..., at most TWShallowDepth levels deep and TWShallowChildren children per element; the snapshot
 *  parameters are put back afterwards. */
+ (nullable id<FBXCElementSnapshot>)shallowSnapshotOf:(XCUIApplication *)application
                                               direct:(BOOL)direct
                                              timeout:(NSTimeInterval)timeout
                                              failure:(NSString * _Nullable __autoreleasing *)failure
{
  // XCTest's own default for both is INT_MAX (XCAXClient_iOS+FBSnapshotReqParams.m), which is what "not set" means
  id previousDepth = FBGetCustomParameterForElementSnapshot(FBSnapshotMaxDepthKey) ?: @(INT_MAX);
  id previousChildren = FBGetCustomParameterForElementSnapshot(FBSnapshotMaxChildrenKey) ?: @(INT_MAX);
  int depth = MIN([previousDepth intValue] > 0 ? [previousDepth intValue] : INT_MAX, TWShallowDepth);
  int children = MIN([previousChildren intValue] > 0 ? [previousChildren intValue] : INT_MAX, TWShallowChildren);
  FBSetCustomParameterForElementSnapshot(FBSnapshotMaxDepthKey, @(depth));
  FBSetCustomParameterForElementSnapshot(FBSnapshotMaxChildrenKey, @(children));
  @try {
    return [self snapshotOf:application direct:direct timeout:timeout failure:failure];
  } @finally {
    FBSetCustomParameterForElementSnapshot(FBSnapshotMaxDepthKey, previousDepth);
    FBSetCustomParameterForElementSnapshot(FBSnapshotMaxChildrenKey, previousChildren);
  }
}

/**
 * The "root" tier's node: the application alone, with the screen's frame, found without a snapshot. Its process
 * id and bundle id come from the application found before the tiers (XCTest's process tracker, no accessibility
 * question), else from the element XCTest's daemon names at WDA's active app detection point.
 */
+ (NSDictionary *)rootNodeOf:(nullable XCUIApplication *)application
                        wait:(NSTimeInterval)wait
                     context:(CC_SHA256_CTX *)context
{
  int pid = 0;
  NSString *bundle = nil;
  @try {
    if (nil != application) {
      pid = application.processID;
      bundle = application.bundleID;
    } else {
      id<FBXCAccessibilityElement> element = FBActiveAppDetectionPoint.sharedInstance.axElement;
      pid = nil == element ? 0 : element.processIdentifier;
      if (pid > 0) {
        XCUIApplication *app = [[FBXCAXClientProxy sharedClient] monitoredApplicationWithProcessIdentifier:pid];
        bundle = app.bundleID;
        if (0 == bundle.length) {
          NSDictionary *info = [XCUIApplication fb_appsInfoWithAxElements:@[(id<FBXCAccessibilityElement>)element]].firstObject;
          id named = info[@"bundleId"];
          bundle = [named isKindOfClass:NSString.class] ? (NSString *)named : nil;
        }
      }
    }
  } @catch (NSException *e) {
    [FBLogger logFmt:@"Tapwright tree: the application can't be named: %@", e.reason ?: e.name];
  }

  NSMutableDictionary *node = [NSMutableDictionary dictionaryWithCapacity:4];
  NSString *type = [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeApplication];
  node[@"t"] = type;
  TWDigestString(context, type);

  NSDictionary *screen = [self screenFactsWithin:wait];
  double rect[4] = {0, 0, [screen[@"width"] doubleValue], [screen[@"height"] doubleValue]};
  node[@"r"] = @[@(rect[0]), @(rect[1]), @(rect[2]), @(rect[3])];
  CC_SHA256_Update(context, rect, (CC_LONG)sizeof(rect));

  int32_t pid32 = (int32_t)pid;
  CC_SHA256_Update(context, &pid32, (CC_LONG)sizeof(pid32));
  if (pid32 > 0) {
    node[@"pid"] = @(pid32);
    // FBUnknownBundleId and empty strings are not a bundle id
    if (bundle.length > 0 && ![bundle isEqualToString:@"unknown"]) {
      [self put:bundle key:@"b" into:node context:context];
    } else {
      TWDigestString(context, nil);
    }
  }
  return node.copy;
}

/** The string as /source writes it: without the characters XML 1.0 forbids (most strings have none: no copy). */
+ (nullable NSString *)safe:(nullable NSString *)string
{
  if (nil == string || NSNotFound == [string rangeOfCharacterFromSet:TWUnsafeCharacters()].location) {
    return string;
  }
  return [string fb_xmlSafeStringWithReplacement:@""];
}

/** Sets `key` to the string when there is one, and puts it into the digest either way. */
+ (void)put:(nullable NSString *)string
        key:(NSString *)key
       into:(NSMutableDictionary *)node
    context:(CC_SHA256_CTX *)context
{
  NSString *safe = [self safe:string];
  TWDigestString(context, safe);
  if (nil != safe) {
    node[key] = safe;
  }
}

/** One element and everything below it, as a node (see the top of this file), in the order /source writes them. */
+ (NSDictionary *)nodeOf:(id<FBXCElementSnapshot>)snapshot context:(CC_SHA256_CTX *)context
{
  FBXCElementSnapshotWrapper *element = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
  XCUIElementType elementType = snapshot.elementType;
  NSMutableDictionary *node = [NSMutableDictionary dictionaryWithCapacity:8];

  NSString *type = [FBElementTypeTransformer shortStringWithElementType:elementType];
  node[@"t"] = type;
  TWDigestString(context, type);
  [self put:element.wdValue key:@"v" into:node context:context];
  [self put:element.wdName key:@"n" into:node context:context];
  [self put:element.wdLabel key:@"l" into:node context:context];
  // /source writes placeholderValue only for the elements that hold text
  NSString *placeholder = FBDoesElementSupportInnerText(elementType) ? element.wdPlaceholderValue : nil;
  [self put:placeholder key:@"p" into:node context:context];
  NSString *traits = element.wdTraits;
  [self put:(traits.length > 0 ? traits : nil) key:@"tr" into:node context:context];

  CGRect frame = element.wdFrame;
  double rect[4] = {(double)CGRectGetMinX(frame), (double)CGRectGetMinY(frame),
                    (double)CGRectGetWidth(frame), (double)CGRectGetHeight(frame)};
  if (!(isfinite(rect[0]) && isfinite(rect[1]) && isfinite(rect[2]) && isfinite(rect[3]))) {
    rect[0] = rect[1] = rect[2] = rect[3] = 0;
  }
  node[@"r"] = @[@(rect[0]), @(rect[1]), @(rect[2]), @(rect[3])];
  CC_SHA256_Update(context, rect, (CC_LONG)sizeof(rect));

  uint8_t enabled = element.wdEnabled ? 1 : 0;
  CC_SHA256_Update(context, &enabled, (CC_LONG)sizeof(enabled));
  if (0 == enabled) {
    node[@"d"] = @1;
  }

  // (version 5) the element with the keyboard focus: the same snapshot's value, no other question asked
  uint8_t focused = snapshot.hasKeyboardFocus ? 1 : 0;
  CC_SHA256_Update(context, &focused, (CC_LONG)sizeof(focused));
  if (1 == focused) {
    node[@"f"] = @1;
  }

  if (XCUIElementTypeApplication == elementType) {
    // as /source: the process id, and the bundle id of the application it is
    int32_t pid = (int32_t)[snapshot.accessibilityElement processIdentifier];
    CC_SHA256_Update(context, &pid, (CC_LONG)sizeof(pid));
    if (pid > 0) {
      node[@"pid"] = @(pid);
      XCUIApplication *app = [[FBXCAXClientProxy sharedClient] monitoredApplicationWithProcessIdentifier:pid];
      [self put:app.bundleID key:@"b" into:node context:context];
    }
  }

  NSArray<id<FBXCElementSnapshot>> *children = snapshot.children;
  uint64_t count = (uint64_t)children.count;
  CC_SHA256_Update(context, &count, (CC_LONG)sizeof(count));
  if (children.count > 0) {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray arrayWithCapacity:children.count];
    for (id<FBXCElementSnapshot> child in children) {
      @autoreleasepool {
        [list addObject:[self nodeOf:child context:context]];
      }
    }
    node[@"c"] = list;
  }
  return node;
}

#pragma mark - The screen

+ (id<FBResponsePayload>)handleScreen:(FBRouteRequest *)request
{
  return FBResponseWithObject([self screenFactsWithin:1.0]);
}

/** A UIDeviceOrientation as the UIInterfaceOrientation it shows (the landscapes are swapped); unknown for face up,
 *  face down and unknown. */
+ (UIInterfaceOrientation)interfaceOrientationOfDevice:(UIDeviceOrientation)orientation
{
  switch (orientation) {
    case UIDeviceOrientationPortrait:
      return UIInterfaceOrientationPortrait;
    case UIDeviceOrientationPortraitUpsideDown:
      return UIInterfaceOrientationPortraitUpsideDown;
    case UIDeviceOrientationLandscapeLeft:
      return UIInterfaceOrientationLandscapeRight;
    case UIDeviceOrientationLandscapeRight:
      return UIInterfaceOrientationLandscapeLeft;
    case UIDeviceOrientationUnknown:
    case UIDeviceOrientationFaceUp:
    case UIDeviceOrientationFaceDown:
      return UIInterfaceOrientationUnknown;
  }
  return UIInterfaceOrientationUnknown;
}

/**
 * The screen's interface orientation without reading any app: XCTest's daemon is asked for it (the orientation
 * XCTest synthesizes events in), waiting at most `wait` seconds; else the device's orientation. `source` says which.
 */
+ (UIInterfaceOrientation)interfaceOrientationWithin:(NSTimeInterval)wait
                                              source:(NSString * _Nullable __autoreleasing *)source
{
  id deviceInterface = nil;
  @try {
    deviceInterface = [XCUIDevice.sharedDevice deviceEventAndStateInterface];
  } @catch (NSException *e) {
    [FBLogger logFmt:@"Tapwright screen: XCTest's device interface raised %@", e.reason ?: e.name];
    deviceInterface = nil;
  }
  if (nil != deviceInterface && [deviceInterface respondsToSelector:@selector(getInterfaceOrientationWithReply:)]) {
    // `answer` is written before the semaphore is signalled and read only after it was taken.
    // The reply's error is not retained or read beyond its presence (its exact type is private).
    __block long long answer = 0;
    dispatch_semaphore_t replied = dispatch_semaphore_create(0);
    @try {
      [deviceInterface getInterfaceOrientationWithReply:^(long long orientation, __unsafe_unretained id error) {
        answer = nil == error ? orientation : 0;
        dispatch_semaphore_signal(replied);
      }];
      // The main run loop keeps turning while it waits: XCTest may answer on the main queue.
      BOOL isAnswered = [[[[FBRunLoopSpinner new]
                           timeout:wait]
                          interval:0.005]
                         spinUntilTrue:^BOOL{
        return 0 == dispatch_semaphore_wait(replied, DISPATCH_TIME_NOW);
      }];
      if (isAnswered && answer >= UIInterfaceOrientationPortrait && answer <= UIInterfaceOrientationLandscapeLeft) {
        if (nil != source) {
          *source = @"interface";
        }
        return (UIInterfaceOrientation)answer;
      }
    } @catch (NSException *e) {
      [FBLogger logFmt:@"Tapwright screen: the interface orientation can't be asked for: %@", e.reason ?: e.name];
    }
  }
  UIInterfaceOrientation fromDevice = UIInterfaceOrientationUnknown;
  @try {
    fromDevice = [self interfaceOrientationOfDevice:XCUIDevice.sharedDevice.orientation];
  } @catch (NSException *e) {
    [FBLogger logFmt:@"Tapwright screen: the device orientation raised %@", e.reason ?: e.name];
    fromDevice = UIInterfaceOrientationUnknown;
  }
  if (nil != source) {
    *source = UIInterfaceOrientationUnknown == fromDevice ? @"unknown" : @"device";
  }
  return fromDevice;
}

/** GET /wda/tw/screen's answer (see the top of this file). */
+ (NSDictionary *)screenFactsWithin:(NSTimeInterval)wait
{
  XCUIScreen *screen = XCUIScreen.mainScreen;
  double scale = screen.scale;
  CGRect bounds = screen.bounds;
  double pixelWidth = (double)CGRectGetWidth(bounds);
  double pixelHeight = (double)CGRectGetHeight(bounds);
  if (!(isfinite(scale) && scale > 0)) {
    scale = 1;
  }
  if (!(isfinite(pixelWidth) && isfinite(pixelHeight))) {
    pixelWidth = pixelHeight = 0;
  }
  NSString *source = nil;
  UIInterfaceOrientation orientation = [self interfaceOrientationWithin:wait source:&source];
  CGSize size = [self pointSizeOfPixels:CGSizeMake((CGFloat)pixelWidth, (CGFloat)pixelHeight)
                                  scale:scale
                            orientation:orientation];
  return @{
    @"width": @((double)size.width),
    @"height": @((double)size.height),
    @"scale": @(scale),
    @"orientation": @((NSInteger)orientation),
    @"source": source ?: @"unknown",
    @"pixels": @[@(pixelWidth), @(pixelHeight)],
  };
}

/** The screen in points as an app sees it in `orientation`: portrait unless it is a landscape (pure, unit tested). */
+ (CGSize)pointSizeOfPixels:(CGSize)pixels scale:(double)scale orientation:(UIInterfaceOrientation)orientation
{
  double factor = (isfinite(scale) && scale > 0) ? scale : 1;
  double a = (double)pixels.width / factor;
  double b = (double)pixels.height / factor;
  double shortSide = MIN(a, b);
  double longSide = MAX(a, b);
  BOOL isLandscape = UIInterfaceOrientationLandscapeLeft == orientation
    || UIInterfaceOrientationLandscapeRight == orientation;
  return isLandscape
    ? CGSizeMake((CGFloat)longSide, (CGFloat)shortSide)
    : CGSizeMake((CGFloat)shortSide, (CGFloat)longSide);
}

@end
