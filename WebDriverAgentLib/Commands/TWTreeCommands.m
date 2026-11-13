/**
 * Tapwright: a compact read of the screen (route version 4).
 *
 * GET /session/:sessionId/wda/tw/tree?since=<token>   (and GET /wda/tw/tree without a session, as /source)
 *   The tree that GET /source?format=xml&excluded_attributes=visible,accessible gives, read the same way (the same
 *   application, the same idle wait, the same snapshot and the same attribute values), with only what Tapwright's
 *   list reads, as compact JSON:
 *     {"token": "<32 hex digits>", "tree": <node>, "ms": {"wait": n, "snapshot": n, "build": n}}
 *   A node is {"t": the element type without "XCUIElementType", "v": value, "n": name, "l": label,
 *              "p": placeholderValue, "tr": traits, "r": [x, y, width, height], "d": 1 when it is not enabled,
 *              "c": [its children's nodes], and on an application "pid": its process id and "b": its bundle id}.
 *   A key is left out where /source leaves the attribute out; "tr" also when the traits are empty, and "c" when there
 *   are no children. "r" is [0, 0, 0, 0] when a frame isn't finite (/source writes "nan" there, which reads as no
 *   frame). Strings are the ones /source writes: without the characters XML 1.0 forbids.
 *   `token` is a digest of the whole tree. When `since` is that token nothing changed since that read, and the answer
 *   is {"token": <the same>, "unchanged": true, "ms": {...}} without the tree.
 *   `ms` says where the time went: the idle wait (none with animationCoolOffTimeout 0), XCTest's snapshot, and
 *   building this answer.
 *
 * GET /wda/tw/version answers 4 from this version on (see TWFastTapCommands.m).
 *
 * Kept in this one file so the fork rebases cleanly onto upstream.
 */

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "FBCommandHandler.h"
#import "FBConfiguration.h"
#import "FBElement.h"
#import "FBElementHelpers.h"
#import "FBElementTypeTransformer.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCAXClientProxy.h"
#import "FBXCElementSnapshot.h"
#import "FBXCElementSnapshotWrapper.h"
#import "FBXPath.h"
#import "NSString+FBXMLSafeString.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBWebDriverAttributes.h"

static const NSUInteger TWTokenBytes = 16; // of the SHA-256 digest: 128 bits

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

@implementation TWTreeCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/tw/tree"] respondWithTarget:self action:@selector(handleTree:)],
    [[FBRoute GET:@"/wda/tw/tree"].withoutSession respondWithTarget:self action:@selector(handleTree:)],
  ];
}

+ (id<FBResponsePayload>)handleTree:(FBRouteRequest *)request
{
  // the application /source reads (FBDebugCommands.m)
  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  id since = request.parameters[@"since"];
  CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
  [FBXPath waitUntilStableWithElement:application];
  CFAbsoluteTime stable = CFAbsoluteTimeGetCurrent();
  id<FBXCElementSnapshot> snapshot = [FBXPath snapshotWithRoot:application
                                                     useNative:FBConfiguration.sharedInstance.includeHittableInPageSource];
  CFAbsoluteTime taken = CFAbsoluteTimeGetCurrent();

  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  NSDictionary *tree = [self nodeOf:snapshot context:&context];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString *token = [NSMutableString stringWithCapacity:TWTokenBytes * 2];
  for (NSUInteger i = 0; i < TWTokenBytes; i++) {
    [token appendFormat:@"%02x", (unsigned int)digest[i]];
  }
  CFAbsoluteTime built = CFAbsoluteTimeGetCurrent();

  NSDictionary *ms = @{
    @"wait": @(round((stable - began) * 1000.0)),
    @"snapshot": @(round((taken - stable) * 1000.0)),
    @"build": @(round((built - taken) * 1000.0)),
  };
  if ([since isKindOfClass:NSString.class] && [(NSString *)since isEqualToString:token]) {
    return FBResponseWithObject(@{@"token": token, @"unchanged": @YES, @"ms": ms});
  }
  return FBResponseWithObject(@{@"token": token, @"tree": tree, @"ms": ms});
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

@end
