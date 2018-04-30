// Copyright 2017 Google
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "Private/FIRLogger.h"

#import "FIRLoggerLevel.h"
#import "Private/FIRVersion.h"
#import "third_party/FIRAppEnvironmentUtil.h"

#include <asl.h>
#include <assert.h>
#include <stdbool.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

FIRLoggerService kFIRLoggerABTesting = @"[Firebase/ABTesting]";
FIRLoggerService kFIRLoggerAdMob = @"[Firebase/AdMob]";
FIRLoggerService kFIRLoggerAnalytics = @"[Firebase/Analytics]";
FIRLoggerService kFIRLoggerAuth = @"[Firebase/Auth]";
FIRLoggerService kFIRLoggerCore = @"[Firebase/Core]";
FIRLoggerService kFIRLoggerCrash = @"[Firebase/Crash]";
FIRLoggerService kFIRLoggerDatabase = @"[Firebase/Database]";
FIRLoggerService kFIRLoggerDynamicLinks = @"[Firebase/DynamicLinks]";
FIRLoggerService kFIRLoggerFirestore = @"[Firebase/Firestore]";
FIRLoggerService kFIRLoggerInstanceID = @"[Firebase/InstanceID]";
FIRLoggerService kFIRLoggerInvites = @"[Firebase/Invites]";
FIRLoggerService kFIRLoggerMessaging = @"[Firebase/Messaging]";
FIRLoggerService kFIRLoggerPerf = @"[Firebase/Performance]";
FIRLoggerService kFIRLoggerRemoteConfig = @"[Firebase/RemoteConfig]";
FIRLoggerService kFIRLoggerStorage = @"[Firebase/Storage]";
FIRLoggerService kFIRLoggerSwizzler = @"[FirebaseSwizzlingUtilities]";

/// Arguments passed on launch.
NSString *const kFIRDisableDebugModeApplicationArgument = @"-FIRDebugDisabled";
NSString *const kFIREnableDebugModeApplicationArgument = @"-FIRDebugEnabled";
NSString *const kFIRLoggerForceSDTERRApplicationArgument = @"-FIRLoggerForceSTDERR";

/// Key for the debug mode bit in NSUserDefaults.
NSString *const kFIRPersistedDebugModeKey = @"/google/firebase/debug_mode";

/// ASL client facility name used by FIRLogger.
const char *kFIRLoggerASLClientFacilityName = "com.firebase.app.logger";

/// Message format used by ASL client that matches format of NSLog.
const char *kFIRLoggerCustomASLMessageFormat =
    "$((Time)(J.3)) $(Sender)[$(PID)] <$((Level)(str))> $Message";

/// Constants for the number of errors and warnings logged.
NSString *const kFIRLoggerErrorCountFileName = @"google-firebase-count-of-errors-logged.txt";
NSString *const kFIRLoggerWarningCountFileName = @"google-firebase-count-of-warnings-logged.txt";
const NSInteger kFIRLoggerCountFileNotFound = -1;

static dispatch_once_t sFIRLoggerOnceToken;

static aslclient sFIRLoggerClient;

static dispatch_queue_t sFIRClientQueue;

static BOOL sFIRLoggerDebugMode;

// The sFIRAnalyticsDebugMode flag is here to support the -FIRDebugEnabled/-FIRDebugDisabled
// flags used by Analytics. Users who use those flags expect Analytics to log verbosely,
// while the rest of Firebase logs at the default level. This flag is introduced to support
// that behavior.
static BOOL sFIRAnalyticsDebugMode;

static FIRLoggerLevel sFIRLoggerMaximumLevel;

#ifdef DEBUG
/// The regex pattern for the message code.
static NSString *const kMessageCodePattern = @"^I-[A-Z]{3}[0-9]{6}$";
static NSRegularExpression *sMessageCodeRegex;
#endif

void FIRLoggerInitializeASL() {
  dispatch_once(&sFIRLoggerOnceToken, ^{
    NSInteger majorOSVersion = [[FIRAppEnvironmentUtil systemVersion] integerValue];
    uint32_t aslOptions = ASL_OPT_STDERR;
#if TARGET_OS_SIMULATOR
    // The iOS 11 simulator doesn't need the ASL_OPT_STDERR flag.
    if (majorOSVersion >= 11) {
      aslOptions = 0;
    }
#else
    // Devices running iOS 10 or higher don't need the ASL_OPT_STDERR flag.
    if (majorOSVersion >= 10) {
      aslOptions = 0;
    }
#endif  // TARGET_OS_SIMULATOR

    // Override the aslOptions to ASL_OPT_STDERR if the override argument is passed in.
    NSArray *arguments = [NSProcessInfo processInfo].arguments;
    if ([arguments containsObject:kFIRLoggerForceSDTERRApplicationArgument]) {
      aslOptions = ASL_OPT_STDERR;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // asl is deprecated
    // Initialize the ASL client handle.
    sFIRLoggerClient = asl_open(NULL, kFIRLoggerASLClientFacilityName, aslOptions);

    // Set the filter used by system/device log. Initialize in default mode.
    asl_set_filter(sFIRLoggerClient, ASL_FILTER_MASK_UPTO(ASL_LEVEL_NOTICE));
    sFIRLoggerDebugMode = NO;
    sFIRAnalyticsDebugMode = NO;
    sFIRLoggerMaximumLevel = FIRLoggerLevelNotice;

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    BOOL debugMode = [userDefaults boolForKey:kFIRPersistedDebugModeKey];

    if ([arguments containsObject:kFIRDisableDebugModeApplicationArgument]) {  // Default mode
      [userDefaults removeObjectForKey:kFIRPersistedDebugModeKey];
    } else if ([arguments containsObject:kFIREnableDebugModeApplicationArgument] ||
               debugMode) {  // Debug mode
      [userDefaults setBool:YES forKey:kFIRPersistedDebugModeKey];
      asl_set_filter(sFIRLoggerClient, ASL_FILTER_MASK_UPTO(ASL_LEVEL_DEBUG));
      sFIRLoggerDebugMode = YES;
    }

    // We should disable debug mode if we are running from App Store.
    if (sFIRLoggerDebugMode && [FIRAppEnvironmentUtil isFromAppStore]) {
      sFIRLoggerDebugMode = NO;
    }

#if TARGET_OS_SIMULATOR
    // Need to call asl_add_output_file so that the logs can appear in Xcode's console view when
    // running iOS 7. Set the ASL filter mask for this output file up to debug level so that all
    // messages are viewable in the console.
    if (majorOSVersion == 7) {
      asl_add_output_file(sFIRLoggerClient, STDERR_FILENO, kFIRLoggerCustomASLMessageFormat,
                          ASL_TIME_FMT_LCL, ASL_FILTER_MASK_UPTO(ASL_LEVEL_DEBUG), ASL_ENCODE_SAFE);
    }
#endif  // TARGET_OS_SIMULATOR

    sFIRClientQueue = dispatch_queue_create("FIRLoggingClientQueue", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(sFIRClientQueue,
                              dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));

#ifdef DEBUG
    sMessageCodeRegex =
        [NSRegularExpression regularExpressionWithPattern:kMessageCodePattern options:0 error:NULL];
#endif
  });
}

void FIRSetAnalyticsDebugMode(BOOL analyticsDebugMode) {
  FIRLoggerInitializeASL();
  dispatch_async(sFIRClientQueue, ^{
    // We should not enable debug mode if we are running from App Store.
    if (analyticsDebugMode && [FIRAppEnvironmentUtil isFromAppStore]) {
      return;
    }
    sFIRAnalyticsDebugMode = analyticsDebugMode;
    asl_set_filter(sFIRLoggerClient, ASL_FILTER_MASK_UPTO(ASL_LEVEL_DEBUG));
  });
}

void FIRSetLoggerLevel(FIRLoggerLevel loggerLevel) {
  if (loggerLevel < FIRLoggerLevelMin || loggerLevel > FIRLoggerLevelMax) {
    FIRLogError(kFIRLoggerCore, @"I-COR000023", @"Invalid logger level, %ld", (long)loggerLevel);
    return;
  }
  FIRLoggerInitializeASL();
  // We should not raise the logger level if we are running from App Store.
  if (loggerLevel >= FIRLoggerLevelNotice && [FIRAppEnvironmentUtil isFromAppStore]) {
    return;
  }

  sFIRLoggerMaximumLevel = loggerLevel;
  dispatch_async(sFIRClientQueue, ^{
    asl_set_filter(sFIRLoggerClient, ASL_FILTER_MASK_UPTO(loggerLevel));
  });
}

BOOL FIRIsLoggableLevel(FIRLoggerLevel loggerLevel, BOOL analyticsComponent) {
  FIRLoggerInitializeASL();
  if (sFIRLoggerDebugMode) {
    return YES;
  } else if (sFIRAnalyticsDebugMode && analyticsComponent) {
    return YES;
  }
  return (BOOL)(loggerLevel <= sFIRLoggerMaximumLevel);
}

#ifdef DEBUG
void FIRResetLogger() {
  sFIRLoggerOnceToken = 0;
  FIRResetNumberOfIssuesLogged();
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:kFIRPersistedDebugModeKey];
}

aslclient getFIRLoggerClient() {
  return sFIRLoggerClient;
}

dispatch_queue_t getFIRClientQueue() {
  return sFIRClientQueue;
}

BOOL getFIRLoggerDebugMode() {
  return sFIRLoggerDebugMode;
}
#endif

#pragma mark - Number of errors and warnings

NSString *FIRLoggerPathInCachesByAppending(NSString *pathToAppend) {
  NSArray *directories =
      NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  if (directories.count == 0) {
    return nil;
  }
  NSString *cacheDir = directories[0];
  return [cacheDir stringByAppendingPathComponent:pathToAppend];
}

/**
 * Read an integer from the specific file, returning kFIRLoggerCountFileNotFound if the file doesn't
 * exist.
 */
NSInteger FIRReadIntegerFromFile(NSString *filePath) {
  if (!filePath.length) {
    return kFIRLoggerCountFileNotFound;
  }

  NSError *error = nil;
  NSString *fileContents =
      [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];
  if (error) {
    return kFIRLoggerCountFileNotFound;
  }

  return [fileContents integerValue];
}

/**
 * Read an integer from the specific file, returning YES if the write was successful.
 */
BOOL FIRWriteIntegerToFile(NSInteger value, NSString *filePath) {
  if (!filePath.length) {
    return NO;
  }

  NSString *fileContents = [NSString stringWithFormat:@"%ld", (long)value];
  NSError *error = nil;
  BOOL success =
      [fileContents writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
  if (error) {
    FIRLogDebug(kFIRLoggerCore, @"I-COR000029",
                @"Attempted to write the a log counter to file but failed: %@", error);
  }

  return success;
}

/**
 * Returns the number of errors logged since last being reset. Note: this synchronously reads a file
 * on the same queue that logging occurs.
 */
NSInteger FIRNumberOfErrorsLogged(void) {
  NSString *fileName = FIRLoggerPathInCachesByAppending(kFIRLoggerErrorCountFileName);
  __block NSString *fileContents = nil;
  __block NSError *error = nil;
  dispatch_sync(sFIRClientQueue, ^{
    fileContents =
        [NSString stringWithContentsOfFile:fileName encoding:NSUTF8StringEncoding error:&error];
  });

  if (error) {
    return 0;
  }

  return [fileContents integerValue];
}

/**
 * Returns the number of warnings logged since last being reset. Note: this synchronously reads a
 * file on the same queue that logging occurs.
 */
NSInteger FIRNumberOfWarningsLogged(void) {
  NSString *fileName = FIRLoggerPathInCachesByAppending(kFIRLoggerWarningCountFileName);
  __block NSString *fileContents = nil;
  __block NSError *error = nil;
  dispatch_sync(sFIRClientQueue, ^{
    fileContents =
        [NSString stringWithContentsOfFile:fileName encoding:NSUTF8StringEncoding error:&error];
  });

  if (error) {
    return 0;
  }

  return [fileContents integerValue];
}

/**
 * Resets the number of issues logged (warnings and errors).
 */
BOOL FIRResetNumberOfIssuesLogged(void) {
  NSString *errorCountPath = FIRLoggerPathInCachesByAppending(kFIRLoggerErrorCountFileName);
  NSString *warningCountPath = FIRLoggerPathInCachesByAppending(kFIRLoggerWarningCountFileName);
  __block BOOL success = NO;
  dispatch_sync(sFIRClientQueue, ^{
    BOOL errorWriteSuccess = FIRWriteIntegerToFile(0, errorCountPath);
    BOOL warningWriteSuccess = FIRWriteIntegerToFile(0, warningCountPath);
    success = (errorWriteSuccess && warningWriteSuccess);
  });

  return success;
}

#pragma mark - Logging functions

void FIRLogBasic(FIRLoggerLevel level,
                 FIRLoggerService service,
                 NSString *messageCode,
                 NSString *message,
                 va_list args_ptr) {
  FIRLoggerInitializeASL();
  BOOL canLog = level <= sFIRLoggerMaximumLevel;

  if (sFIRLoggerDebugMode) {
    canLog = YES;
  } else if (sFIRAnalyticsDebugMode && [kFIRLoggerAnalytics isEqualToString:service]) {
    canLog = YES;
  }

  if (!canLog) {
    return;
  }
#ifdef DEBUG
  NSCAssert(messageCode.length == 11, @"Incorrect message code length.");
  NSRange messageCodeRange = NSMakeRange(0, messageCode.length);
  NSUInteger numberOfMatches =
      [sMessageCodeRegex numberOfMatchesInString:messageCode options:0 range:messageCodeRange];
  NSCAssert(numberOfMatches == 1, @"Incorrect message code format.");
#endif
  NSString *logMsg = [[NSString alloc] initWithFormat:message arguments:args_ptr];
  logMsg = [NSString
      stringWithFormat:@"%s - %@[%@] %@", FirebaseVersionString, service, messageCode, logMsg];
  dispatch_async(sFIRClientQueue, ^{
    asl_log(sFIRLoggerClient, NULL, level, "%s", logMsg.UTF8String);

    // Keep count of how many errors and warnings are triggered.
    if (level == FIRLoggerLevelError) {
      NSString *path = FIRLoggerPathInCachesByAppending(kFIRLoggerErrorCountFileName);
      NSInteger currentValue = FIRReadIntegerFromFile(path);
      if (currentValue == kFIRLoggerCountFileNotFound) {
        FIRWriteIntegerToFile(1, path);
      } else {
        FIRWriteIntegerToFile(currentValue + 1, path);
      }
    } else if (level == FIRLoggerLevelWarning) {
      NSString *path = FIRLoggerPathInCachesByAppending(kFIRLoggerWarningCountFileName);
      NSInteger currentValue = FIRReadIntegerFromFile(path);
      if (currentValue == kFIRLoggerCountFileNotFound) {
        FIRWriteIntegerToFile(1, path);
      } else {
        FIRWriteIntegerToFile(currentValue + 1, path);
      }
    }
  });
}
#pragma clang diagnostic pop

/**
 * Generates the logging functions using macros.
 *
 * Calling FIRLogError(kFIRLoggerCore, @"I-COR000001", @"Configure %@ failed.", @"blah") shows:
 * yyyy-mm-dd hh:mm:ss.SSS sender[PID] <Error> [Firebase/Core][I-COR000001] Configure blah failed.
 * Calling FIRLogDebug(kFIRLoggerCore, @"I-COR000001", @"Configure succeed.") shows:
 * yyyy-mm-dd hh:mm:ss.SSS sender[PID] <Debug> [Firebase/Core][I-COR000001] Configure succeed.
 */
#define FIR_LOGGING_FUNCTION(level)                                                             \
  void FIRLog##level(FIRLoggerService service, NSString *messageCode, NSString *message, ...) { \
    va_list args_ptr;                                                                           \
    va_start(args_ptr, message);                                                                \
    FIRLogBasic(FIRLoggerLevel##level, service, messageCode, message, args_ptr);                \
    va_end(args_ptr);                                                                           \
  }

FIR_LOGGING_FUNCTION(Error)
FIR_LOGGING_FUNCTION(Warning)
FIR_LOGGING_FUNCTION(Notice)
FIR_LOGGING_FUNCTION(Info)
FIR_LOGGING_FUNCTION(Debug)

#undef FIR_MAKE_LOGGER

#pragma mark - FIRLoggerWrapper

@implementation FIRLoggerWrapper

+ (void)logWithLevel:(FIRLoggerLevel)level
         withService:(FIRLoggerService)service
            withCode:(NSString *)messageCode
         withMessage:(NSString *)message
            withArgs:(va_list)args {
  FIRLogBasic(level, service, messageCode, message, args);
}

@end
