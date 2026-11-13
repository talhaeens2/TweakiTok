#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Global Crash Logger for TweakiTok.
 * - Captures uncaught Objective-C/Swift exceptions.
 * - Catches fatal POSIX signals (SIGSEGV, SIGBUS, SIGABRT, SIGILL).
 * - Tracks application lifecycle and detects abnormal terminations (Watchdog 0x8BADF00D, SIGKILL, Jetsam OOM)
 *   generating diagnostic reports in <Documents>/TweakiTok_Crash_<Date_Time>.txt.
 * - Creates an initial placeholder file so the 'TikTok' folder immediately appears in the iOS Files app.
 */
void TTK_SetupGlobalCrashLogger(void);

/**
 * Returns the absolute file path to the latest crash log in the application's Documents directory.
 */
NSString *TTK_GetCrashLogFilePath(void);

/**
 * Returns whether Developer Mode is enabled.
 */
BOOL TTK_IsDeveloperModeEnabled(void);

/**
 * Records a diagnostic lifecycle breadcrumb (e.g., scene transitions, feed events).
 */
void TTK_RecordBreadcrumb(const char *format, ...);

/**
 * Marks that the application session exited or suspended cleanly.
 */
void TTK_RecordCleanExit(void);

#ifdef __cplusplus
}
#endif
