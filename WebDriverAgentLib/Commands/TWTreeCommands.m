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
 *   (version 10) Fewer attributes, and the snapshot's own cost:
 *   `attrs` (path "direct" only; with "xctest" it is an "invalid argument" error) picks the accessibility attributes
 *   the direct request asks for, per element:
 *     "std"   XCTest's standard set (FBStandardAttributeNames: +[XCElementSnapshot
 *             sanitizedElementSnapshotHierarchyAttributesForAttributes:nil isMacOS:NO]), what version 9 asked; the
 *             default (TWTreeDefaultAttrs).
 *     "lean"  only what nodeOf: reads: XCTest's own attributes for the snapshot key paths of TWLeanKeyPaths()
 *             (+axAttributesForElementSnapshotKeyPaths:isMacOS:), put through the same sanitizer XCTest uses for a
 *             hierarchy. When this XCTest can't tell them for every key path, "lean" asks "std" (GET /wda/tw/attrs
 *             says why).
 *     a comma-separated list of attribute names, with or without "XC_kAXXCAttribute", in any letter case: exactly
 *             those, to time each one. A name that isn't one of GET /wda/tw/attrs' "valid" is an "invalid argument"
 *             error naming the valid ones. The list isn't completed: without the type or frame attributes nodes
 *             lose those values.
 *   Which elements are read (the tree's shape) never depends on the attributes: the request's parameters
 *   traverseFromParentsToChildren, maxDepth and maxChildren make the AX server walk the children, and the
 *   snapshot's `children` come from that walk. XC_kAXXCAttributeChildren is only valid in a list when XCTest's own
 *   std or lean sets hold it (mobile-agent found that asking for it on its own keeps the reply from decoding).
 *   The token is a digest of the nodes only, never of `attrs`: two reads whose nodes are the same have the same
 *   token whatever they asked; a smaller set whose nodes differ has another token (that is how to check "lean").
 *   `arraycap` (1-2147483647, any path): XCTest's snapshot parameter maxArrayCount (default 2147483647), the most
 *   items an array-valued attribute brings. `modal` (0 or 1, any path): snapshotKeyHonorModalViews (default 0): 1
 *   reads only the modal view (an alert, a sheet) when one is shown, so the tree loses what it covers. Both are off
 *   unless given, set for this read only (process-wide, as the shallow tier sets its limits) and put back after it.
 *   Their trees may differ from the default's; compare the tokens.
 *   `ms` gains "request" (milliseconds inside the snapshot requests themselves, all tiers; "snapshot" minus it is
 *   the AX timeout's setting and putting back and finding the application's element) and, when the direct
 *   request was made, "attrs" (how many attribute names it asked for).
 *
 * GET /wda/tw/attrs   (and GET /session/:sessionId/wda/tw/attrs)   (version 10)
 *   What `attrs` can ask on this phone's XCTest, without asking any app:
 *     {"default": "std", "std": [names], "lean": [names], "leanFallback": "<why lean asks std>" (only then),
 *      "keyPaths": [the snapshot key paths lean is made from], "byKeyPath": {key path: [the names XCTest gave it]},
 *      "valid": [names a list may hold],
 *      "parameters": {XCTest's snapshot request parameters as the direct request sends them}}
 *   Names without "XC_kAXXCAttribute". "std" is missing when this XCTest can't tell its standard set.
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
 * GET /wda/tw/front   (and GET /session/:sessionId/wda/tw/front)   (version 11)
 *   The application in front, found exactly as the tree read finds it before its first tier, and nothing more: no
 *   snapshot, no element query, no idle wait, nothing that reads an app's elements:
 *     {"b": "<bundle id>", "pid": n, "ms": n}
 *   `b` and `pid` are left out when they can't be told (`b` also when XCTest names it "unknown"); `ms` is how long
 *   finding it took. Meant to answer in milliseconds also on a screen whose app never answers accessibility reads
 *   (GET /wda/activeAppInfo reads the app's identifier, which waits on the app). See +handleFront: for why none of
 *   its calls can wait on the app.
 *
 * GET /wda/tw/version answers 4 from this version on, 5 once "f" is sent (see TWFastTapCommands.m), 9 once the tree
 * is bounded and the screen and OCR routes exist, 10 once `attrs`, `arraycap`, `modal`, `ms.request`, `ms.attrs` and
 * GET /wda/tw/attrs exist, 11 once GET /wda/tw/front, GET /wda/tw/shot and the OCR route's `image` exist, 16 once
 * the front route's own point lookup is bounded (TWHitCommands.m).
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
static const NSTimeInterval TWFrontAXTimeout = 0.5; // seconds GET /wda/tw/front gives its accessibility lookup
// (version 16, review RN-H2) the app in front the bounded way, for the fast tap's `apps` check (defined at the end)
XCUIApplication *_Nullable TWBoundedFrontApplication(NSString *_Nullable __autoreleasing *_Nullable failure);
// (version 16) the element at a point, the bounded way (TWHitCommands.m; where that file isn't built, WDA's own)
#if !TARGET_OS_TV && !TARGET_OS_WATCH
extern id<FBXCAccessibilityElement> _Nullable TWElementAtPoint(CGPoint point, NSString *_Nullable __autoreleasing *_Nullable how);
#else
static id<FBXCAccessibilityElement> _Nullable TWElementAtPoint(CGPoint point, NSString *_Nullable __autoreleasing *_Nullable how)
{
  if (NULL != how) {
    *how = @"daemon";
  }
  return [FBActiveAppDetectionPoint axElementWithPoint:point];
}
#endif
static NSString *const TWTierFull = @"full";
static NSString *const TWTierShallow = @"shallow";
static NSString *const TWTierRoot = @"root";

// (version 10) the attributes of the direct request
static NSString *const TWAttrsStandard = @"std";
static NSString *const TWAttrsLean = @"lean";
static NSString *const TWTreeDefaultAttrs = @"std"; // what a read without `attrs` asks (version 9's set)
static NSString *const TWAttributePrefix = @"XC_kAXXCAttribute";
// XCTest's snapshot request parameters (XCAXClient_iOS+FBSnapshotReqParams.m lists their defaults)
static NSString *const TWSnapshotMaxArrayCountKey = @"maxArrayCount";
static NSString *const TWSnapshotHonorModalViewsKey = @"snapshotKeyHonorModalViews";

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

/**
 * The snapshot key paths nodeOf: reads, which "lean" asks the attributes of (version 10). Node key -> key paths:
 * "t" elementType; "v" value, and label (static text), selected (buttons), placeholderValue (text) as wdValue
 * reads them; "n" identifier, label; "l" label; "p" placeholderValue; "tr" traits; "r" frame; "d" enabled;
 * "f" hasKeyboardFocus. "pid" is the snapshot's accessibilityElement (every snapshot carries it, no attribute),
 * "b" comes from XCTest's process tracker, and "c" from the request's traversal parameters.
 */
static NSArray<NSString *> *TWLeanKeyPaths(void)
{
  return @[@"elementType", @"frame", @"label", @"identifier", @"value", @"placeholderValue", @"enabled",
           @"selected", @"traits", @"hasKeyboardFocus"];
}

/** Other spellings of a key path XCTest may know it by (a BOOL property's getter); empty when there is none. */
static NSArray<NSString *> *TWKeyPathAlternatives(NSString *keyPath)
{
  if ([keyPath isEqualToString:@"enabled"]) {
    return @[@"isEnabled"];
  }
  if ([keyPath isEqualToString:@"selected"]) {
    return @[@"isSelected"];
  }
  return @[];
}

/**
 * Attribute names known to exist on iOS 26's XCTest besides its standard set, for timing in an `attrs` list:
 * the ones mobile-agent's runner asks in one snapshot request (gesposito/mobile-agent agent-ios/shim/Runner.m,
 * iOS 26.6.2) and the ones WDA itself names (XCTestPrivateSymbols.m). XC_kAXXCAttributeChildren is left out on
 * purpose (see the top of this file).
 */
static NSArray<NSString *> *TWKnownAttributeNames(void)
{
  return @[
    @"XC_kAXXCAttributeElementType", @"XC_kAXXCAttributeElementBaseType", @"XC_kAXXCAttributeAutomationType",
    @"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeValue", @"XC_kAXXCAttributePlaceholderValue",
    @"XC_kAXXCAttributeIdentifier", @"XC_kAXXCAttributeFrame", @"XC_kAXXCAttributeTraits",
    @"XC_kAXXCAttributeIsUserInteractionEnabled", @"XC_kAXXCAttributeVisibleVerticalScrollArea",
    @"XC_kAXXCAttributeVisibleHorizontalScrollArea", @"XC_kAXXCAttributeVisibleFrame",
    @"XC_kAXXCAttributeIsVisible", @"XC_kAXXCAttributeIsElement", @"XC_kAXXCAttributeMinValue",
    @"XC_kAXXCAttributeMaxValue", @"XC_kAXXCAttributeCustomActions",
  ];
}

/** The strings in what XCTest answered (an array, an ordered set or a set; a set's in sorted order); empty for
 *  anything else. */
static NSArray<NSString *> *TWStringsIn(id _Nullable value)
{
  NSArray *items = nil;
  BOOL isUnordered = NO;
  if ([value isKindOfClass:NSArray.class]) {
    items = (NSArray *)value;
  } else if ([value isKindOfClass:NSOrderedSet.class]) {
    items = [(NSOrderedSet *)value array];
  } else if ([value isKindOfClass:NSSet.class]) {
    items = [(NSSet *)value allObjects];
    isUnordered = YES;
  }
  NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:items.count];
  for (id item in items) {
    if ([item isKindOfClass:NSString.class] && [(NSString *)item length] > 0) {
      [strings addObject:(NSString *)item];
    }
  }
  if (isUnordered) {
    [strings sortUsingSelector:@selector(compare:)];
  }
  return strings.copy;
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
    [[FBRoute GET:@"/wda/tw/attrs"] respondWithTarget:self action:@selector(handleAttrs:)],
    [[FBRoute GET:@"/wda/tw/attrs"].withoutSession respondWithTarget:self action:@selector(handleAttrs:)],
    [[FBRoute GET:@"/wda/tw/front"] respondWithTarget:self action:@selector(handleFront:)],
    [[FBRoute GET:@"/wda/tw/front"].withoutSession respondWithTarget:self action:@selector(handleFront:)],
  ];
}

#pragma mark - The attributes and parameters (pure, unit tested)

/** The attribute name without "XC_kAXXCAttribute" (in any letter case); the name itself when it hasn't the prefix. */
+ (NSString *)shortAttributeName:(NSString *)name
{
  NSUInteger length = TWAttributePrefix.length;
  if (name.length > length
      && NSOrderedSame == [name compare:TWAttributePrefix options:NSCaseInsensitiveSearch range:NSMakeRange(0, length)]) {
    return [name substringFromIndex:length];
  }
  return name;
}

/** The names without "XC_kAXXCAttribute", in their order. */
+ (NSArray<NSString *> *)shortAttributeNames:(NSArray<NSString *> *)names
{
  NSMutableArray<NSString *> *shortNames = [NSMutableArray arrayWithCapacity:names.count];
  for (NSString *name in names) {
    [shortNames addObject:[self shortAttributeName:name]];
  }
  return shortNames.copy;
}

/**
 * The attributes a comma-separated `attrs` list asks for, as the names `valid` spells them: each item is one of
 * them with or without "XC_kAXXCAttribute", in any letter case, spaces around it ignored; a repeat counts once;
 * the list's order is kept. nil with `problem` saying why for an empty item or a name that isn't valid.
 */
+ (nullable NSArray<NSString *> *)attributeList:(NSString *)list
                                     validNames:(NSArray<NSString *> *)valid
                                        problem:(NSString * _Nullable __autoreleasing *)problem
{
  NSMutableDictionary<NSString *, NSString *> *byKey = [NSMutableDictionary dictionaryWithCapacity:valid.count];
  for (NSString *name in valid) {
    byKey[[self shortAttributeName:name].lowercaseString] = name;
  }
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (NSString *raw in [list componentsSeparatedByString:@","]) {
    NSString *item = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (0 == item.length) {
      if (nil != problem) {
        *problem = @"attrs must be lean, std or a comma-separated list of attribute names without an empty one";
      }
      return nil;
    }
    NSString *name = byKey[[self shortAttributeName:item].lowercaseString];
    if (nil == name) {
      if (nil != problem) {
        NSArray<NSString *> *known = [[self shortAttributeNames:valid] sortedArrayUsingSelector:@selector(compare:)];
        *problem = [NSString stringWithFormat:@"attrs: unknown attribute name \"%@\"; valid: lean, std or a list of %@",
                    item, [known componentsJoinedByString:@", "]];
      }
      return nil;
    }
    if (![names containsObject:name]) {
      [names addObject:name];
    }
  }
  return names.copy;
}

/** A whole number from 1 to INT_MAX (a snapshot parameter's count); nil for anything else. */
+ (nullable NSNumber *)snapshotCountFrom:(nullable id)value
{
  long long number = 0;
  if ([value isKindOfClass:NSString.class]) {
    NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
    if (![scanner scanLongLong:&number] || !scanner.isAtEnd) {
      return nil;
    }
  } else if ([value isKindOfClass:NSNumber.class]) {
    double real = [(NSNumber *)value doubleValue];
    if (!(isfinite(real) && real >= 1 && real <= (double)INT_MAX && real == floor(real))) {
      return nil;
    }
    number = (long long)real;
  } else {
    return nil;
  }
  return (number >= 1 && number <= (long long)INT_MAX) ? @((int)number) : nil;
}

/** "1"/"true" as YES, "0"/"false" as NO (also the numbers 1 and 0); nil for anything else. */
+ (nullable NSNumber *)flagFrom:(nullable id)value
{
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
  if ([value isKindOfClass:NSNumber.class]) {
    double number = [(NSNumber *)value doubleValue];
    if (1 == number) {
      return @YES;
    }
    if (0 == number) {
      return @NO;
    }
  }
  return nil;
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

  // (version 10) the direct request's attributes, and the snapshot parameters asked for this read
  id attrsValue = request.parameters[@"attrs"];
  if (nil != attrsValue && ![attrsValue isKindOfClass:NSString.class]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"attrs must be lean, std or a comma-separated list of attribute names"
                                                                       traceback:nil]);
  }
  if (nil != attrsValue && !isDirect) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"attrs works only with path=direct"
                                                                       traceback:nil]);
  }
  NSArray<NSString *> *attributes = nil; // nil: XCTest's own snapshot, as /source takes it
  if (isDirect) {
    NSString *attrsProblem = nil;
    attributes = [self attributesFor:(nil == attrsValue ? TWTreeDefaultAttrs : (NSString *)attrsValue)
                             problem:&attrsProblem];
    if (nil != attrsProblem) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:attrsProblem traceback:nil]);
    }
  }
  id arrayCapValue = request.parameters[@"arraycap"];
  NSNumber *arrayCap = nil == arrayCapValue ? nil : [self snapshotCountFrom:arrayCapValue];
  if (nil != arrayCapValue && nil == arrayCap) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"arraycap must be a whole number from 1 to 2147483647"
                                                                       traceback:nil]);
  }
  id modalValue = request.parameters[@"modal"];
  NSNumber *modal = nil == modalValue ? nil : [self flagFrom:modalValue];
  if (nil != modalValue && nil == modal) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"modal must be 0 or 1"
                                                                       traceback:nil]);
  }
  id since = request.parameters[@"since"];
  NSMutableArray<NSString *> *why = [NSMutableArray array];

  NSTimeInterval began = TWNow();
  NSTimeInterval fullEnd = began + [self fullShareOf:budget];

  // the application /source reads (FBDebugCommands.m), found before the first tier so that "root" can name it
  NSString *appFailure = nil;
  XCUIApplication *application = [self frontApplicationFor:request
                                                    within:MAX(fullEnd - TWNow(), TWTreeMinTier)
                                                   failure:&appFailure];
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
  NSTimeInterval requested = 0; // seconds inside the snapshot requests themselves
  BOOL wasDirect = NO; // whether a direct request was made
  if (nil != application) {
    // (version 10) `arraycap` and `modal` for this read only (process-wide, like the shallow tier's limits)
    id previousArrayCap = FBGetCustomParameterForElementSnapshot(TWSnapshotMaxArrayCountKey);
    id previousModal = FBGetCustomParameterForElementSnapshot(TWSnapshotHonorModalViewsKey);
    if (nil != arrayCap) {
      FBSetCustomParameterForElementSnapshot(TWSnapshotMaxArrayCountKey, (NSNumber *)arrayCap);
    }
    if (nil != modal) {
      FBSetCustomParameterForElementSnapshot(TWSnapshotHonorModalViewsKey, (NSNumber *)modal);
    }
    @try {
      NSString *failure = nil;
      NSTimeInterval fullTimeout = fullEnd - stable;
      if (fullTimeout >= TWTreeMinTier) {
        snapshot = [self snapshotOf:(XCUIApplication *)application
                         attributes:attributes
                            timeout:fullTimeout
                          requested:&requested
                          wasDirect:&wasDirect
                            failure:&failure];
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
                                  attributes:attributes
                                     timeout:shallowTimeout
                                   requested:&requested
                                   wasDirect:&wasDirect
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
    } @finally {
      // put back exactly what was there (nil removes the parameter again)
      if (nil != arrayCap) {
        FBSetCustomParameterForElementSnapshot(TWSnapshotMaxArrayCountKey, previousArrayCap);
      }
      if (nil != modal) {
        FBSetCustomParameterForElementSnapshot(TWSnapshotHonorModalViewsKey, previousModal);
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
  NSMutableDictionary *ms = [NSMutableDictionary dictionaryWithCapacity:7];
  ms[@"app"] = TWTreeMilliseconds(began, found);
  ms[@"wait"] = TWTreeMilliseconds(found, stable);
  ms[@"snapshot"] = TWTreeMilliseconds(stable, taken);
  ms[@"build"] = TWTreeMilliseconds(taken, built);
  ms[@"budget"] = @(round(budget * 1000.0));
  ms[@"request"] = @(round(requested * 1000.0));
  if (wasDirect) {
    ms[@"attrs"] = @(attributes.count);
  }
  answer[@"ms"] = ms.copy;
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

/** The attributes of "lean" (see the top of this file), made once; nil with `problem` saying why when this XCTest
 *  can't tell them for every key path of TWLeanKeyPaths() (then "lean" asks "std"). */
+ (nullable NSArray<NSString *> *)leanAttributesWithProblem:(NSString * _Nullable __autoreleasing *)problem
{
  return [self leanAttributesWithProblem:problem byKeyPath:nil];
}

/** As leanAttributesWithProblem:, and `byKeyPath` (when given) gets the attribute names XCTest gave each key path
 *  (short names), as far as it got. */
+ (nullable NSArray<NSString *> *)leanAttributesWithProblem:(NSString * _Nullable __autoreleasing *)problem
                                                  byKeyPath:(NSDictionary * _Nullable __autoreleasing *)byKeyPath
{
  static NSArray<NSString *> *lean = nil;
  static NSString *leanProblem = nil;
  static NSDictionary *leanByKeyPath = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSString *why = nil;
    NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
    lean = [self makeLeanAttributesWithProblem:&why byKeyPath:mapping];
    leanProblem = nil == lean ? (why ?: @"unknown") : nil;
    leanByKeyPath = mapping.copy;
  });
  if (nil != problem) {
    *problem = leanProblem;
  }
  if (nil != byKeyPath) {
    *byKeyPath = leanByKeyPath;
  }
  return lean;
}

+ (nullable NSArray<NSString *> *)makeLeanAttributesWithProblem:(NSString * _Nullable __autoreleasing *)problem
                                                      byKeyPath:(NSMutableDictionary *)byKeyPath
{
  Class snapshotClass = NSClassFromString(@"XCElementSnapshot");
  SEL keyPathNames = @selector(axAttributesForElementSnapshotKeyPaths:isMacOS:);
  SEL hierarchyNames = @selector(sanitizedElementSnapshotHierarchyAttributesForAttributes:isMacOS:);
  if (nil == snapshotClass
      || ![snapshotClass respondsToSelector:keyPathNames]
      || ![snapshotClass respondsToSelector:hierarchyNames]) {
    if (nil != problem) {
      *problem = @"this XCTest can't name the attributes of snapshot key paths";
    }
    return nil;
  }
  NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
  for (NSString *keyPath in TWLeanKeyPaths()) {
    NSArray<NSString *> *mapped = nil;
    NSMutableArray<NSString *> *spellings = [NSMutableArray arrayWithObject:keyPath];
    [spellings addObjectsFromArray:TWKeyPathAlternatives(keyPath)];
    for (NSString *spelling in spellings) {
      @try {
        mapped = TWStringsIn([snapshotClass axAttributesForElementSnapshotKeyPaths:@[spelling] isMacOS:NO]);
      } @catch (NSException *e) {
        [FBLogger logFmt:@"Tapwright tree: XCTest raised %@ naming the attributes of %@", e.reason ?: e.name, spelling];
        mapped = nil;
      }
      if (mapped.count > 0) {
        break;
      }
    }
    if (0 == mapped.count) {
      if (nil != problem) {
        *problem = [NSString stringWithFormat:@"XCTest names no attribute for the key path %@", keyPath];
      }
      return nil;
    }
    byKeyPath[keyPath] = [self shortAttributeNames:mapped];
    [names addObjectsFromArray:mapped];
  }
  NSArray<NSString *> *sanitized = nil;
  @try {
    sanitized = TWStringsIn([snapshotClass sanitizedElementSnapshotHierarchyAttributesForAttributes:names.array
                                                                                            isMacOS:NO]);
  } @catch (NSException *e) {
    [FBLogger logFmt:@"Tapwright tree: XCTest raised %@ completing the lean attributes", e.reason ?: e.name];
    sanitized = nil;
  }
  if (0 == sanitized.count) {
    if (nil != problem) {
      *problem = @"XCTest's hierarchy sanitizer gave no attributes";
    }
    return nil;
  }
  return sanitized;
}

/** Every attribute name an `attrs` list may hold: XCTest's standard set, the lean set and TWKnownAttributeNames(). */
+ (NSArray<NSString *> *)validAttributeNames
{
  NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
  [names addObjectsFromArray:[self standardAttributes] ?: @[]];
  [names addObjectsFromArray:[self leanAttributesWithProblem:nil] ?: @[]];
  [names addObjectsFromArray:TWKnownAttributeNames()];
  return names.array;
}

/**
 * The attribute names the direct request asks for `attrs` (lean, std or a list); nil without `problem` when this
 * XCTest can't tell them (the read then takes XCTest's own snapshot, as version 9 did); nil with `problem` for a
 * list that isn't valid.
 */
+ (nullable NSArray<NSString *> *)attributesFor:(NSString *)attrs
                                        problem:(NSString * _Nullable __autoreleasing *)problem
{
  if ([attrs isEqualToString:TWAttrsStandard]) {
    return [self standardAttributes];
  }
  if ([attrs isEqualToString:TWAttrsLean]) {
    return [self leanAttributesWithProblem:nil] ?: [self standardAttributes];
  }
  return [self attributeList:attrs validNames:[self validAttributeNames] problem:problem];
}

/** GET /wda/tw/attrs's answer (see the top of this file). */
+ (id<FBResponsePayload>)handleAttrs:(FBRouteRequest *)request
{
  NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithCapacity:7];
  answer[@"default"] = TWTreeDefaultAttrs;
  NSArray<NSString *> *standard = [self standardAttributes];
  if (nil != standard) {
    answer[@"std"] = [self shortAttributeNames:(NSArray<NSString *> *)standard];
  }
  NSString *leanProblem = nil;
  NSDictionary *byKeyPath = nil;
  NSArray<NSString *> *lean = [self leanAttributesWithProblem:&leanProblem byKeyPath:&byKeyPath] ?: standard;
  if (nil != lean) {
    answer[@"lean"] = [self shortAttributeNames:(NSArray<NSString *> *)lean];
  }
  if (nil != leanProblem) {
    answer[@"leanFallback"] = leanProblem;
  }
  answer[@"keyPaths"] = TWLeanKeyPaths();
  answer[@"byKeyPath"] = byKeyPath ?: @{};
  answer[@"valid"] = [self shortAttributeNames:[self validAttributeNames]];

  NSMutableDictionary<NSString *, id> *parameters = [NSMutableDictionary dictionary];
  @try {
    NSDictionary *defaults = [FBXCAXClientProxy sharedClient].defaultParameters;
    for (id key in defaults) {
      id value = defaults[key];
      NSString *name = [key isKindOfClass:NSString.class] ? (NSString *)key : [key description];
      BOOL isPlain = [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class];
      parameters[name] = isPlain ? value : ([value description] ?: @"");
    }
  } @catch (NSException *e) {
    [FBLogger logFmt:@"Tapwright attrs: the snapshot parameters can't be read: %@", e.reason ?: e.name];
  }
  answer[@"parameters"] = parameters.copy;
  return FBResponseWithObject(answer.copy);
}

/**
 * A snapshot of the application's tree, taken within `timeout` seconds (see "How the time is bounded" at the top),
 * or nil with `failure` saying why. With `attributes`: one request of XCTest's accessibility client for the
 * application's element with those attributes; without them (or when the element can't be had) the snapshot
 * /source takes. `requested` grows by the seconds spent inside the request itself; `wasDirect` becomes YES when
 * the direct request was made.
 */
+ (nullable id<FBXCElementSnapshot>)snapshotOf:(XCUIApplication *)application
                                    attributes:(nullable NSArray<NSString *> *)attributes
                                       timeout:(NSTimeInterval)timeout
                                     requested:(NSTimeInterval *)requested
                                     wasDirect:(BOOL *)wasDirect
                                       failure:(NSString * _Nullable __autoreleasing *)failure
{
  __block id<FBXCElementSnapshot> snapshot = nil;
  __block NSString *problem = nil;
  __block NSTimeInterval requestTook = 0;
  __block BOOL isDirect = NO;
  NSError *timeoutError = nil;
  NSTimeInterval started = TWNow();
  TWSetSnapshotRequestDeadline(started + timeout);
  BOOL inTime = NO;
  @try {
    inTime = [[FBXCAXClientProxy sharedClient] withAXTimeout:timeout do:^{
      // the application's own element (XCTest's process tracker knows it; asked inside the bounded scope anyway)
      id<FBXCAccessibilityElement> element = nil;
      if (nil != attributes) {
        @try {
          element = (id<FBXCAccessibilityElement>)application.accessibilityElement;
        } @catch (NSException *e) {
          [FBLogger logFmt:@"Tapwright tree: the application's element raised %@", e.reason ?: e.name];
          element = nil;
        }
      }
      NSTimeInterval requestStarted = TWNow();
      @try {
        if (nil != element) {
          isDirect = YES;
          NSError *error = nil;
          id result = [[FBXCAXClientProxy sharedClient] snapshotForElement:(id<FBXCAccessibilityElement>)element
                                                                 attributes:(NSArray<NSString *> *)attributes
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
      requestTook = TWNow() - requestStarted;
    } error:&timeoutError];
  } @finally {
    TWSetSnapshotRequestDeadline(0);
  }
  if (NULL != requested) {
    *requested += requestTook;
  }
  if (NULL != wasDirect && isDirect) {
    *wasDirect = YES;
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
                                           attributes:(nullable NSArray<NSString *> *)attributes
                                              timeout:(NSTimeInterval)timeout
                                            requested:(NSTimeInterval *)requested
                                            wasDirect:(BOOL *)wasDirect
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
    return [self snapshotOf:application
                 attributes:attributes
                    timeout:timeout
                  requested:requested
                  wasDirect:wasDirect
                    failure:failure];
  } @finally {
    FBSetCustomParameterForElementSnapshot(FBSnapshotMaxDepthKey, previousDepth);
    FBSetCustomParameterForElementSnapshot(FBSnapshotMaxChildrenKey, previousChildren);
  }
}

#pragma mark - The application in front (version 11: shared by the tree read and GET /wda/tw/front)

/**
 * The application /source reads (FBDebugCommands.m): the session's active application, else XCTest's active one,
 * looked up inside -[FBXCAXClientProxy withAXTimeout:do:error:] so that its accessibility calls wait `timeout`
 * seconds at most. nil, with `failure` set when the lookup raised, when it can't be told.
 */
+ (nullable XCUIApplication *)frontApplicationFor:(nullable FBRouteRequest *)request
                                           within:(NSTimeInterval)timeout
                                          failure:(NSString * _Nullable __autoreleasing *)failure
{
  __block XCUIApplication *application = nil;
  __block NSString *problem = nil;
  [[FBXCAXClientProxy sharedClient] withAXTimeout:timeout do:^{
    @try {
      application = [self boundedActiveApplicationFor:request];
      // (version 15) WebDriverAgent names the app in front by the element at its detection point. On a home screen
      // page with an interactive widget at that point the element is the widget's, drawn by a WidgetRenderer process
      // (com.apple.chrono.WidgetRenderer-Default) whose accessibility never answers: the app in front was that
      // process, and the home screen read as a screen with no elements (iPhone 14 Pro Max, iOS 26.5, 2026-11-26,
      // when a Smart Stack turned to the Fitness widget). A widget is never the app in front: SpringBoard is.
      if ([self isWidgetHost:application.bundleID]) {
        application = XCUIApplication.fb_systemApplication;
      }
    } @catch (NSException *e) {
      problem = e.reason ?: e.name;
    }
  } error:nil];
  if (NULL != failure) {
    *failure = problem;
  }
  return application;
}

/**
 * (version 16) The application in front as WebDriverAgent's own detection finds it for a session started without an
 * app (Tapwright's: defaultActiveApplication "auto", or no session), with its one point lookup made the bounded way
 * (TWElementAtPoint): the active applications; when there is more than one, the one whose process owns the element at
 * WDA's detection point; else the most recent; else the system application. WDA's own detection asks the daemon at
 * that point, a request nothing bounds (TWHitCommands.m). A session with another default application: WDA's own.
 */
+ (XCUIApplication *)boundedActiveApplicationFor:(nullable FBRouteRequest *)request
{
  FBSession *session = request.session;
  if (nil != session && ![session.defaultActiveApplication isEqualToString:@"auto"]) {
    return session.activeApplication;
  }
  NSArray<XCUIApplication *> *applications = XCUIApplication.fb_activeApplications;
  if (applications.count > 1) {
    id<FBXCAccessibilityElement> element = TWElementAtPoint(FBActiveAppDetectionPoint.sharedInstance.coordinates, NULL);
    if (nil != element) {
      for (XCUIApplication *application in applications) {
        if (application.processID == element.processIdentifier) {
          return application;
        }
      }
    }
  }
  return applications.firstObject ?: XCUIApplication.fb_systemApplication;
}

/** Is this the bundle id of a process that only draws widgets (chronod's renderers)? Never an app in front. */
+ (BOOL)isWidgetHost:(nullable NSString *)bundle
{
  return nil != bundle && [bundle hasPrefix:@"com.apple.chrono."];
}

/**
 * The process id of `application` (0 when it can't be told), and its bundle id into `bundle` (nil when it can't
 * be told, is empty or is FBUnknownBundleId's "unknown"). Both come from XCTest's process tracker, no
 * accessibility question. Without an application: from the element XCTest's daemon names at WDA's active app
 * detection point (at most 0.3 s), then the tracker, then the daemon's bundle id for that process (at most 1 s).
 */
+ (int)processOf:(nullable XCUIApplication *)application bundle:(NSString * _Nullable __autoreleasing *)bundle
{
  int pid = 0;
  NSString *named = nil;
  @try {
    if (nil != application) {
      pid = application.processID;
      named = application.bundleID;
    } else {
      // (version 16) the bounded lookup, not WDA's daemon question (TWHitCommands.m)
      id<FBXCAccessibilityElement> element = TWElementAtPoint(FBActiveAppDetectionPoint.sharedInstance.coordinates, NULL);
      pid = nil == element ? 0 : element.processIdentifier;
      if (pid > 0) {
        XCUIApplication *app = [[FBXCAXClientProxy sharedClient] monitoredApplicationWithProcessIdentifier:pid];
        named = app.bundleID;
        if (0 == named.length) {
          NSDictionary *info = [XCUIApplication fb_appsInfoWithAxElements:@[(id<FBXCAccessibilityElement>)element]].firstObject;
          id told = info[@"bundleId"];
          named = [told isKindOfClass:NSString.class] ? (NSString *)told : nil;
        }
      }
    }
  } @catch (NSException *e) {
    [FBLogger logFmt:@"Tapwright tree: the application can't be named: %@", e.reason ?: e.name];
  }
  if (NULL != bundle) {
    // FBUnknownBundleId and empty strings are not a bundle id
    *bundle = (named.length > 0 && ![named isEqualToString:@"unknown"]) ? named : nil;
  }
  return pid;
}

/**
 * GET /wda/tw/front: the application in front, as the tree read finds it before its first tier.
 *
 * Why none of its calls can wait on the app in front (or on any app's elements):
 * - The session's -activeApplication, for a session started without an app (Tapwright's: POST /session with empty
 *   capabilities, defaultActiveApplication "auto"), is +fb_activeApplicationWithDefaultBundleId:nil. (A session
 *   started with an app under test and shouldRespectSystemAlerts on would also ask SpringBoard whether it shows an
 *   alert: an element query of SpringBoard, not of the app in front, bounded by the AX timeout below.)
 * - That asks XCAXClient_iOS for the active applications: one request to the accessibility server for the list of
 *   application elements, not for anything inside an app, bounded by the AX timeout (TWFrontAXTimeout, 0.5 s) set
 *   with -withAXTimeout:do:error:. When there is more than one, it asks which element is at WDA's detection point:
 *   (version 16) the accessibility client's own lookup with the AX timeout at 0.3 s (TWElementAtPoint), where WDA's
 *   detection asked XCTest's daemon (_XCT_requestElementAtPoint:, whose answer is waited for 0.3 s at most, the
 *   request itself unbounded).
 * - The XCUIApplication comes from XCTest's process tracker (-monitoredApplicationWithProcessIdentifier:), and its
 *   processID and bundleID are properties of that tracker's process record: no accessibility request. Nothing here
 *   reads `identifier`, `label` or any other element attribute, which is what makes GET /wda/activeAppInfo wait.
 * - Only when no application could be had at all: the daemon at the detection point again (0.3 s at most) and the
 *   daemon's bundle id for that process id (_XCT_requestBundleIDForPID:, 1 s at most).
 * No snapshot, no idle wait, no quiescence wait. Worst case is about 0.5 + 0.3 + 1 s, not the app's own pace; the
 * usual case is a few milliseconds (the tree read's ms.app: 5-9 ms with TikTok's feed in front).
 */
+ (id<FBResponsePayload>)handleFront:(FBRouteRequest *)request
{
  NSTimeInterval began = TWNow();
  XCUIApplication *application = [self frontApplicationFor:request within:TWFrontAXTimeout failure:nil];
  NSString *bundle = nil;
  int pid = [self processOf:application bundle:&bundle];
  NSTimeInterval told = TWNow();

  NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithCapacity:3];
  if (pid > 0) {
    answer[@"pid"] = @(pid);
    answer[@"b"] = bundle; // nil leaves it out
  }
  answer[@"ms"] = TWTreeMilliseconds(began, told);
  return FBResponseWithObject(answer.copy);
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
  NSString *bundle = nil;
  int pid = [self processOf:application bundle:&bundle];

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

/**
 * (version 16, review RN-H2) The application in front, the bounded way, for a caller without a request (the fast
 * tap's `apps` check, TWFastTapCommands.m): what GET /wda/tw/front finds, inside -withAXTimeout:do:error:
 * (TWFrontAXTimeout), its point lookup the client's own (TWElementAtPoint). nil when it can't be told; `failure` set
 * when the lookup raised.
 */
XCUIApplication *_Nullable TWBoundedFrontApplication(NSString *_Nullable __autoreleasing *_Nullable failure)
{
  return [TWTreeCommands frontApplicationFor:nil within:TWFrontAXTimeout failure:failure];
}

