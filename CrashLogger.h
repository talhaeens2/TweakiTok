#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Global Crash Logger for TweakiTok.
 * Hooks uncaught Objective-C/Swift exceptions and POSIX signals (SIGSEGV, SIGBUS, SIGABRT, SIGILL, etc.)
 * Writes detailed diagnostic reports to <Documents>/TweakiTok_Crash.txt when Developer Mode is enabled.
 */
void TTK_SetupGlobalCrashLogger(void);

/**
 * Returns the absolute file path to TweakiTok_Crash.txt in the application's Documents directory.
 */
NSString *TTK_GetCrashLogFilePath(void);

/**
 * Returns whether Developer Mode (crash logging) is currently active.
 */
BOOL TTK_IsDeveloperModeEnabled(void);

#ifdef __cplusplus
}
#endif
