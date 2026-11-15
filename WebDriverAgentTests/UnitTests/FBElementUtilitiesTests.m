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
