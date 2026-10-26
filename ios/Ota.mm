#import "Ota.h"
#import <CommonCrypto/CommonDigest.h>
#import <React/RCTReloadCommand.h>
#import <SSZipArchive/SSZipArchive.h>

#if __has_include(<Ota/Ota-Swift.h>)
#import <Ota/Ota-Swift.h>
#else
#import "Ota-Swift.h"
#endif

static NSString *const kBundleName = @"main.jsbundle";

static NSString *_Nullable OtaSha256(NSURL *fileURL)
{
  NSInputStream *stream = [NSInputStream inputStreamWithURL:fileURL];
  [stream open];
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  uint8_t buffer[32 * 1024];
  NSInteger read;
  while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
    CC_SHA256_Update(&ctx, buffer, (CC_LONG)read);
  }
  [stream close];
  if (read < 0) return nil;

  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &ctx);
  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [hex appendFormat:@"%02x", digest[i]];
  }
  return hex;
}

typedef void (^OtaProgressBlock)(int64_t received, int64_t total);
typedef void (^OtaDownloadCompletion)(NSURL *_Nullable location, NSURLResponse *_Nullable response, NSError *_Nullable error);

// The completion-handler variant of NSURLSession does not report progress, so use a delegate
@interface OtaDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) OtaProgressBlock onProgress;
@property (nonatomic, copy) OtaDownloadCompletion onComplete;
@end

@implementation OtaDownloadDelegate {
  BOOL _finished;
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
  self.onProgress(totalBytesWritten, totalBytesExpectedToWrite);
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
  // `location` is deleted as soon as this method returns
  _finished = YES;
  self.onComplete(location, downloadTask.response, nil);
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
  if (!_finished) {
    _finished = YES;
    self.onComplete(nil, task.response, error);
  }
}

@end

// Emits only when the integer percent changes (at most ~100 events per phase),
// or every 100ms when the total size is unknown
@interface OtaProgressThrottle : NSObject
- (instancetype)initWithPhase:(NSString *)phase emitter:(void (^)(NSDictionary *))emitter;
- (void)update:(int64_t)received total:(int64_t)total;
- (void)finish:(int64_t)received total:(int64_t)total;
@end

@implementation OtaProgressThrottle {
  NSString *_phase;
  void (^_emitter)(NSDictionary *);
  int _lastPercent;
  CFAbsoluteTime _lastEmitAt;
}

- (instancetype)initWithPhase:(NSString *)phase emitter:(void (^)(NSDictionary *))emitter
{
  if (self = [super init]) {
    _phase = phase;
    _emitter = [emitter copy];
    _lastPercent = -1;
  }
  return self;
}

- (void)update:(int64_t)received total:(int64_t)total
{
  if (total > 0) {
    int percent = (int)(received * 100 / total);
    if (percent == _lastPercent) return;
    _lastPercent = percent;
    [self emit:received total:total percent:percent];
  } else {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastEmitAt < 0.1) return;
    _lastEmitAt = now;
    [self emit:received total:total percent:-1];
  }
}

- (void)finish:(int64_t)received total:(int64_t)total
{
  if (_lastPercent != 100) [self emit:received total:total percent:100];
}

- (void)emit:(int64_t)received total:(int64_t)total percent:(int)percent
{
  _emitter(@{@"phase": _phase, @"progress": @(percent), @"received": @(received), @"total": @(total)});
}

@end

@implementation Ota {
  // Downloads share the staging folder, so only one may run at a time
  BOOL _downloading;
}

RCT_EXPORT_MODULE()

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
(const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeOtaSpecJSI>(params);
}

- (void)reloadApp:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      // Reload re-queries the delegate's bundleURL, which returns the OTA bundle if present
      RCTTriggerReloadCommandListeners(@"Reload triggered");
      resolve(@"Reload triggered");
    } @catch (NSException *exception) {
      reject(@"RELOAD_FAILED", exception.reason, nil);
    }
  });
}

- (void)downloadBundle:(nonnull NSString *)url
           versionCode:(double)versionCode
                sha256:(nullable NSString *)sha256
               resolve:(nonnull RCTPromiseResolveBlock)resolve
                reject:(nonnull RCTPromiseRejectBlock)reject
{
  NSURL *bundleURL = [NSURL URLWithString:url];
  if (!bundleURL) {
    reject(@"INVALID_URL", @"Invalid URL", nil);
    return;
  }

  @synchronized(self) {
    if (_downloading) {
      reject(@"ALREADY_DOWNLOADING", @"Another download is in progress", nil);
      return;
    }
    _downloading = YES;
  }

  __weak Ota *weakSelf = self;
  void (^finish)(void) = ^{
    Ota *strongSelf = weakSelf;
    if (strongSelf) {
      @synchronized(strongSelf) {
        strongSelf->_downloading = NO;
      }
    }
  };
  void (^emit)(NSDictionary *) = ^(NSDictionary *event) {
    [weakSelf emitOnProgress:event];
  };
  OtaProgressThrottle *downloadProgress = [[OtaProgressThrottle alloc] initWithPhase:@"download" emitter:emit];

  OtaDownloadDelegate *delegate = [OtaDownloadDelegate new];
  delegate.onProgress = ^(int64_t received, int64_t total) {
    [downloadProgress update:received total:total];
  };
  delegate.onComplete = ^(NSURL *location, NSURLResponse *response, NSError *error) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *stagingDir = [OtaHelper stagingURL];
    [fileManager removeItemAtURL:stagingDir error:nil];

    void (^fail)(NSString *, NSString *, NSError *) = ^(NSString *code, NSString *message, NSError *err) {
      [fileManager removeItemAtURL:stagingDir error:nil];
      finish();
      reject(code, message, err);
    };

    if (error) {
      fail(@"DOWNLOAD_FAILED", error.localizedDescription, error);
      return;
    }

    NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
      ? ((NSHTTPURLResponse *)response).statusCode : 200;
    if (statusCode < 200 || statusCode >= 300) {
      fail(@"HTTP_ERROR", [NSString stringWithFormat:@"Code: %ld", (long)statusCode], nil);
      return;
    }

    if (!location) {
      fail(@"NO_FILE", @"Downloaded file not found", nil);
      return;
    }

    int64_t zipSize = [[fileManager attributesOfItemAtPath:location.path error:nil] fileSize];
    [downloadProgress finish:zipSize total:response.expectedContentLength];

    if (sha256.length > 0) {
      NSString *actual = OtaSha256(location);
      if (![actual isEqualToString:sha256.lowercaseString]) {
        fail(@"CHECKSUM_MISMATCH",
             [NSString stringWithFormat:@"Expected sha256 %@, got %@", sha256, actual ?: @"(unreadable)"], nil);
        return;
      }
    }

    // Extract into staging first so a broken zip never replaces a working bundle.
    // `location` is only valid inside this callback, so unzip synchronously here.
    OtaProgressThrottle *unzipProgress = [[OtaProgressThrottle alloc] initWithPhase:@"unzip" emitter:emit];
    __block long entryCount = 0;
    NSError *unzipError = nil;
    BOOL unzipped = [SSZipArchive unzipFileAtPath:location.path
                                    toDestination:stagingDir.path
                               preserveAttributes:YES
                                        overwrite:YES
                                   nestedZipLevel:0
                                         password:nil
                                            error:&unzipError
                                         delegate:nil
                                  progressHandler:^(NSString *entry, unz_file_info zipInfo, long entryNumber, long total) {
      entryCount = total;
      [unzipProgress update:entryNumber total:total];
    }
                                completionHandler:nil];
    if (!unzipped) {
      fail(@"UNZIP_FAILED", unzipError.localizedDescription ?: @"Unknown unzip error", unzipError);
      return;
    }
    [unzipProgress finish:entryCount total:entryCount];

    if (![fileManager fileExistsAtPath:[stagingDir URLByAppendingPathComponent:kBundleName].path]) {
      fail(@"NO_BUNDLE", @"main.jsbundle not found in zip", nil);
      return;
    }

    NSError *installError = nil;
    if (![OtaHelper installFromStaging:stagingDir version:versionCode error:&installError]) {
      fail(@"MOVE_FAILED", installError.localizedDescription, installError);
      return;
    }

    finish();
    resolve(@{@"status": @YES, @"message": @"Download and unzip successfully"});
  };

  // The session keeps a strong reference to its delegate until invalidated
  NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                        delegate:delegate
                                                   delegateQueue:nil];
  [[session downloadTaskWithURL:bundleURL] resume];
  [session finishTasksAndInvalidate];
}

- (nonnull NSNumber *)getSavedVersion
{
  return @([OtaHelper savedVersion]);
}

- (nonnull NSNumber *)getFailedVersion
{
  return @([OtaHelper failedVersion]);
}

- (nonnull NSString *)getNativeVersion
{
  return [OtaHelper nativeVersion];
}

- (void)notifyAppReady
{
  [OtaHelper notifyAppReady];
}

- (void)removeBundle:(nonnull RCTPromiseResolveBlock)resolve
              reject:(nonnull RCTPromiseRejectBlock)reject
{
  [OtaHelper clear];
  resolve(@{@"status": @YES, @"message": @"OTA bundle removed successfully"});
}

@end
