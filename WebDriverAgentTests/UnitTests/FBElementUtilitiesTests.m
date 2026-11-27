/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */


#import <XCTest/XCTest.h>

#import "FBElement.h"
#import "XCUIElementDouble.h"
#import "FBElementUtils.h"
#import "FBConfiguration.h"
#import "XCUIElement+FBUtilities.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCElementSnapshot.h"
#import "XCElementSnapshotDouble.h"
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>

// Private Tapwright route version 9 methods: their pure logic only (the budget split and the geometry).
@interface TWTreeCommands : NSObject
+ (nullable NSNumber *)budgetSecondsFrom:(nullable id)value;
+ (NSTimeInterval)fullShareOf:(NSTimeInterval)budget;
+ (NSTimeInterval)rootReserveOf:(NSTimeInterval)budget;
+ (NSTimeInterval)shallowTimeoutOf:(NSTimeInterval)budget elapsed:(NSTimeInterval)elapsed;
+ (CGSize)pointSizeOfPixels:(CGSize)pixels scale:(double)scale orientation:(UIInterfaceOrientation)orientation;
// route version 10: the `attrs` list and the snapshot parameters
+ (NSString *)shortAttributeName:(NSString *)name;
+ (nullable NSArray<NSString *> *)attributeList:(NSString *)list
                                     validNames:(NSArray<NSString *> *)valid
                                        problem:(NSString * _Nullable __autoreleasing *)problem;
+ (nullable NSNumber *)snapshotCountFrom:(nullable id)value;
+ (nullable NSNumber *)flagFrom:(nullable id)value;
@end

@interface TWOcrCommands : NSObject
+ (CGImagePropertyOrientation)propertyOrientationOf:(UIImageOrientation)orientation;
+ (CGSize)uprightSizeOf:(CGSize)size orientation:(UIImageOrientation)orientation;
+ (CGRect)screenRectOfNormalizedBox:(CGRect)box inSize:(CGSize)size;
// route version 11: the picture's parameters and size
+ (nullable NSNumber *)pictureWidthFrom:(nullable id)value;
+ (nullable NSNumber *)pictureQualityFrom:(nullable id)value;
+ (nullable NSNumber *)imageFlagFrom:(nullable id)value;
+ (CGSize)sentSizeOf:(CGSize)upright width:(NSInteger)width;
+ (NSInteger)shotQualityFor:(NSInteger)quality width:(NSInteger)width;
+ (CGSize)pointSizeOf:(CGSize)upright scale:(double)scale;
@end

// Private Tapwright command methods, exercised with synthetic AX identities only.
@interface TWHitCommands : NSObject
+ (BOOL)snapshot:(id)snapshot matchesHit:(id)hit;
+ (id)verifiedSnapshotOf:(id)hit inApplication:(id)application via:(NSString * __autoreleasing *)via;
// route version 16: the way a point is asked, and what a lookup that found nothing says
+ (NSString *)howFrom:(nullable id)value;
+ (NSString *)nothingWhyAfter:(NSNumber *)milliseconds how:(NSString *)how errorName:(nullable NSString *)errorName;
+ (nullable NSString *)shortErrorName:(nullable NSError *)error;
+ (NSString *)nothingWhyAfter:(NSNumber *)milliseconds all:(nullable NSNumber *)all how:(NSString *)how
                    errorName:(nullable NSString *)errorName;
+ (nullable id)elementAt:(CGPoint)point how:(NSString * __autoreleasing *)how errorName:(NSString * __autoreleasing *)errorName;
@end


// (version 16) the two lookups, faked: which was asked, what the client one says
static NSUInteger TWClientAsks;
static NSUInteger TWDaemonAsks;
static BOOL TWClientCanAsk;
static id TWClientElement;
static NSString *TWClientErrorName;
static id TWDaemonElement;
@interface TWHitLookupDouble : TWHitCommands
@end
@implementation TWHitLookupDouble
+ (id)clientElementAt:(CGPoint)point asked:(BOOL *)asked errorName:(NSString * __autoreleasing *)errorName
{
  TWClientAsks++;
  if (!TWClientCanAsk) {
    return nil;
  }
  *asked = YES;
  if (nil == TWClientElement && NULL != errorName) {
    *errorName = TWClientErrorName;
  }
  return TWClientElement;
}
+ (id)daemonElementAt:(CGPoint)point
{
  TWDaemonAsks++;
  return TWDaemonElement;
}
@end

@interface TWHitAXDouble : NSObject
@property (nonatomic, strong) id payload;
@property (nonatomic) int processIdentifier;
@end
@implementation TWHitAXDouble
@end

@interface TWHitSnapshotDouble : XCElementSnapshotDouble
@property (nonatomic, strong) id hitElement;
@end
@implementation TWHitSnapshotDouble
- (CGRect)frame { return CGRectMake(16, 82, 48, 49); }
- (id<FBXCAccessibilityElement>)accessibilityElement { return self.hitElement; }
@end

static id TWDirectSnapshot;
static id TWFallbackSnapshot;
static NSUInteger TWFallbackReads;
@interface TWHitCommandsDouble : TWHitCommands
@end
@implementation TWHitCommandsDouble
+ (id)snapshotOfElement:(id)hit { return TWDirectSnapshot; }
+ (id)snapshotOf:(id)hit inApplication:(id)application
{
  TWFallbackReads++;
  return TWFallbackSnapshot;
}
@end

static TWHitAXDouble *TWAX(unsigned long long elementId, int processId)
{
  TWHitAXDouble *element = [TWHitAXDouble new];
  element.payload = @{@"uid.elementID": @(elementId)};
  element.processIdentifier = processId;
  return element;
}

static TWHitSnapshotDouble *TWSnapshot(id element)
{
  TWHitSnapshotDouble *snapshot = [TWHitSnapshotDouble new];
  snapshot.hitElement = element;
  return snapshot;
}

@interface FBQuiescenceApplicationDouble : NSObject
@property (nonatomic) BOOL fb_shouldWaitForQuiescence;
@property (nonatomic) NSTimeInterval observedTimeout;
@end
@implementation FBQuiescenceApplicationDouble
- (id)applicationImpl { return self; }
- (id)currentProcess { return self; }
- (void)fb_waitForQuiescenceIncludingAnimationsIdle:(BOOL)includingAnimations
{
  self.observedTimeout = FBConfiguration.sharedInstance.waitForIdleTimeout;
  @throw [NSException exceptionWithName:@"QuiescenceFailure" reason:@"test" userInfo:nil];
}
@end

@interface FBElementUtilitiesTests : XCTestCase
@end

@implementation FBElementUtilitiesTests

- (void)testNothingAnsweredSaysTheVersion6WordsFirstThenTheTimeAndTheWay
{
  // (version 16) daemons 2.0.2 and 2.0.3 match "no element answered"; 2.0.3 on runner 16 reads the time and the way
  XCTAssertEqualObjects([TWHitCommands nothingWhyAfter:@304 how:@"client" errorName:nil], @"no element answered at the point (hit 304 ms, client)");
  XCTAssertEqualObjects([TWHitCommands nothingWhyAfter:@12 how:@"daemon" errorName:nil], @"no element answered at the point (hit 12 ms, daemon)");
  XCTAssertEqualObjects([TWHitCommands nothingWhyAfter:@301 how:@"client" errorName:@"kAXErrorIPCTimeout"],
                        @"no element answered at the point (hit 301 ms, client, kAXErrorIPCTimeout)");
}

- (void)testNothingAnsweredSaysTheLookupsOwnTimeThenTheWhole
{
  // (review RN-M1) "hit" is the lookup alone, "all" the lookup with the AX timeout's lock, install and restore
  XCTAssertEqualObjects([TWHitCommands nothingWhyAfter:@12 all:@272 how:@"client" errorName:nil],
                        @"no element answered at the point (hit 12 ms, all 272 ms, client)");
  XCTAssertEqualObjects([TWHitCommands nothingWhyAfter:@301 all:@318 how:@"client" errorName:@"kAXErrorIPCTimeout"],
                        @"no element answered at the point (hit 301 ms, all 318 ms, client, kAXErrorIPCTimeout)");
  // (review RN-M2) a client lookup that raised: the daemon way, the exception named after it
  XCTAssertEqualObjects([TWHitCommands nothingWhyAfter:@300 all:@305 how:@"daemon"
                                             errorName:@"NSInternalInconsistencyException"],
                        @"no element answered at the point (hit 300 ms, all 305 ms, daemon, NSInternalInconsistencyException)");
  XCTAssertEqualObjects([TWHitCommands nothingWhyAfter:@304 all:nil how:@"client" errorName:nil],
                        @"no element answered at the point (hit 304 ms, client)");
}

- (void)testShortErrorNameIsTheAXErrorNameOrDomainAndCode
{
  NSError *timedOut = [NSError errorWithDomain:@"XCTDaemonErrorDomain" code:13
                                      userInfo:@{NSLocalizedDescriptionKey: @"Error kAXErrorIPCTimeout getting snapshot"}];
  XCTAssertEqualObjects([TWHitCommands shortErrorName:timedOut], @"kAXErrorIPCTimeout");
  NSError *other = [NSError errorWithDomain:@"SomeDomain" code:7 userInfo:@{NSLocalizedDescriptionKey: @"failed"}];
  XCTAssertEqualObjects([TWHitCommands shortErrorName:other], @"SomeDomain 7");
  XCTAssertNil([TWHitCommands shortErrorName:nil]);
}

- (void)testHowIsDaemonOnlyWhenAsked
{
  XCTAssertEqualObjects([TWHitCommands howFrom:@"daemon"], @"daemon");
  XCTAssertEqualObjects([TWHitCommands howFrom:@"client"], @"client");
  XCTAssertEqualObjects([TWHitCommands howFrom:nil], @"client");
  XCTAssertEqualObjects([TWHitCommands howFrom:@"anything"], @"client");
  XCTAssertEqualObjects([TWHitCommands howFrom:@42], @"client");
}

- (void)testTheClientWayIsAskedAndTheDaemonWayOnlyAsItsFallbackOrWhenAsked
{
  id element = TWAX(7, 42);
  // the client's lookup answers: the daemon isn't asked
  TWClientAsks = TWDaemonAsks = 0;
  TWClientCanAsk = YES;
  TWClientElement = element;
  TWDaemonElement = nil;
  NSString *how = @"client";
  NSString *errorName = nil;
  XCTAssertEqual([TWHitLookupDouble elementAt:CGPointZero how:&how errorName:&errorName], element);
  XCTAssertEqualObjects(how, @"client");
  XCTAssertEqual(TWDaemonAsks, 0u);
  // the client's lookup asked and found nothing (the app didn't answer in time): no fallback, its error's name
  TWClientAsks = TWDaemonAsks = 0;
  TWClientElement = nil;
  TWClientErrorName = @"kAXErrorIPCTimeout";
  how = @"client";
  XCTAssertNil([TWHitLookupDouble elementAt:CGPointZero how:&how errorName:&errorName]);
  XCTAssertEqualObjects(how, @"client");
  XCTAssertEqualObjects(errorName, @"kAXErrorIPCTimeout");
  XCTAssertEqual(TWDaemonAsks, 0u);
  // the client's lookup can't be made here: the daemon's, and the way says so
  TWClientAsks = TWDaemonAsks = 0;
  TWClientCanAsk = NO;
  TWDaemonElement = element;
  how = @"client";
  XCTAssertEqual([TWHitLookupDouble elementAt:CGPointZero how:&how errorName:&errorName], element);
  XCTAssertEqualObjects(how, @"daemon");
  XCTAssertEqual(TWDaemonAsks, 1u);
  // the daemon's way asked for (the lead's measurement): the client isn't asked
  TWClientAsks = TWDaemonAsks = 0;
  TWClientCanAsk = YES;
  how = @"daemon";
  XCTAssertEqual([TWHitLookupDouble elementAt:CGPointZero how:&how errorName:&errorName], element);
  XCTAssertEqualObjects(how, @"daemon");
  XCTAssertEqual(TWClientAsks, 0u);
  XCTAssertEqual(TWDaemonAsks, 1u);
}

- (void)testHitSnapshotMustMatchElementAndProcessIdentity
{
  id hit = TWAX(123, 42);
  XCTAssertTrue([TWHitCommands snapshot:TWSnapshot(TWAX(123, 42)) matchesHit:hit]);
  XCTAssertFalse([TWHitCommands snapshot:TWSnapshot(TWAX(456, 42)) matchesHit:hit]);
  XCTAssertFalse([TWHitCommands snapshot:TWSnapshot(TWAX(123, 99)) matchesHit:hit]);
  XCTAssertFalse([TWHitCommands snapshot:TWSnapshot(nil) matchesHit:hit]);
  XCTAssertFalse([TWHitCommands snapshot:TWSnapshot(TWAX(0, 42)) matchesHit:hit]);
  XCTAssertFalse([TWHitCommands snapshot:nil matchesHit:hit]);
  XCTAssertFalse([TWHitCommands snapshot:[NSObject new] matchesHit:hit]);
}

- (void)testMatchingDirectHitSnapshotDoesNotReadFallback
{
  id hit = TWAX(123, 42);
  TWDirectSnapshot = TWSnapshot(TWAX(123, 42));
  TWFallbackSnapshot = TWSnapshot(TWAX(456, 42));
  TWFallbackReads = 0;
  NSString *via = nil;
  id result = [TWHitCommandsDouble verifiedSnapshotOf:hit inApplication:[NSObject new] via:&via];
  XCTAssertEqual(result, TWDirectSnapshot);
  XCTAssertEqualObjects(via, @"element");
  XCTAssertEqual(TWFallbackReads, 0u);
}

- (void)testMismatchedDirectSnapshotUsesExactIdentityFallback
{
  id hit = TWAX(123, 42);
  TWDirectSnapshot = TWSnapshot(TWAX(456, 42));
  TWFallbackSnapshot = TWSnapshot(TWAX(123, 42));
  TWFallbackReads = 0;
  NSString *via = nil;
  id result = [TWHitCommandsDouble verifiedSnapshotOf:hit inApplication:[NSObject new] via:&via];
  XCTAssertEqual(result, TWFallbackSnapshot);
  XCTAssertEqualObjects(via, @"app");
  XCTAssertEqual(TWFallbackReads, 1u);
}

- (void)testUnprovenHitIdentityReturnsNoSnapshot
{
  id hit = TWAX(123, 42);
  TWDirectSnapshot = TWSnapshot(TWAX(456, 42));
  for (id fallback in @[TWSnapshot(TWAX(456, 42)), TWSnapshot(TWAX(123, 99)), [NSNull null]]) {
    TWFallbackSnapshot = fallback == [NSNull null] ? nil : fallback;
    NSString *via = nil;
    XCTAssertNil([TWHitCommandsDouble verifiedSnapshotOf:hit inApplication:[NSObject new] via:&via]);
    XCTAssertNil(via);
  }
  NSString *via = nil;
  XCTAssertNil([TWHitCommandsDouble verifiedSnapshotOf:hit inApplication:nil via:&via]);
}

- (void)testTreeBudgetIsClampedAndDefaulted
{
  XCTAssertEqualWithAccuracy([TWTreeCommands budgetSecondsFrom:nil].doubleValue, 3.0, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands budgetSecondsFrom:@"1500"].doubleValue, 1.5, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands budgetSecondsFrom:@(2500)].doubleValue, 2.5, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands budgetSecondsFrom:@"100"].doubleValue, 0.5, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands budgetSecondsFrom:@"99999"].doubleValue, 20.0, 1e-9);
  XCTAssertNil([TWTreeCommands budgetSecondsFrom:@"3s"]);
  XCTAssertNil([TWTreeCommands budgetSecondsFrom:@""]);
  XCTAssertNil([TWTreeCommands budgetSecondsFrom:@[]]);
}

- (void)testTreeBudgetSplitLeavesTimeForEveryTier
{
  XCTAssertEqualWithAccuracy([TWTreeCommands fullShareOf:3.0], 1.8, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands rootReserveOf:0.5], 0.2, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands rootReserveOf:3.0], 0.3, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands rootReserveOf:20.0], 1.0, 1e-9);
  // after a failed full tier, the shallow tier gets the rest but the root tier's reserve
  XCTAssertEqualWithAccuracy([TWTreeCommands shallowTimeoutOf:3.0 elapsed:1.8], 0.9, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands shallowTimeoutOf:20.0 elapsed:12.0], 7.0, 1e-9);
  // too little left: the shallow tier is not tried
  XCTAssertEqualWithAccuracy([TWTreeCommands shallowTimeoutOf:0.5 elapsed:0.3], 0.0, 1e-9);
  XCTAssertEqualWithAccuracy([TWTreeCommands shallowTimeoutOf:3.0 elapsed:2.9], 0.0, 1e-9);
  // the tiers never add up to more than the budget
  double budgets[] = {0.5, 1.0, 3.0, 7.5, 20.0};
  for (size_t i = 0; i < sizeof(budgets) / sizeof(budgets[0]); i++) {
    double budget = budgets[i];
    double full = [TWTreeCommands fullShareOf:budget];
    double shallow = [TWTreeCommands shallowTimeoutOf:budget elapsed:full];
    XCTAssertLessThanOrEqual(full + shallow + [TWTreeCommands rootReserveOf:budget], budget + 1e-9);
  }
}

- (void)testTreeAttributeNamesLoseTheirPrefix
{
  XCTAssertEqualObjects([TWTreeCommands shortAttributeName:@"XC_kAXXCAttributeLabel"], @"Label");
  XCTAssertEqualObjects([TWTreeCommands shortAttributeName:@"xc_kaxxcattributeFrame"], @"Frame");
  XCTAssertEqualObjects([TWTreeCommands shortAttributeName:@"Label"], @"Label");
  // the prefix alone is a name, not an empty one
  XCTAssertEqualObjects([TWTreeCommands shortAttributeName:@"XC_kAXXCAttribute"], @"XC_kAXXCAttribute");
}

- (void)testTreeAttributeListIsCheckedAgainstTheValidNames
{
  NSArray<NSString *> *valid = @[@"XC_kAXXCAttributeElementType", @"XC_kAXXCAttributeLabel",
                                 @"XC_kAXXCAttributeFrame"];
  NSString *problem = nil;
  NSArray<NSString *> *names = [TWTreeCommands attributeList:@"Label,frame" validNames:valid problem:&problem];
  XCTAssertEqualObjects(names, (@[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeFrame"]));
  XCTAssertNil(problem);
  // full names, spaces and repeats
  names = [TWTreeCommands attributeList:@" XC_kAXXCAttributeLabel , label,ElementType"
                             validNames:valid
                                problem:&problem];
  XCTAssertEqualObjects(names, (@[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeElementType"]));
  XCTAssertNil(problem);
  // an empty list or an empty item
  XCTAssertNil([TWTreeCommands attributeList:@"" validNames:valid problem:&problem]);
  XCTAssertTrue([problem containsString:@"empty"]);
  problem = nil;
  XCTAssertNil([TWTreeCommands attributeList:@"Label,,Frame" validNames:valid problem:&problem]);
  XCTAssertTrue([problem containsString:@"empty"]);
  problem = nil;
  // an unknown name is named, with the valid ones
  XCTAssertNil([TWTreeCommands attributeList:@"Label,Bogus" validNames:valid problem:&problem]);
  XCTAssertTrue([problem containsString:@"\"Bogus\""]);
  XCTAssertTrue([problem containsString:@"ElementType, Frame, Label"]);
}

- (void)testTreeSnapshotParametersAreParsed
{
  XCTAssertEqualObjects([TWTreeCommands snapshotCountFrom:@"1"], @1);
  XCTAssertEqualObjects([TWTreeCommands snapshotCountFrom:@"2147483647"], @2147483647);
  XCTAssertEqualObjects([TWTreeCommands snapshotCountFrom:@(5)], @5);
  XCTAssertNil([TWTreeCommands snapshotCountFrom:@"0"]);
  XCTAssertNil([TWTreeCommands snapshotCountFrom:@"-3"]);
  XCTAssertNil([TWTreeCommands snapshotCountFrom:@"2147483648"]);
  XCTAssertNil([TWTreeCommands snapshotCountFrom:@"1.5"]);
  XCTAssertNil([TWTreeCommands snapshotCountFrom:@"many"]);
  XCTAssertNil([TWTreeCommands snapshotCountFrom:@(2.5)]);
  XCTAssertNil([TWTreeCommands snapshotCountFrom:nil]);
  XCTAssertEqualObjects([TWTreeCommands flagFrom:@"1"], @YES);
  XCTAssertEqualObjects([TWTreeCommands flagFrom:@"true"], @YES);
  XCTAssertEqualObjects([TWTreeCommands flagFrom:@"0"], @NO);
  XCTAssertEqualObjects([TWTreeCommands flagFrom:@"FALSE"], @NO);
  XCTAssertEqualObjects([TWTreeCommands flagFrom:@(1)], @YES);
  XCTAssertNil([TWTreeCommands flagFrom:@"yes"]);
  XCTAssertNil([TWTreeCommands flagFrom:@"2"]);
  XCTAssertNil([TWTreeCommands flagFrom:nil]);
}

- (void)testScreenSizeFollowsTheInterfaceOrientation
{
  CGSize portrait = [TWTreeCommands pointSizeOfPixels:CGSizeMake(1179, 2556)
                                                scale:3
                                          orientation:UIInterfaceOrientationPortrait];
  XCTAssertEqualWithAccuracy(portrait.width, 393.0, 1e-9);
  XCTAssertEqualWithAccuracy(portrait.height, 852.0, 1e-9);
  CGSize landscape = [TWTreeCommands pointSizeOfPixels:CGSizeMake(1179, 2556)
                                                 scale:3
                                           orientation:UIInterfaceOrientationLandscapeLeft];
  XCTAssertEqualWithAccuracy(landscape.width, 852.0, 1e-9);
  XCTAssertEqualWithAccuracy(landscape.height, 393.0, 1e-9);
  // a landscape-native panel in an unknown orientation is told as portrait
  CGSize unknown = [TWTreeCommands pointSizeOfPixels:CGSizeMake(2556, 1179)
                                               scale:3
                                         orientation:UIInterfaceOrientationUnknown];
  XCTAssertEqualWithAccuracy(unknown.width, 393.0, 1e-9);
  XCTAssertEqualWithAccuracy(unknown.height, 852.0, 1e-9);
  CGSize unscaled = [TWTreeCommands pointSizeOfPixels:CGSizeMake(320, 480)
                                                scale:0
                                          orientation:UIInterfaceOrientationPortrait];
  XCTAssertEqualWithAccuracy(unscaled.width, 320.0, 1e-9);
  XCTAssertEqualWithAccuracy(unscaled.height, 480.0, 1e-9);
}

- (void)testOcrBoxesBecomeTopLeftScreenPoints
{
  CGRect rect = [TWOcrCommands screenRectOfNormalizedBox:CGRectMake(0.1, 0.7, 0.5, 0.2)
                                                  inSize:CGSizeMake(400, 800)];
  XCTAssertEqualWithAccuracy(rect.origin.x, 40.0, 1e-6);
  XCTAssertEqualWithAccuracy(rect.origin.y, 80.0, 1e-6);
  XCTAssertEqualWithAccuracy(rect.size.width, 200.0, 1e-6);
  XCTAssertEqualWithAccuracy(rect.size.height, 160.0, 1e-6);
  CGRect top = [TWOcrCommands screenRectOfNormalizedBox:CGRectMake(0, 0.9, 1, 0.1) inSize:CGSizeMake(400, 800)];
  XCTAssertEqualWithAccuracy(top.origin.y, 0.0, 1e-6);
  XCTAssertEqualWithAccuracy(top.size.height, 80.0, 1e-6);
  CGRect bottom = [TWOcrCommands screenRectOfNormalizedBox:CGRectMake(0, 0, 1, 0.1) inSize:CGSizeMake(400, 800)];
  XCTAssertEqualWithAccuracy(bottom.origin.y, 720.0, 1e-6);
}

- (void)testOcrPicturesAreTurnedUpright
{
  CGSize turned = [TWOcrCommands uprightSizeOf:CGSizeMake(1179, 2556) orientation:UIImageOrientationRight];
  XCTAssertEqualWithAccuracy(turned.width, 2556.0, 1e-9);
  XCTAssertEqualWithAccuracy(turned.height, 1179.0, 1e-9);
  CGSize upright = [TWOcrCommands uprightSizeOf:CGSizeMake(1179, 2556) orientation:UIImageOrientationUp];
  XCTAssertEqualWithAccuracy(upright.width, 1179.0, 1e-9);
  XCTAssertEqualWithAccuracy(upright.height, 2556.0, 1e-9);
  XCTAssertEqual((NSInteger)[TWOcrCommands propertyOrientationOf:UIImageOrientationUp],
                 (NSInteger)kCGImagePropertyOrientationUp);
  XCTAssertEqual((NSInteger)[TWOcrCommands propertyOrientationOf:UIImageOrientationRight],
                 (NSInteger)kCGImagePropertyOrientationRight);
  XCTAssertEqual((NSInteger)[TWOcrCommands propertyOrientationOf:UIImageOrientationLeft],
                 (NSInteger)kCGImagePropertyOrientationLeft);
  XCTAssertEqual((NSInteger)[TWOcrCommands propertyOrientationOf:UIImageOrientationDown],
                 (NSInteger)kCGImagePropertyOrientationDown);
}

- (void)testShotParametersAreParsed
{
  XCTAssertEqualObjects([TWOcrCommands pictureWidthFrom:nil], @0);
  XCTAssertEqualObjects([TWOcrCommands pictureWidthFrom:@"400"], @400);
  XCTAssertEqualObjects([TWOcrCommands pictureWidthFrom:@(400)], @400);
  XCTAssertEqualObjects([TWOcrCommands pictureWidthFrom:@"1"], @1);
  XCTAssertNil([TWOcrCommands pictureWidthFrom:@"0"]);
  XCTAssertNil([TWOcrCommands pictureWidthFrom:@"-5"]);
  XCTAssertNil([TWOcrCommands pictureWidthFrom:@"400.5"]);
  XCTAssertNil([TWOcrCommands pictureWidthFrom:@(400.5)]);
  XCTAssertNil([TWOcrCommands pictureWidthFrom:@"400px"]);
  XCTAssertNil([TWOcrCommands pictureWidthFrom:@""]);
  XCTAssertNil([TWOcrCommands pictureWidthFrom:@[]]);

  XCTAssertEqualObjects([TWOcrCommands pictureQualityFrom:nil], @70);
  XCTAssertEqualObjects([TWOcrCommands pictureQualityFrom:@"1"], @1);
  XCTAssertEqualObjects([TWOcrCommands pictureQualityFrom:@"100"], @100);
  XCTAssertEqualObjects([TWOcrCommands pictureQualityFrom:@(55)], @55);
  XCTAssertNil([TWOcrCommands pictureQualityFrom:@"0"]);
  XCTAssertNil([TWOcrCommands pictureQualityFrom:@"101"]);
  XCTAssertNil([TWOcrCommands pictureQualityFrom:@"0.7"]);
  XCTAssertNil([TWOcrCommands pictureQualityFrom:@"high"]);

  XCTAssertEqualObjects([TWOcrCommands imageFlagFrom:nil], @NO);
  XCTAssertEqualObjects([TWOcrCommands imageFlagFrom:@"1"], @YES);
  XCTAssertEqualObjects([TWOcrCommands imageFlagFrom:@"TRUE"], @YES);
  XCTAssertEqualObjects([TWOcrCommands imageFlagFrom:@"0"], @NO);
  XCTAssertEqualObjects([TWOcrCommands imageFlagFrom:@"false"], @NO);
  XCTAssertEqualObjects([TWOcrCommands imageFlagFrom:@(1)], @YES);
  XCTAssertEqualObjects([TWOcrCommands imageFlagFrom:@(0)], @NO);
  XCTAssertNil([TWOcrCommands imageFlagFrom:@"yes"]);
  XCTAssertNil([TWOcrCommands imageFlagFrom:@"2"]);
  XCTAssertNil([TWOcrCommands imageFlagFrom:@(2)]);

  // a picture sent as taken keeps its quality; a redrawn one is taken at 80 or more
  XCTAssertEqual([TWOcrCommands shotQualityFor:70 width:0], 70);
  XCTAssertEqual([TWOcrCommands shotQualityFor:30 width:0], 30);
  XCTAssertEqual([TWOcrCommands shotQualityFor:70 width:400], 80);
  XCTAssertEqual([TWOcrCommands shotQualityFor:95 width:400], 95);
}

- (void)testShotSizeIsClampedAndProportional
{
  CGSize portrait = CGSizeMake(1290, 2796);
  CGSize original = [TWOcrCommands sentSizeOf:portrait width:0];
  XCTAssertEqualWithAccuracy(original.width, 1290.0, 1e-9);
  XCTAssertEqualWithAccuracy(original.height, 2796.0, 1e-9);
  CGSize scaled = [TWOcrCommands sentSizeOf:portrait width:400]; // 2796 * 400 / 1290 = 866.98
  XCTAssertEqualWithAccuracy(scaled.width, 400.0, 1e-9);
  XCTAssertEqualWithAccuracy(scaled.height, 867.0, 1e-9);
  CGSize narrowest = [TWOcrCommands sentSizeOf:portrait width:50]; // clamped to 120: 2796 * 120 / 1290 = 260.09
  XCTAssertEqualWithAccuracy(narrowest.width, 120.0, 1e-9);
  XCTAssertEqualWithAccuracy(narrowest.height, 260.0, 1e-9);
  CGSize widest = [TWOcrCommands sentSizeOf:portrait width:5000];
  XCTAssertEqualWithAccuracy(widest.width, 1290.0, 1e-9);
  XCTAssertEqualWithAccuracy(widest.height, 2796.0, 1e-9);
  CGSize landscape = [TWOcrCommands sentSizeOf:CGSizeMake(2796, 1290) width:400]; // 1290 * 400 / 2796 = 184.55
  XCTAssertEqualWithAccuracy(landscape.width, 400.0, 1e-9);
  XCTAssertEqualWithAccuracy(landscape.height, 185.0, 1e-9);
  // a picture narrower than 120 pixels is never made wider
  CGSize tiny = [TWOcrCommands sentSizeOf:CGSizeMake(100, 200) width:400];
  XCTAssertEqualWithAccuracy(tiny.width, 100.0, 1e-9);
  XCTAssertEqualWithAccuracy(tiny.height, 200.0, 1e-9);
  CGSize empty = [TWOcrCommands sentSizeOf:CGSizeZero width:400];
  XCTAssertEqualWithAccuracy(empty.width, 0.0, 1e-9);
  XCTAssertEqualWithAccuracy(empty.height, 0.0, 1e-9);

  CGSize points = [TWOcrCommands pointSizeOf:portrait scale:3];
  XCTAssertEqualWithAccuracy(points.width, 430.0, 1e-9);
  XCTAssertEqualWithAccuracy(points.height, 932.0, 1e-9);
  CGSize unscaled = [TWOcrCommands pointSizeOf:CGSizeMake(320, 480) scale:0];
  XCTAssertEqualWithAccuracy(unscaled.width, 320.0, 1e-9);
  XCTAssertEqualWithAccuracy(unscaled.height, 480.0, 1e-9);
}

- (void)testStabilityWaitRestoresSettingsAfterAnException
{
  NSTimeInterval originalTimeout = FBConfiguration.sharedInstance.waitForIdleTimeout;
  FBQuiescenceApplicationDouble *application = [FBQuiescenceApplicationDouble new];
  XCUIElementDouble *element = [XCUIElementDouble new];
  element.application = (id)application;
  SEL selector = @selector(fb_waitUntilStableWithTimeout:);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-strict"
  void (*wait)(id, SEL, NSTimeInterval) = (void (*)(id, SEL, NSTimeInterval))
    class_getMethodImplementation(XCUIElement.class, selector);
#pragma clang diagnostic pop
  @try {
    FBConfiguration.sharedInstance.waitForIdleTimeout = 17;
    XCTAssertThrowsSpecificNamed(wait(element, selector, 2), NSException, @"QuiescenceFailure");
    XCTAssertEqual(application.observedTimeout, 2);
    XCTAssertFalse(application.fb_shouldWaitForQuiescence);
    XCTAssertEqual(FBConfiguration.sharedInstance.waitForIdleTimeout, 17);
  } @finally {
    FBConfiguration.sharedInstance.waitForIdleTimeout = originalTimeout;
  }
}

- (void)testTypesFiltering {
  NSMutableArray *elements = [NSMutableArray new];
  XCUIElementDouble *el1 = [XCUIElementDouble new];
  [elements addObject:el1];
  XCUIElementDouble *el2 = [XCUIElementDouble new];
  el2.elementType = XCUIElementTypeAlert;
  el2.wdType = @"XCUIElementTypeAlert";
  [elements addObject:el2];
  XCUIElementDouble *el3 = [XCUIElementDouble new];
  [elements addObject:el3];
  
  NSSet *result = [FBElementUtils uniqueElementTypesWithElements:elements];
  XCTAssertEqual([result count], 2);
}

@end
