/**
 * Tapwright: test pictures for an app's photo picker (docs/AGENT-TOOLS.md 17.6, `media`).
 *
 * GET  /session/:sessionId/wda/tw/photos/access
 *        -> {"add": "authorized|limited|denied|restricted|notDetermined", "full": <the same>}
 *        What iOS lets this runner do with the photo library: "add" is add-only access, "full" is read and write.
 *        Asking changes nothing and shows no prompt.
 * POST /session/:sessionId/wda/tw/photos/add {images: [base64, ...], names: [string, ...]?}
 *        Adds each picture (jpeg, png or heic bytes) to the library with ADD-ONLY access, so the runner never reads
 *        the library. When iOS hasn't been asked yet it asks the person once ("Allow ... to add to your photos?")
 *        and the answer waits for them. Answers {"identifiers": [local identifier, ...]} in the order sent.
 *        `names` become the pictures' file names (Photos > Recently Added shows them in the info sheet).
 * POST /session/:sessionId/wda/tw/photos/delete {identifiers: [string, ...]}
 *        Deletes pictures by the local identifiers `add` returned. Deleting needs FULL access, which iOS asks the
 *        person for once, and iOS asks them to confirm each delete (nothing here taps that for them). Answers
 *        {"deleted": n}: 0 when they were already gone or the person declined. Without full access it answers an
 *        error whose message starts "full access to the photo library is needed", which the client words for the user.
 *
 * Route version 3 (GET /wda/tw/version answers {"tapwright": 3}; see TWFastTapCommands.m for 1 and 2).
 *
 * Kept in this one file so the fork rebases cleanly onto upstream. The Info.plist of WebDriverAgentRunner holds the
 * two usage descriptions iOS shows in its prompts (NSPhotoLibraryAddUsageDescription, NSPhotoLibraryUsageDescription).
 */

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>

#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBLogger.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBRunLoopSpinner.h"

#if !TARGET_OS_TV && !TARGET_OS_WATCH

static const NSUInteger TWMaxPictures = 20;
static const NSTimeInterval TWPhotosPromptWait = 120.0; // seconds a person has to answer iOS's prompt
static const NSTimeInterval TWPhotosChangeWait = 120.0; // seconds a change may take (a delete waits for the person's confirm)

@interface TWPhotosCommands : NSObject <FBCommandHandler>
@end

@implementation TWPhotosCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/tw/photos/access"] respondWithTarget:self action:@selector(handleAccess:)],
    [[FBRoute POST:@"/wda/tw/photos/add"] respondWithTarget:self action:@selector(handleAdd:)],
    [[FBRoute POST:@"/wda/tw/photos/delete"] respondWithTarget:self action:@selector(handleDelete:)],
  ];
}

+ (NSString *)nameOfStatus:(PHAuthorizationStatus)status
{
  switch (status) {
    case PHAuthorizationStatusAuthorized:
      return @"authorized";
    case PHAuthorizationStatusLimited:
      return @"limited";
    case PHAuthorizationStatusDenied:
      return @"denied";
    case PHAuthorizationStatusRestricted:
      return @"restricted";
    case PHAuthorizationStatusNotDetermined:
    default:
      return @"notDetermined";
  }
}

+ (BOOL)allows:(PHAuthorizationStatus)status
{
  return PHAuthorizationStatusAuthorized == status || PHAuthorizationStatusLimited == status;
}

/** Spins the main run loop until `done` is signalled or `limit` seconds pass; YES when it was signalled. */
+ (BOOL)waitFor:(dispatch_semaphore_t)done limit:(NSTimeInterval)limit
{
  NSError *spinError = nil;
  return [[[[FBRunLoopSpinner new]
            timeout:limit]
           interval:0.01]
          spinUntilTrue:^BOOL{
    return 0 == dispatch_semaphore_wait(done, DISPATCH_TIME_NOW);
  } error:&spinError];
}

/** The access level's status; when iOS hasn't been asked, asks (the person answers on the phone) and waits. */
+ (PHAuthorizationStatus)statusFor:(PHAccessLevel)level askIfNeeded:(BOOL)ask
{
  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:level];
  if (PHAuthorizationStatusNotDetermined != status || !ask) {
    return status;
  }
  dispatch_semaphore_t answered = dispatch_semaphore_create(0);
  __block PHAuthorizationStatus granted = PHAuthorizationStatusNotDetermined;
  [PHPhotoLibrary requestAuthorizationForAccessLevel:level handler:^(PHAuthorizationStatus newStatus) {
    granted = newStatus;
    dispatch_semaphore_signal(answered);
  }];
  if (![self waitFor:answered limit:TWPhotosPromptWait]) {
    [FBLogger logFmt:@"Tapwright photos: nobody answered iOS's photo library prompt within %.0f s", TWPhotosPromptWait];
    return PHAuthorizationStatusNotDetermined;
  }
  return granted;
}

+ (id<FBResponsePayload>)handleAccess:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{
    @"add": [self nameOfStatus:[self statusFor:PHAccessLevelAddOnly askIfNeeded:NO]],
    @"full": [self nameOfStatus:[self statusFor:PHAccessLevelReadWrite askIfNeeded:NO]],
  });
}

+ (id<FBResponsePayload>)handleAdd:(FBRouteRequest *)request
{
  id images = request.arguments[@"images"];
  if (![images isKindOfClass:NSArray.class] || 0 == [(NSArray *)images count]
      || [(NSArray *)images count] > TWMaxPictures) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"images must be a list of 1-20 base64 pictures"
                                                                       traceback:nil]);
  }
  NSArray *list = (NSArray *)images;
  id namesValue = request.arguments[@"names"];
  NSArray *names = [namesValue isKindOfClass:NSArray.class] ? (NSArray *)namesValue : nil;
  if (nil != names && names.count != list.count) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"names must have one name for each picture"
                                                                       traceback:nil]);
  }
  NSMutableArray<NSData *> *pictures = [NSMutableArray arrayWithCapacity:list.count];
  for (id item in list) {
    NSData *data = [item isKindOfClass:NSString.class]
      ? [[NSData alloc] initWithBase64EncodedString:item options:NSDataBase64DecodingIgnoreUnknownCharacters]
      : nil;
    if (nil == data || 0 == data.length) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"every picture must be base64 picture data"
                                                                         traceback:nil]);
    }
    [pictures addObject:data];
  }

  PHAuthorizationStatus status = [self statusFor:PHAccessLevelAddOnly askIfNeeded:YES];
  if (![self allows:status]) {
    NSString *message = [NSString stringWithFormat:@"the runner may not add to the photo library (iOS says %@)",
                         [self nameOfStatus:status]];
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:message traceback:nil]);
  }

  NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:pictures.count];
  dispatch_semaphore_t changed = dispatch_semaphore_create(0);
  __block BOOL succeeded = NO;
  __block NSError *changeError = nil;
  [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
    for (NSUInteger i = 0; i < pictures.count; i++) {
      PHAssetCreationRequest *creation = [PHAssetCreationRequest creationRequestForAsset];
      PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
      id name = nil != names ? names[i] : nil;
      if ([name isKindOfClass:NSString.class] && [(NSString *)name length] > 0) {
        options.originalFilename = name;
      }
      [creation addResourceWithType:PHAssetResourceTypePhoto data:pictures[i] options:options];
      [identifiers addObject:creation.placeholderForCreatedAsset.localIdentifier];
    }
  } completionHandler:^(BOOL success, NSError *error) {
    succeeded = success;
    changeError = error;
    dispatch_semaphore_signal(changed);
  }];
  if (![self waitFor:changed limit:TWPhotosChangeWait]) {
    return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:@"adding the pictures took too long; check Photos > Recently Added"
                                                               traceback:nil]);
  }
  if (!succeeded) {
    NSString *message = [NSString stringWithFormat:@"the photo library refused the pictures: %@",
                         changeError.localizedDescription ?: @"unknown error"];
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:message traceback:nil]);
  }
  return FBResponseWithObject(@{@"identifiers": identifiers});
}

+ (id<FBResponsePayload>)handleDelete:(FBRouteRequest *)request
{
  id value = request.arguments[@"identifiers"];
  if (![value isKindOfClass:NSArray.class] || 0 == [(NSArray *)value count]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"identifiers must be a list of local identifiers"
                                                                       traceback:nil]);
  }
  for (id item in (NSArray *)value) {
    if (![item isKindOfClass:NSString.class] || 0 == [(NSString *)item length]) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"identifiers must be non-empty strings"
                                                                         traceback:nil]);
    }
  }
  PHAuthorizationStatus status = [self statusFor:PHAccessLevelReadWrite askIfNeeded:YES];
  if (![self allows:status]) {
    NSString *message = [NSString stringWithFormat:@"full access to the photo library is needed to delete pictures (iOS says %@)",
                         [self nameOfStatus:status]];
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:message traceback:nil]);
  }

  PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:(NSArray *)value options:nil];
  if (0 == assets.count) {
    return FBResponseWithObject(@{@"deleted": @0}); // already gone
  }
  NSUInteger count = assets.count;
  dispatch_semaphore_t changed = dispatch_semaphore_create(0);
  __block BOOL succeeded = NO;
  __block NSError *changeError = nil;
  [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
    [PHAssetChangeRequest deleteAssets:assets];
  } completionHandler:^(BOOL success, NSError *error) {
    succeeded = success;
    changeError = error;
    dispatch_semaphore_signal(changed);
  }];
  // iOS shows its own "Delete N Photos?" confirmation and waits for the person, so this may take a while.
  if (![self waitFor:changed limit:TWPhotosChangeWait]) {
    return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:@"the delete wasn't confirmed on the phone in time"
                                                               traceback:nil]);
  }
  if (!succeeded) {
    if ([changeError.domain isEqualToString:PHPhotosErrorDomain] && PHPhotosErrorUserCancelled == changeError.code) {
      return FBResponseWithObject(@{@"deleted": @0}); // the person said no
    }
    NSString *message = [NSString stringWithFormat:@"the photo library couldn't delete the pictures: %@",
                         changeError.localizedDescription ?: @"unknown error"];
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:message traceback:nil]);
  }
  return FBResponseWithObject(@{@"deleted": @(count)});
}

@end

#endif
