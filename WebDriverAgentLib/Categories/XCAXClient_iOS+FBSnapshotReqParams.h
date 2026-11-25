/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "XCAXClient_iOS.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const FBSnapshotMaxChildrenKey;
extern NSString *const FBSnapshotMaxDepthKey;

void FBSetCustomParameterForElementSnapshot (NSString* name, id value);

id __nullable FBGetCustomParameterForElementSnapshot (NSString *name);

/**
 Tapwright (route version 9): a deadline, as NSProcessInfo.systemUptime, for every accessibility snapshot request
 this process makes until it is cleared with 0. A request made after it fails at once with an error, and the
 run loop responsiveness check of `accessibilityDeadline` (#1210) waits no longer than it, so XCTest's own retries
 of a failed snapshot can't take longer than the bounded read that set it (TWTreeCommands.m).
 */
void TWSetSnapshotRequestDeadline(NSTimeInterval deadline);

@interface XCAXClient_iOS (FBSnapshotReqParams)

@end

NS_ASSUME_NONNULL_END
