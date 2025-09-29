#import "Ota.h"
#import <React/RCTBridge.h>
#import <React/RCTRootView.h>
#import <React/RCTReloadCommand.h>
#import <UIKit/UIKit.h>
#import <SSZipArchive/SSZipArchive.h>
#import <React/RCTBundleURLProvider.h>



@implementation Ota


RCT_EXPORT_MODULE()

- (void)reloadApp:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      
      // Log bundle hiện tại
      NSFileManager *fileManager = [NSFileManager defaultManager];
      NSURL *libraryDir = [[fileManager URLsForDirectory:NSLibraryDirectory
                                               inDomains:NSUserDomainMask] firstObject];
      NSString *otaBundlePath = [[libraryDir path] stringByAppendingPathComponent:@"ota-main.jsbundle"];
      
    
      
      // Trigger React Native reload listeners (reload the JS bundle)
      RCTTriggerReloadCommandListeners(@"Reload triggered");
      resolve(@"Reload triggered");
    } @catch (NSException *exception) {
      reject(@"RELOAD_FAILED", exception.reason, nil);
    }
  });
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
(const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeOtaSpecJSI>(params);
}

- (void)downloadBundle:(nonnull NSString *)url
           versionCode:(double)versionCode
               resolve:(nonnull RCTPromiseResolveBlock)resolve
                reject:(nonnull RCTPromiseRejectBlock)reject
{
    // Copy block để tránh bị giải phóng
    RCTPromiseResolveBlock resolveCopy = [resolve copy];
    RCTPromiseRejectBlock rejectCopy = [reject copy];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *bundleVersionKey = @"ota_bundle_version";

   
    
    NSURL *bundleURL = [NSURL URLWithString:url];
    if (!bundleURL) {
        if (rejectCopy) {
            dispatch_async(dispatch_get_main_queue(), ^{
                rejectCopy(@"INVALID_URL", @"Invalid URL", nil);
            });
        }
        return;
    }
    
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession]
        downloadTaskWithURL:bundleURL
          completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
              
        if (error) {
            if (rejectCopy) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    rejectCopy(@"DOWNLOAD_FAILED", error.localizedDescription, error);
                });
            }
            return;
        }
        
        if (!location) {
            if (rejectCopy) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    rejectCopy(@"NO_FILE", @"Downloaded file not found", nil);
                });
            }
            return;
        }
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *libraryDir = [[fileManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] firstObject];
        NSString *bundlePath = [[libraryDir path] stringByAppendingPathComponent:@"ota-main.jsbundle"];
        NSString *tempZipPath = [location path];
        NSString *unzipDir = [libraryDir path];
        
        NSError *unzipError = nil;
        BOOL result = [SSZipArchive unzipFileAtPath:tempZipPath
                                      toDestination:unzipDir
                                          overwrite:YES
                                           password:nil
                                              error:&unzipError];
      if (!result) {
          NSString *errorMessage = unzipError ? unzipError.localizedDescription : @"Unknown unzip error";
          if (rejectCopy) {
              dispatch_async(dispatch_get_main_queue(), ^{
                  rejectCopy(@"UNZIP_FAILED", errorMessage, unzipError);
              });
          }
          return;
      }
        
        NSString *unzippedBundle = [unzipDir stringByAppendingPathComponent:@"main.jsbundle"];
        if (![fileManager fileExistsAtPath:unzippedBundle]) {
            if (rejectCopy) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    rejectCopy(@"NO_BUNDLE", @"main.jsbundle not found in zip", nil);
                });
            }
            return;
        }
        
        // Remove old bundle if exists
        if ([fileManager fileExistsAtPath:bundlePath]) {
            [fileManager removeItemAtPath:bundlePath error:nil];
        }
        
        NSError *moveError = nil;
        if (![fileManager moveItemAtPath:unzippedBundle toPath:bundlePath error:&moveError]) {
            if (rejectCopy) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    rejectCopy(@"MOVE_FAILED", moveError.localizedDescription, moveError);
                });
            }
            return;
        }
        
        // Remove temp zip
        [fileManager removeItemAtPath:tempZipPath error:nil];
        
        [defaults setInteger:(NSInteger)versionCode forKey:bundleVersionKey];
        [defaults synchronize];
        
        if (resolveCopy) {
            dispatch_async(dispatch_get_main_queue(), ^{
                resolveCopy(@{@"status": @YES, @"message": @"Download and unzip successfully"});
            });
        }
        
    }];
    
    [downloadTask resume];
}

- (nonnull NSString *)getSavedVersion { 
  NSString *bundleVersionKey = @"ota_bundle_version";
  NSInteger savedVersion = [[NSUserDefaults standardUserDefaults] integerForKey:bundleVersionKey];
  return [NSString stringWithFormat:@"%ld", (long)savedVersion];
}

- (void)removeBundle:(nonnull RCTPromiseResolveBlock)resolve reject:(nonnull RCTPromiseRejectBlock)reject { 
  RCTPromiseResolveBlock resolveCopy = [resolve copy];
      RCTPromiseRejectBlock rejectCopy = [reject copy];

      dispatch_async(dispatch_get_main_queue(), ^{
          NSFileManager *fileManager = [NSFileManager defaultManager];
          NSURL *libraryDir = [[fileManager URLsForDirectory:NSLibraryDirectory
                                                   inDomains:NSUserDomainMask] firstObject];
          NSString *bundlePath = [[libraryDir path] stringByAppendingPathComponent:@"ota-main.jsbundle"];
          
          NSError *error = nil;
          if ([fileManager fileExistsAtPath:bundlePath]) {
              if (![fileManager removeItemAtPath:bundlePath error:&error]) {
                  if (rejectCopy) {
                      rejectCopy(@"REMOVE_FAILED", error.localizedDescription, error);
                  }
                  return;
              }
          }

          // Reset saved version
          NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
          [defaults removeObjectForKey:@"ota_bundle_version"];
          [defaults synchronize];

          if (resolveCopy) {
              resolveCopy(@{@"status": @YES, @"message": @"OTA bundle removed successfully"});
          }
      });
}


@end
