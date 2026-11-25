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
@end

@interface TWOcrCommands : NSObject
+ (CGImagePropertyOrientation)propertyOrientationOf:(UIImageOrientation)orientation;
+ (CGSize)uprightSizeOf:(CGSize)size orientation:(UIImageOrientation)orientation;
+ (CGRect)screenRectOfNormalizedBox:(CGRect)box inSize:(CGSize)size;
@end

// Private Tapwright command methods, exercised with synthetic AX identities only.
@interface TWHitCommands : NSObject
+ (BOOL)snapshot:(id)snapshot matchesHit:(id)hit;
+ (id)verifiedSnapshotOf:(id)hit inApplication:(id)application via:(NSString * __autoreleasing *)via;
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
