/**
 * Tapwright: a fast touch at a screen point.
 *
 * POST /session/:sessionId/wda/tw/tap {x, y, duration?, wait?, orientation?, apps?}
 *   x, y        the point, in screen points (portrait unless `orientation` says otherwise)
 *   duration    seconds the finger rests before it lifts (default 0.05; a long press passes more)
 *   wait        NO (default): answer as soon as the event is queued for synthesis.
 *               YES: answer once XCTest's daemon has synthesized it (the touch has been played).
 *   orientation the UIInterfaceOrientation the point is expressed in (default portrait, 1)
 *   apps        (version 4) bundle ids: the touch is made only while one of these apps is in front, as
 *               GET /wda/activeAppInfo (without a session) names it, asked just before the touch is queued.
 *               Otherwise nothing is touched and the answer is an "invalid element state" error whose message
 *               starts "tapwright front:" and names the app in front ("unknown" when it can't be told), so the client
 *               can ask its own way. It is also refused that way while another touch is still being played (the
 *               check would not be the touch's).
 * POST /session/:sessionId/wda/tw/drag {points: [[t_ms, x, y], ...], orientation?}
 *   points      the finger's path, at least two points: it presses at the first point at its time, moves
 *               through each later point at its time (XCTest moves it in a straight line between them), and
 *               lifts at the last point's time. A last point where the finger already is makes it rest there
 *               before it lifts. Times are milliseconds from the press, in order, at most 60 s in all.
 *   orientation as for tap
 *   The answer comes once the whole drag has been played: {"ms": <synthesis ms>}.
 * GET /wda/tw/version -> {"tapwright": 4} (1: tap only; 2: tap and drag; 3: and the photo routes of
 * TWPhotosCommands.m; 4: and the compact tree read of TWTreeCommands.m, and the tap's `apps`), so a client can tell
 * which routes exist.
 *
 * Unlike /wda/tap and /actions, nothing here reads the application: no element lookup, no
 * snapshot, no interface orientation query and no idle or quiescence wait. One touch path is
 * built and handed to XCTest's event synthesizer on a serial background queue (the approach of
 * appium-ios PR #87), so the main thread, which serves every other route, is never blocked by it
 * and consecutive touches reach the daemon in the order they were asked for. The caller confirms
 * the effect by reading the screen afterwards.
 *
 * A drag is played the same way: one touch path, on the same queue, so a drag and the touches around it never
 * overlap.
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
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIDevice.h"

#if !TARGET_OS_TV && !TARGET_OS_WATCH

static const NSTimeInterval TWDefaultHold = 0.05;
static const NSTimeInterval TWMaxHold = 60.0;
static const NSTimeInterval TWSynthesisSlack = 10.0; // seconds a synthesis may take beyond the touch itself
static const int TWMaxPending = 8; // touches queued and not yet played before new ones are refused
static const NSUInteger TWMaxDragPoints = 1000;

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
    [[FBRoute POST:@"/wda/tw/drag"] respondWithTarget:self action:@selector(handleDrag:)],
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
  return FBResponseWithObject(@{@"tapwright": @4});
}

+ (NSNumber *)finiteNumber:(id)value
{
  if (![value isKindOfClass:NSNumber.class]) {
    return nil;
  }
  double number = [(NSNumber *)value doubleValue];
  return isfinite(number) ? (NSNumber *)value : nil;
}

/** The request's orientation into `orientation` (portrait when absent); NO when it isn't 1-4. */
+ (BOOL)orientation:(UIInterfaceOrientation *)orientation from:(FBRouteRequest *)request
{
  *orientation = UIInterfaceOrientationPortrait;
  id orientationValue = request.arguments[@"orientation"];
  if (nil == orientationValue) {
    return YES;
  }
  NSNumber *number = [self finiteNumber:orientationValue];
  NSInteger value = number.integerValue;
  if (nil == number || value < UIInterfaceOrientationPortrait || value > UIInterfaceOrientationLandscapeRight) {
    return NO;
  }
  *orientation = (UIInterfaceOrientation)value;
  return YES;
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
  UIInterfaceOrientation orientation;
  if (![self orientation:&orientation from:request]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"orientation must be 1-4 (UIInterfaceOrientation)"
                                                                       traceback:nil]);
  }
  BOOL wait = [request.arguments[@"wait"] respondsToSelector:@selector(boolValue)]
    && [request.arguments[@"wait"] boolValue];
  id apps = request.arguments[@"apps"];
  if (nil != apps) {
    if (![self isListOfStrings:apps]) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"apps must be a list of bundle ids"
                                                                         traceback:nil]);
    }
    NSString *refusal = [self refusalFor:(NSArray<NSString *> *)apps];
    if (nil != refusal) {
      return FBResponseWithStatus([FBCommandStatus invalidElementStateErrorWithMessage:refusal traceback:nil]);
    }
  }

  XCSynthesizedEventRecord *event = [self eventAtPoint:CGPointMake(x.doubleValue, y.doubleValue)
                                                  hold:hold
                                           orientation:orientation];
  return [self play:event
              limit:hold + TWSynthesisSlack
               wait:wait
               what:[NSString stringWithFormat:@"tap at (%@, %@)", x, y]];
}

+ (BOOL)isListOfStrings:(id)value
{
  if (![value isKindOfClass:NSArray.class] || 0 == [(NSArray *)value count]) {
    return NO;
  }
  for (id item in (NSArray *)value) {
    if (![item isKindOfClass:NSString.class] || 0 == [(NSString *)item length]) {
      return NO;
    }
  }
  return YES;
}

/**
 * Why a touch for `apps` must not be made now, or nil when one of them is in front. The app in front is the one
 * GET /wda/activeAppInfo names when it is asked without a session, as Tapwright asks it (FBCustomCommands.m).
 * Anything that can't be told (an error, no bundle id) refuses: nothing is touched on doubt.
 */
+ (nullable NSString *)refusalFor:(NSArray<NSString *> *)apps
{
  if (atomic_load(&twPending) > 0) {
    return @"tapwright front: unknown is in front (another touch is still being played); nothing was touched";
  }
  NSString *front = nil;
  @try {
    front = XCUIApplication.fb_activeApplication.bundleID;
  } @catch (NSException *e) {
    [FBLogger logFmt:@"Tapwright tap: the app in front can't be told: %@", e.reason];
    front = nil;
  }
  if (front.length > 0 && [apps containsObject:(NSString *)front]) {
    return nil;
  }
  return [NSString stringWithFormat:@"tapwright front: %@ is in front, not one of the given apps; nothing was touched",
          front.length > 0 ? front : @"unknown"];
}

+ (id<FBResponsePayload>)handleDrag:(FBRouteRequest *)request
{
  id points = request.arguments[@"points"];
  if (![points isKindOfClass:NSArray.class] || [(NSArray *)points count] < 2
      || [(NSArray *)points count] > TWMaxDragPoints) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"points must be a list of 2-1000 [t_ms, x, y]"
                                                                       traceback:nil]);
  }
  UIInterfaceOrientation orientation;
  if (![self orientation:&orientation from:request]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"orientation must be 1-4 (UIInterfaceOrientation)"
                                                                       traceback:nil]);
  }
  NSArray *list = (NSArray *)points;
  NSUInteger count = list.count;
  NSMutableArray<NSNumber *> *times = [NSMutableArray arrayWithCapacity:count];
  NSMutableArray<NSValue *> *where = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger i = 0; i < count; i++) {
    id point = [list objectAtIndex:i];
    NSNumber *t = nil;
    NSNumber *x = nil;
    NSNumber *y = nil;
    if ([point isKindOfClass:NSArray.class] && 3 == [(NSArray *)point count]) {
      t = [self finiteNumber:[(NSArray *)point objectAtIndex:0]];
      x = [self finiteNumber:[(NSArray *)point objectAtIndex:1]];
      y = [self finiteNumber:[(NSArray *)point objectAtIndex:2]];
    }
    if (nil == t || nil == x || nil == y) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"each point must be [t_ms, x, y], finite numbers"
                                                                         traceback:nil]);
    }
    double seconds = t.doubleValue / 1000.0;
    if (seconds < 0 || seconds > TWMaxHold || (i > 0 && seconds < times[i - 1].doubleValue)) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"point times must be in order, 0-60000 ms"
                                                                         traceback:nil]);
    }
    [times addObject:@(seconds)];
    [where addObject:[NSValue valueWithCGPoint:CGPointMake(x.doubleValue, y.doubleValue)]];
  }
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:where[0].CGPointValue
                                                                      offset:times[0].doubleValue];
  for (NSUInteger i = 1; i < count; i++) {
    // a last point where the finger already is: it rests there until it lifts (no move, as with W3C's pause)
    BOOL rests = (i == count - 1) && CGPointEqualToPoint(where[i].CGPointValue, where[i - 1].CGPointValue);
    if (!rests) {
      [path moveToPoint:where[i].CGPointValue atOffset:times[i].doubleValue];
    }
  }
  NSTimeInterval end = times[count - 1].doubleValue;
  [path liftUpAtOffset:end];
  XCSynthesizedEventRecord *event = [[XCSynthesizedEventRecord alloc] initWithName:@"Tapwright drag"
                                                              interfaceOrientation:orientation];
  [event addPointerEventPath:path];
  return [self play:event
              limit:end + TWSynthesisSlack
               wait:YES
               what:[NSString stringWithFormat:@"drag of %lu points", (unsigned long)count]];
}

/**
 * Plays the event on the synthesis queue. Without `wait` it answers once the event is queued; with it, once XCTest
 * has played it ({"ms": <synthesis ms>}) or failed to. At most TWMaxPending events wait at once.
 */
+ (id<FBResponsePayload>)play:(XCSynthesizedEventRecord *)event
                        limit:(NSTimeInterval)limit
                         wait:(BOOL)wait
                         what:(NSString *)what
{
  if (atomic_fetch_add(&twPending, 1) >= TWMaxPending) {
    atomic_fetch_sub(&twPending, 1);
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"too many touches are still being played; try again"
                                                               traceback:nil]);
  }
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
      [FBLogger logFmt:@"Tapwright %@: %@", what, failure];
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
