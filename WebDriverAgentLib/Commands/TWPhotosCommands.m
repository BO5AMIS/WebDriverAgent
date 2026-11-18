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
 *        Version 7 also takes {items: [{kind: "photo", data: base64, name?} | {kind: "video", file: path, name?}]}:
 *        a video is a .mp4/.mov the computer uploaded into this runner's container over house_arrest, `file` relative
 *        to the container and under tmp/tapwright-media/. It is added by file URL and moved into the library
 *        (shouldMoveFile), never read into memory, and only when iOS says the library takes videos
 *        (supportsAssetResourceTypes). At most 5 videos, 200 MB each and 400 MB together; the change may take up to
 *        10 minutes for big clips. Every staged file the call names is removed when it ends: added, refused or failed
 *        (after a timeout, when the change finishes).
 * POST /session/:sessionId/wda/tw/photos/delete {identifiers: [string, ...]}
 *        Deletes pictures by the local identifiers `add` returned. Deleting needs FULL access, which iOS asks the
 *        person for once, and iOS asks them to confirm each delete (nothing here taps that for them). Answers
 *        {"deleted": n}: 0 when they were already gone or the person declined. Without full access it answers an
 *        error whose message starts "full access to the photo library is needed", which the client words for the user.
 *
 * Route version 3 (GET /wda/tw/version answers {"tapwright": 3}; see TWFastTapCommands.m for 1 and 2); videos in
 * add (`items`) from version 7.
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
static const unsigned long long TWMaxBytes = 40ULL * 1024 * 1024; // all pictures of one call together (the computer caps it too)
// PHAuthorizationStatusLimited (iOS 14); written as its number so the file builds with an older deployment target
static const NSInteger TWStatusLimited = 4;
static const NSTimeInterval TWPhotosPromptWait = 120.0; // seconds a person has to answer iOS's prompt
static const NSTimeInterval TWPhotosChangeWait = 120.0; // seconds a change may take (a delete waits for the person's confirm)
static const NSTimeInterval TWPhotosChangeWaitMax = 600.0; // seconds an add with big clips may take at most
static const NSUInteger TWMaxVideos = 5; // per add
static const unsigned long long TWMaxVideoBytes = 200ULL * 1024 * 1024; // per clip (the computer caps it too)
static const unsigned long long TWMaxVideoTotal = 400ULL * 1024 * 1024; // all clips of one add together
static NSString *const TWStagingFolder = @"tapwright-media"; // under the container's tmp

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
    case PHAuthorizationStatusDenied:
      return @"denied";
    case PHAuthorizationStatusRestricted:
      return @"restricted";
    case PHAuthorizationStatusNotDetermined:
      return @"notDetermined";
    default:
      return TWStatusLimited == (NSInteger)status ? @"limited" : @"notDetermined";
  }
}

+ (BOOL)allows:(PHAuthorizationStatus)status
{
  return PHAuthorizationStatusAuthorized == status || TWStatusLimited == (NSInteger)status;
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

/**
 * The access level's status (`full`: read and write; else add-only); when iOS hasn't been asked, asks (the person
 * answers on the phone) and waits. The access levels exist from iOS 14; before that there is one status for both.
 */
+ (PHAuthorizationStatus)statusForFullAccess:(BOOL)full askIfNeeded:(BOOL)ask
{
  PHAuthorizationStatus status;
  if (@available(iOS 14.0, *)) {
    status = [PHPhotoLibrary authorizationStatusForAccessLevel:full ? PHAccessLevelReadWrite : PHAccessLevelAddOnly];
  } else {
    status = [PHPhotoLibrary authorizationStatus];
  }
  if (PHAuthorizationStatusNotDetermined != status || !ask) {
    return status;
  }
  dispatch_semaphore_t answered = dispatch_semaphore_create(0);
  __block PHAuthorizationStatus granted = PHAuthorizationStatusNotDetermined;
  void (^handler)(PHAuthorizationStatus) = ^(PHAuthorizationStatus newStatus) {
    granted = newStatus;
    dispatch_semaphore_signal(answered);
  };
  if (@available(iOS 14.0, *)) {
    [PHPhotoLibrary requestAuthorizationForAccessLevel:full ? PHAccessLevelReadWrite : PHAccessLevelAddOnly handler:handler];
  } else {
    [PHPhotoLibrary requestAuthorization:handler];
  }
  if (![self waitFor:answered limit:TWPhotosPromptWait]) {
    [FBLogger logFmt:@"Tapwright photos: nobody answered iOS's photo library prompt within %.0f s", TWPhotosPromptWait];
    return PHAuthorizationStatusNotDetermined;
  }
  return granted;
}

+ (id<FBResponsePayload>)handleAccess:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{
    @"add": [self nameOfStatus:[self statusForFullAccess:NO askIfNeeded:NO]],
    @"full": [self nameOfStatus:[self statusForFullAccess:YES askIfNeeded:NO]],
  });
}

+ (void)removeStaged:(NSArray<NSURL *> *)staged
{
  for (NSURL *url in staged) {
    [NSFileManager.defaultManager removeItemAtURL:url error:nil]; // (moved into the library already: nothing there)
  }
}

/** A refusal of an add: removes the staged clips first (the computer removes them too; neither may leave one behind). */
+ (id<FBResponsePayload>)refuse:(FBCommandStatus *)status removing:(NSArray<NSURL *> *)staged
{
  [self removeStaged:staged];
  return FBResponseWithStatus(status);
}

/** The staging folder the computer uploads clips into over house_arrest: <container>/tmp/tapwright-media. */
+ (NSString *)stagingRoot
{
  return [[NSHomeDirectory() stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:TWStagingFolder];
}

/**
 * The staged clip a container-relative path names, or nil (and `why`) when it is not a plain file inside the staging
 * folder: no absolute path, no "." or "..", no link anywhere in it (each component is read without following links),
 * nothing outside tmp/tapwright-media, before or after resolving links.
 */
+ (NSURL *)stagedFile:(id)value size:(unsigned long long *)size why:(NSString **)why
{
  if (![value isKindOfClass:NSString.class] || 0 == [(NSString *)value length]) {
    *why = @"every video must name its staged file";
    return nil;
  }
  NSString *relative = (NSString *)value;
  NSString *prefix = [@"tmp/" stringByAppendingString:TWStagingFolder];
  if ([relative hasPrefix:@"/"] || ![relative hasPrefix:[prefix stringByAppendingString:@"/"]]
      || [relative.pathComponents containsObject:@".."] || [relative.pathComponents containsObject:@"."]) {
    *why = [NSString stringWithFormat:@"a staged file must be under %@/ in the runner's container", prefix];
    return nil;
  }
  NSString *root = [self stagingRoot].stringByStandardizingPath;
  NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:relative].stringByStandardizingPath;
  if (![path hasPrefix:[root stringByAppendingString:@"/"]]) {
    *why = @"a staged file must be inside the staging folder";
    return nil;
  }
  // Every component from the container down is read without following links (attributesOfItemAtPath is an lstat):
  // each folder must be a plain folder and the last a plain file. A folder that is a link elsewhere in the sandbox
  // would let a path that reads as inside the staging folder name a file outside it (review R179 L4).
  NSArray<NSString *> *components = relative.pathComponents;
  NSString *walked = NSHomeDirectory();
  NSDictionary<NSFileAttributeKey, id> *attributes = nil;
  for (NSUInteger i = 0; i < components.count; i++) {
    walked = [walked stringByAppendingPathComponent:components[i]];
    attributes = [NSFileManager.defaultManager attributesOfItemAtPath:walked error:nil];
    if (nil == attributes) {
      *why = [NSString stringWithFormat:@"no staged file at %@", relative];
      return nil;
    }
    if (i + 1 < components.count && ![attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
      *why = [NSString stringWithFormat:@"%@ is not in plain folders (a link is never followed)", relative];
      return nil;
    }
  }
  if (nil == attributes || ![attributes[NSFileType] isEqual:NSFileTypeRegular]) {
    *why = [NSString stringWithFormat:@"%@ is not a plain file", relative];
    return nil;
  }
  // and with every link resolved, it is still inside the staging folder (resolved the same way)
  NSString *resolvedRoot = [self stagingRoot].stringByResolvingSymlinksInPath;
  if (![path.stringByResolvingSymlinksInPath hasPrefix:[resolvedRoot stringByAppendingString:@"/"]]) {
    *why = @"a staged file must be inside the staging folder";
    return nil;
  }
  *size = [attributes[NSFileSize] unsignedLongLongValue];
  return [NSURL fileURLWithPath:path isDirectory:NO];
}

+ (id<FBResponsePayload>)handleAdd:(FBRouteRequest *)request
{
  // Two shapes. Version 3: {images: [base64, ...], names?}, pictures only. Version 7: {items: [{kind: "photo",
  // data: base64, name?} | {kind: "video", file: "tmp/tapwright-media/...", name?}, ...]}, in the order the
  // identifiers come back. A video is a file the computer staged in this runner's container (house_arrest), added by
  // file URL and moved into the library, so a clip is never held in memory.
  NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
  NSTimeInterval changeWait = TWPhotosChangeWait;
  NSMutableArray<NSURL *> *staged = [NSMutableArray array];
  id itemsValue = request.arguments[@"items"];
  if (nil != itemsValue) {
    if (![itemsValue isKindOfClass:NSArray.class]) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"items must be a list"
                                                                         traceback:nil]);
    }
    NSArray *list = (NSArray *)itemsValue;
    // every staged file the call names is removed on a refusal, whatever else is wrong with the call
    for (id item in list) {
      NSString *why = nil;
      unsigned long long ignored = 0;
      NSURL *url = [item isKindOfClass:NSDictionary.class] && [@"video" isEqual:((NSDictionary *)item)[@"kind"]]
        ? [self stagedFile:((NSDictionary *)item)[@"file"] size:&ignored why:&why] : nil;
      if (nil != url) {
        [staged addObject:url];
      }
    }
    if (0 == list.count || list.count > TWMaxPictures) {
      return [self refuse:[FBCommandStatus invalidArgumentErrorWithMessage:@"items must be a list of 1-20 pictures and videos"
                                                                 traceback:nil] removing:staged];
    }
    unsigned long long total = 0, videoTotal = 0;
    NSUInteger videos = 0;
    for (id item in list) {
      if (![item isKindOfClass:NSDictionary.class]) {
        return [self refuse:[FBCommandStatus invalidArgumentErrorWithMessage:@"every item must be an object"
                                                                   traceback:nil] removing:staged];
      }
      NSDictionary *entry = (NSDictionary *)item;
      id name = entry[@"name"];
      NSString *named = [name isKindOfClass:NSString.class] ? (NSString *)name : @"";
      if ([@"photo" isEqual:entry[@"kind"]]) {
        id encoded = entry[@"data"];
        // a base64 string is a third bigger than its bytes: refuse before decoding what is over the cap
        if ([encoded isKindOfClass:NSString.class]) {
          total += (unsigned long long)([(NSString *)encoded length] / 4 * 3);
          if (total > TWMaxBytes) {
            return [self refuse:[FBCommandStatus invalidArgumentErrorWithMessage:@"the pictures together are over the 40 MB limit"
                                                                       traceback:nil] removing:staged];
          }
        }
        NSData *data = [encoded isKindOfClass:NSString.class]
          ? [[NSData alloc] initWithBase64EncodedString:(NSString *)encoded options:NSDataBase64DecodingIgnoreUnknownCharacters]
          : nil;
        if (nil == data || 0 == data.length) {
          return [self refuse:[FBCommandStatus invalidArgumentErrorWithMessage:@"every picture must be base64 picture data"
                                                                     traceback:nil] removing:staged];
        }
        [items addObject:@{@"kind": @"photo", @"data": data, @"name": named}];
      } else if ([@"video" isEqual:entry[@"kind"]]) {
        NSString *why = nil;
        unsigned long long size = 0;
        NSURL *url = [self stagedFile:entry[@"file"] size:&size why:&why];
        if (nil == url) {
          return [self refuse:[FBCommandStatus invalidArgumentErrorWithMessage:why traceback:nil] removing:staged];
        }
        videos += 1;
        videoTotal += size;
        if (videos > TWMaxVideos || size > TWMaxVideoBytes || videoTotal > TWMaxVideoTotal) {
          NSString *message = [NSString stringWithFormat:@"at most %lu videos of %llu MB each, %llu MB together, in one add",
                               (unsigned long)TWMaxVideos, TWMaxVideoBytes / 1048576, TWMaxVideoTotal / 1048576];
          return [self refuse:[FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil] removing:staged];
        }
        [items addObject:@{@"kind": @"video", @"url": url, @"name": named}];
      } else {
        return [self refuse:[FBCommandStatus invalidArgumentErrorWithMessage:@"an item's kind must be photo or video"
                                                                   traceback:nil] removing:staged];
      }
    }
    if (videos > 0 && ![PHAssetCreationRequest supportsAssetResourceTypes:@[@(PHAssetResourceTypeVideo)]]) {
      return [self refuse:[FBCommandStatus unsupportedOperationErrorWithMessage:@"this phone's photo library can't add videos"
                                                                      traceback:nil] removing:staged];
    }
    // a clip takes longer to import than a picture: a second more for every 4 MB, 10 minutes at most
    changeWait = MIN(TWPhotosChangeWaitMax, TWPhotosChangeWait + (NSTimeInterval)videoTotal / (4.0 * 1048576));
  } else {
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
    unsigned long long total = 0;
    for (NSUInteger i = 0; i < list.count; i++) {
      id item = list[i];
      // a base64 string is a third bigger than its bytes: refuse before decoding what is over the cap
      if ([item isKindOfClass:NSString.class]) {
        total += (unsigned long long)([(NSString *)item length] / 4 * 3);
        if (total > TWMaxBytes) {
          return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"the pictures together are over the 40 MB limit"
                                                                             traceback:nil]);
        }
      }
      NSData *data = [item isKindOfClass:NSString.class]
        ? [[NSData alloc] initWithBase64EncodedString:(NSString *)item options:NSDataBase64DecodingIgnoreUnknownCharacters]
        : nil;
      if (nil == data || 0 == data.length) {
        return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"every picture must be base64 picture data"
                                                                           traceback:nil]);
      }
      id name = nil != names ? names[i] : nil;
      [items addObject:@{@"kind": @"photo", @"data": data,
                         @"name": [name isKindOfClass:NSString.class] ? (NSString *)name : @""}];
    }
  }

  PHAuthorizationStatus status = [self statusForFullAccess:NO askIfNeeded:YES];
  if (![self allows:status]) {
    NSString *message = [NSString stringWithFormat:@"the runner may not add to the photo library (iOS says %@)",
                         [self nameOfStatus:status]];
    return [self refuse:[FBCommandStatus unknownErrorWithMessage:message traceback:nil] removing:staged];
  }

  NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:items.count];
  dispatch_semaphore_t changed = dispatch_semaphore_create(0);
  __block BOOL succeeded = NO;
  __block NSError *changeError = nil;
  NSArray<NSURL *> *leftovers = [staged copy];
  [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
    for (NSDictionary *item in items) {
      PHAssetCreationRequest *creation = [PHAssetCreationRequest creationRequestForAsset];
      PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
      NSString *name = item[@"name"];
      if (name.length > 0) {
        options.originalFilename = name;
      }
      if ([@"video" isEqual:item[@"kind"]]) {
        options.shouldMoveFile = YES; // the library takes the file itself: no copy of a big clip
        [creation addResourceWithType:PHAssetResourceTypeVideo fileURL:item[@"url"] options:options];
      } else {
        [creation addResourceWithType:PHAssetResourceTypePhoto data:item[@"data"] options:options];
      }
      [identifiers addObject:creation.placeholderForCreatedAsset.localIdentifier];
    }
  } completionHandler:^(BOOL success, NSError *error) {
    succeeded = success;
    changeError = error;
    // whatever the library didn't move (a failure, or a change that ended after this route stopped waiting) goes now
    [TWPhotosCommands removeStaged:leftovers];
    dispatch_semaphore_signal(changed);
  }];
  if (![self waitFor:changed limit:changeWait]) {
    // the change goes on; its completion removes the staged files when it ends
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
  PHAuthorizationStatus status = [self statusForFullAccess:YES askIfNeeded:YES];
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
