/**
 * Tapwright: a fast touch at a screen point.
 *
 * POST /session/:sessionId/wda/tw/tap {x, y, duration?, wait?, orientation?}
 *   x, y        the point, in screen points (portrait unless `orientation` says otherwise)
 *   duration    seconds the finger rests before it lifts (default 0.05; a long press passes more)
 *   wait        NO (default): answer as soon as the event is queued for synthesis.
 *               YES: answer once XCTest's daemon has synthesized it (the touch has been played).
 *   orientation the UIInterfaceOrientation the point is expressed in (default portrait, 1)
 * GET /wda/tw/version -> {"tapwright": 1}, so a client can tell whether this route exists.
 *
 * Unlike /wda/tap and /actions, nothing here reads the application: no element lookup, no
 * snapshot, no interface orientation query and no idle or quiescence wait. One touch path is
 * built and handed to XCTest's event synthesizer on a serial background queue (the approach of
 * appium-ios PR #87), so the main thread, which serves every other route, is never blocked by it
 * and consecutive touches reach the daemon in the order they were asked for. The caller confirms
 * the effect by reading the screen afterwards.
 *
 * Kept in this one file so the fork rebases cleanly onto upstream.
 */

#import <Foundation/Foundation.h>
#import <stdatomic.h>

#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBLogger.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBRunLoopSpinner.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCUIDevice.h"

#if !TARGET_OS_TV && !TARGET_OS_WATCH

static const NSTimeInterval TWDefaultHold = 0.05;
static const NSTimeInterval TWMaxHold = 60.0;
static const NSTimeInterval TWSynthesisSlack = 10.0; // seconds a synthesis may take beyond the touch itself
static const int TWMaxPending = 8; // touches queued and not yet played before new ones are refused

static atomic_int twPending;

@interface TWFastTapCommands : NSObject <FBCommandHandler>
@end

@implementation TWFastTapCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/tw/version"].withoutSession respondWithTarget:self action:@selector(handleVersion:)],
    [[FBRoute GET:@"/wda/tw/version"] respondWithTarget:self action:@selector(handleVersion:)],
    [[FBRoute POST:@"/wda/tw/tap"] respondWithTarget:self action:@selector(handleTap:)],
  ];
}

+ (dispatch_queue_t)synthesisQueue
{
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                               QOS_CLASS_USER_INTERACTIVE, 0);
    queue = dispatch_queue_create("tapwright.fast-tap", attributes);
  });
  return queue;
}

+ (id<FBResponsePayload>)handleVersion:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{@"tapwright": @1});
}

+ (NSNumber *)finiteNumber:(id)value
{
  if (![value isKindOfClass:NSNumber.class]) {
    return nil;
  }
  double number = [(NSNumber *)value doubleValue];
  return isfinite(number) ? (NSNumber *)value : nil;
}

+ (XCSynthesizedEventRecord *)eventAtPoint:(CGPoint)point
                                      hold:(NSTimeInterval)hold
                               orientation:(UIInterfaceOrientation)orientation
{
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
  [path liftUpAtOffset:hold];
  XCSynthesizedEventRecord *event = [[XCSynthesizedEventRecord alloc] initWithName:@"Tapwright tap"
                                                              interfaceOrientation:orientation];
  [event addPointerEventPath:path];
  return event;
}

+ (id<FBResponsePayload>)handleTap:(FBRouteRequest *)request
{
  NSNumber *x = [self finiteNumber:request.arguments[@"x"]];
  NSNumber *y = [self finiteNumber:request.arguments[@"y"]];
  if (nil == x || nil == y) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"x and y must be finite numbers (screen points)"
                                                                       traceback:nil]);
  }
  NSTimeInterval hold = TWDefaultHold;
  id holdValue = request.arguments[@"duration"];
  if (nil != holdValue) {
    NSNumber *number = [self finiteNumber:holdValue];
    if (nil == number || number.doubleValue < 0 || number.doubleValue > TWMaxHold) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"duration must be 0-60 seconds"
                                                                         traceback:nil]);
    }
    hold = number.doubleValue;
  }
  UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
  id orientationValue = request.arguments[@"orientation"];
  if (nil != orientationValue) {
    NSNumber *number = [self finiteNumber:orientationValue];
    NSInteger value = number.integerValue;
    if (nil == number || value < UIInterfaceOrientationPortrait || value > UIInterfaceOrientationLandscapeRight) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"orientation must be 1-4 (UIInterfaceOrientation)"
                                                                         traceback:nil]);
    }
    orientation = (UIInterfaceOrientation)value;
  }
  BOOL wait = [request.arguments[@"wait"] respondsToSelector:@selector(boolValue)]
    && [request.arguments[@"wait"] boolValue];

  if (atomic_fetch_add(&twPending, 1) >= TWMaxPending) {
    atomic_fetch_sub(&twPending, 1);
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"too many touches are still being played; try again"
                                                               traceback:nil]);
  }
  XCSynthesizedEventRecord *event = [self eventAtPoint:CGPointMake(x.doubleValue, y.doubleValue)
                                                  hold:hold
                                           orientation:orientation];
  NSTimeInterval limit = hold + TWSynthesisSlack;
  // `failure` and `playedMs` are written by the queue before it signals `played`, and read by
  // the main thread only after that.
  dispatch_semaphore_t played = dispatch_semaphore_create(0);
  __block NSString *failure = nil;
  __block double playedMs = 0;
  dispatch_async([self synthesisQueue], ^{
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    __block NSError *synthesisError = nil;
    __block BOOL succeeded = NO;
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:event completion:^(_Bool result, NSError *error) {
      succeeded = result;
      synthesisError = error;
      dispatch_semaphore_signal(answered);
    }];
    long timedOut = dispatch_semaphore_wait(answered,
                                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)));
    playedMs = (CFAbsoluteTimeGetCurrent() - began) * 1000.0;
    if (0 != timedOut) {
      failure = [NSString stringWithFormat:@"the touch was not played within %.0f s", limit];
    } else if (nil != synthesisError || !succeeded) {
      failure = synthesisError.localizedDescription ?: @"XCTest could not play the touch";
    }
    if (nil != failure) {
      [FBLogger logFmt:@"Tapwright tap at (%@, %@): %@", x, y, failure];
    }
    atomic_fetch_sub(&twPending, 1);
    dispatch_semaphore_signal(played);
  });
  if (!wait) {
    return FBResponseWithOK();
  }
  // The main run loop keeps turning while the touch plays: XCTest may answer on the main queue.
  NSError *spinError = nil;
  BOOL isPlayed = [[[[FBRunLoopSpinner new]
                     timeout:limit + 1.0]
                    interval:0.005]
                   spinUntilTrue:^BOOL{
    return 0 == dispatch_semaphore_wait(played, DISPATCH_TIME_NOW);
  } error:&spinError];
  if (!isPlayed) {
    return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:@"the touch was not played in time"
                                                               traceback:nil]);
  }
  if (nil != failure) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:failure traceback:nil]);
  }
  return FBResponseWithObject(@{@"ms": @(round(playedMs))});
}

@end

#endif
