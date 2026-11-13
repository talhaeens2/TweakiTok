#import "CrashLogger.h"
#import "BHIManager.h"

#import <signal.h>
#import <execinfo.h>
#import <sys/utsname.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <time.h>
#import <stdarg.h>
#import <pthread.h>

static NSUncaughtExceptionHandler *sPreviousExceptionHandler = NULL;
static struct sigaction sPreviousSigActions[32];
static char sCrashLogPath[1024] = {0};
static char sDocsPath[1024] = {0};
static char sAlternateStack[SIGSTKSZ * 4];
static char sLastBreadcrumbs[16][256];
static int sBreadcrumbIndex = 0;
static pthread_mutex_t sBreadcrumbMutex = PTHREAD_MUTEX_INITIALIZER;

static NSString *TTK_GetDeviceModel(void) {
    struct utsname systemInfo;
    if (uname(&systemInfo) == 0) {
        return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    }
    return @"Unknown";
}

static void TTK_EnsureDocsPath(void) {
    if (sDocsPath[0] != '\0') return;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject;
    if (!docs || docs.length == 0) {
        const char *home = getenv("HOME");
        if (home) {
            docs = [NSString stringWithFormat:@"%s/Documents", home];
        }
    }
    if (docs) {
        [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        strncpy(sDocsPath, [docs UTF8String], sizeof(sDocsPath) - 1);

        // Files App Visibility: Create a descriptive file so that 'iPhone'umda > TikTok'
        // immediately appears in the iOS Files app even before any crash occurs.
        NSString *infoPath = [docs stringByAppendingPathComponent:@"TweakiTok_Info.txt"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:infoPath]) {
            NSString *content = [NSString stringWithFormat:
                @"TweakiTok Tanı & Çökme Günlükleri Dizini\n"
                @"===========================================\n"
                @"Bu klasör TweakiTok tarafından otomatik olarak oluşturulmuştur.\n"
                @"Uygulamada bir çökme (crash) veya iOS Watchdog kilitlenmesi meydana gelirse,\n"
                @"ayrıntılı raporlar bu klasöre 'TweakiTok_Crash_*.txt' olarak kaydedilir.\n"
                @"Oluşturulma Tarihi: %@\n", [NSDate date]];
            [content writeToFile:infoPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

static UIViewController *TTK_GetTopViewController(UIViewController *root) {
    if (!root) {
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    for (UIWindow *w in ws.windows) {
                        if (w.isKeyWindow) {
                            window = w;
                            break;
                        }
                    }
                    if (window) break;
                }
            }
        }
        if (!window) window = [UIApplication sharedApplication].keyWindow;
        root = window.rootViewController;
    }
    
    if ([root isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)root;
        return TTK_GetTopViewController(nav.visibleViewController);
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)root;
        return TTK_GetTopViewController(tab.selectedViewController);
    }
    if (root.presentedViewController) {
        return TTK_GetTopViewController(root.presentedViewController);
    }
    return root;
}

static NSString *TTK_GetHumanReadableExceptionExplanation(NSString *name, NSString *reason) {
    if ([name isEqualToString:@"NSInvalidArgumentException"]) {
        if ([reason containsString:@"unrecognized selector"]) {
            return @"[Geçersiz Metot / Unrecognized Selector]: Bir nesneye o nesnede tanımlı olmayan bir fonksiyon/metot çağrısı yapıldı.";
        }
        return @"[Geçersiz Parametre / Invalid Argument]: Bir fonksiyona veya diziye kabul edilemez (nil veya hatalı türde) bir parametre gönderildi.";
    } else if ([name isEqualToString:@"NSRangeException"]) {
        return @"[Dizi Sınır Aşımı / Range Out of Bounds]: Bir dizi (Array), liste veya metin sınırlarının dışındaki bir indekse erişilmeye çalışıldı.";
    } else if ([name isEqualToString:@"NSInternalInconsistencyException"]) {
        return @"[Dahili Tutarsızlık / Internal Inconsistency]: UIKit veya dahili bir kütüphane beklenmedik bir durumla karşılaştı.";
    } else if ([name isEqualToString:@"NSGenericException"]) {
        return @"[Genel Hata / Generic Exception]: İşletim sistemi veya kütüphane seviyesinde genel bir hata oluştu.";
    }
    return @"[Bilinmeyen İstisna / Unhandled Exception]: Yakalanamayan bir Objective-C / Swift çalışma zamanı hatası oluştu.";
}

static const char *TTK_GetSignalHumanExplanation(int sig, int code, void *addr) {
    switch (sig) {
        case SIGSEGV:
            if (addr == NULL || (uintptr_t)addr < 0x1000) {
                return "[Bellek Hatası / NULL Pointer Dereference]: Uygulama NULL / nil (sıfır) olan bir bellek adresine erişmeye çalıştı.";
            }
            return "[Bellek Hatası / Segmentation Fault]: Uygulama geçersiz, silinmiş (deallocated / zombie) veya korumalı bir bellek adresine okuma/yazma yapmaya çalıştı.";
        case SIGBUS:
            return "[Veriyolu Hatası / Bus Error]: Bellek hizalama hatası veya geçersiz donanım/sayfalama bellek erişimi gerçekleşti.";
        case SIGABRT:
            return "[Zorla Sonlandırma / Abort]: Uygulama abort() çağrısı yaptı. Genellikle bir C++ assert(), unhandled exception veya bellek tahsis bozulması sonucu oluşur.";
        case SIGILL:
            return "[Geçersiz Komut / Illegal Instruction]: İşlemciye tanınmayan veya bozuk bir makine komutu gönderildi (Örn: Hasarlı fonksiyon işaretçisi).";
        case SIGFPE:
            return "[Aritmetik Hata / Floating Point Exception]: Sıfıra bölme veya matematiksel taşma gerçekleşti.";
        case SIGTRAP:
            return "[Hata Tuzağı / Trace Trap]: Swift fatalError(), precondition failure veya derleyici güvenlik tuzağı tetiklendi.";
        default:
            return "[Sistem Sinyali / Signal]: Beklenmedik bir POSIX sinyali alındı.";
    }
}

static void TTK_WriteRawLog(const char *buffer) {
    if (!buffer || sCrashLogPath[0] == '\0') return;
    int fd = open(sCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        size_t len = strlen(buffer);
        write(fd, buffer, len);
        close(fd);
    }
}

void TTK_RecordBreadcrumb(const char *format, ...) {
    if (!format) return;
    char buffer[256];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);

    time_t now = time(NULL);
    struct tm tm_info;
    localtime_r(&now, &tm_info);
    char timeBuf[32];
    strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", &tm_info);

    pthread_mutex_lock(&sBreadcrumbMutex);
    int idx = sBreadcrumbIndex % 16;
    snprintf(sLastBreadcrumbs[idx], sizeof(sLastBreadcrumbs[idx]), "[%s] %s", timeBuf, buffer);
    sBreadcrumbIndex++;
    pthread_mutex_unlock(&sBreadcrumbMutex);
}

static NSString *TTK_GetFormattedBreadcrumbs(void) {
    NSMutableString *str = [NSMutableString string];
    pthread_mutex_lock(&sBreadcrumbMutex);
    int count = sBreadcrumbIndex < 16 ? sBreadcrumbIndex : 16;
    int start = sBreadcrumbIndex < 16 ? 0 : (sBreadcrumbIndex % 16);
    for (int i = 0; i < count; i++) {
        int idx = (start + i) % 16;
        [str appendFormat:@"  * %s\n", sLastBreadcrumbs[idx]];
    }
    pthread_mutex_unlock(&sBreadcrumbMutex);
    return str.length > 0 ? str : @"  (Kayıtlı eylem yok)\n";
}

static NSString *TTK_GetActiveSessionFilePath(void) {
    TTK_EnsureDocsPath();
    if (sDocsPath[0] == '\0') return nil;
    return [[NSString stringWithUTF8String:sDocsPath] stringByAppendingPathComponent:@"TweakiTok_ActiveSession.json"];
}

void TTK_RecordCleanExit(void) {
    NSString *sessionPath = TTK_GetActiveSessionFilePath();
    if (!sessionPath) return;
    NSDictionary *dict = @{
        @"cleanExit": @YES,
        @"timestamp": [NSString stringWithFormat:@"%ld", (long)time(NULL)]
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        [data writeToFile:sessionPath atomically:YES];
    }
}

static void TTK_CheckPreviousSessionForAbnormalTermination(void) {
    NSString *sessionPath = TTK_GetActiveSessionFilePath();
    if (!sessionPath || ![[NSFileManager defaultManager] fileExistsAtPath:sessionPath]) {
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:sessionPath];
    if (!data) return;

    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!dict || ![dict isKindOfClass:[NSDictionary class]]) return;

    NSNumber *clean = dict[@"cleanExit"];
    if (clean && [clean boolValue] == NO) {
        // Önceki oturum temiz kapanmamış! (Watchdog 0x8BADF00D, SIGKILL, Codesigning veya Jetsam OOM)
        NSString *lastState = dict[@"lastState"] ?: @"Bilinmiyor";
        NSString *launchTime = dict[@"launchTime"] ?: @"Bilinmiyor";
        NSString *appVersion = dict[@"appVersion"] ?: @"Unknown";
        NSString *breadcrumbs = dict[@"breadcrumbs"] ?: @"";

        NSDateFormatter *fileFormatter = [[NSDateFormatter alloc] init];
        [fileFormatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
        NSString *fileDateStr = [fileFormatter stringFromDate:[NSDate date]];
        NSString *fileName = [NSString stringWithFormat:@"TweakiTok_Crash_%@_AbnormalTermination.txt", fileDateStr];
        NSString *outPath = [[NSString stringWithUTF8String:sDocsPath] stringByAppendingPathComponent:fileName];

        NSMutableString *report = [NSMutableString string];
        [report appendString:@"\n================================================================\n"];
        [report appendString:@"🚨 TWEAKITOK KRİTİK GÜNLÜK: ANİ SONLANDIRILMA (WATCHDOG / SIGKILL)\n"];
        [report appendString:@"================================================================\n"];
        [report appendFormat:@"Tespit Tarihi       : %@\n", [NSDate date]];
        [report appendFormat:@"Oturum Başlangıcı   : %@\n", launchTime];
        [report appendFormat:@"Uygulama Sürümü     : TikTok v%@\n", appVersion];
        [report appendFormat:@"Cihaz Modeli        : %@ (iOS %@)\n", TTK_GetDeviceModel(), [UIDevice currentDevice].systemVersion];
        [report appendFormat:@"Son Durum (State)   : %@\n", lastState];
        [report appendString:@"----------------------------------------------------------------\n"];
        [report appendString:@"Açık Analiz:\n"];
        [report appendString:@"Bu çökme, standart bir kod hatasından (exception) değil; uygulamanın\n"];
        [report appendString:@"iOS işletim sistemi tarafından doğrudan SIGKILL ile öldürülmesinden kaynaklandı.\n"];
        [report appendString:@"Olası Nedenler:\n"];
        [report appendString:@"1. iOS Watchdog (0x8BADF00D): Ana iş parçacığı (Main Thread) 10 saniyeden uzun\n"];
        [report appendString:@"   süre kilitlendi/dondu ve RunLoop'a dönemedi (Örn: Deadlock veya ön plana geçerken takılma).\n"];
        [report appendString:@"2. Kod İmzalama / Geçersiz Sayfa İhlali (Codesigning Invalid Page):\n"];
        [report appendString:@"   İşlemci veri alanından kod çalıştırmaya çalıştı veya Substrate trampoline hatası oluştu.\n"];
        [report appendString:@"3. iOS Bellek Yetersizliği (Jetsam OOM): Cihaz RAM'i tükendi ve sistem TikTok'u kapattı.\n"];
        [report appendString:@"----------------------------------------------------------------\n"];
        [report appendString:@"Önceki Oturumun Son Eylemleri (Breadcrumbs):\n"];
        [report appendString:breadcrumbs.length > 0 ? breadcrumbs : @"  (Kayıtlı eylem bulunamadı)\n"];
        [report appendString:@"================================================================\n\n"];

        [report writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[TweakiTok] Abnormal termination detected from previous run. Log written to: %@", outPath);
    }
}

static void TTK_UpdateActiveSession(const char *state) {
    NSString *sessionPath = TTK_GetActiveSessionFilePath();
    if (!sessionPath) return;

    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *appVersion = infoDict[@"CFBundleShortVersionString"] ?: @"Unknown";

    NSDictionary *dict = @{
        @"cleanExit": @NO,
        @"launchTime": [NSString stringWithFormat:@"%@", [NSDate date]],
        @"appVersion": appVersion,
        @"lastState": [NSString stringWithUTF8String:state ?: "Running"],
        @"breadcrumbs": TTK_GetFormattedBreadcrumbs()
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        [data writeToFile:sessionPath atomically:YES];
    }
}

static void TTK_UncaughtExceptionHandler(NSException *exception) {
    @try {
        TTK_EnsureDocsPath();
        
        NSDate *now = [NSDate date];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS Z"];
        NSString *dateStr = [formatter stringFromDate:now];
        
        NSDateFormatter *fileFormatter = [[NSDateFormatter alloc] init];
        [fileFormatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
        NSString *fileDateStr = [fileFormatter stringFromDate:now];
        NSString *fileName = [NSString stringWithFormat:@"TweakiTok_Crash_%@.txt", fileDateStr];
        
        NSString *docs = [NSString stringWithUTF8String:sDocsPath];
        NSString *filePath = [docs stringByAppendingPathComponent:fileName];
        strncpy(sCrashLogPath, [filePath UTF8String], sizeof(sCrashLogPath) - 1);
        
        NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
        NSString *appVersion = infoDict[@"CFBundleShortVersionString"] ?: @"Unknown";
        NSString *appBuild = infoDict[@"CFBundleVersion"] ?: @"Unknown";
        NSString *osVersion = [UIDevice currentDevice].systemVersion;
        NSString *deviceModel = TTK_GetDeviceModel();
        
        UIViewController *topVC = TTK_GetTopViewController(nil);
        NSString *topVCName = topVC ? NSStringFromClass([topVC class]) : @"Unknown";
        
        NSString *name = [exception name] ?: @"Unknown Exception";
        NSString *reason = [exception reason] ?: @"No reason provided";
        NSDictionary *userInfo = [exception userInfo];
        NSArray *callStack = [exception callStackSymbols];
        
        NSString *explanation = TTK_GetHumanReadableExceptionExplanation(name, reason);
        
        NSMutableString *report = [NSMutableString string];
        [report appendString:@"\n================================================================\n"];
        [report appendString:@"🚨 TWEAKITOK CRASH REPORT (UNCAUGHT EXCEPTION)\n"];
        [report appendString:@"================================================================\n"];
        [report appendFormat:@"Tarih / Saat       : %@\n", dateStr];
        [report appendFormat:@"Günlük Dosyası     : %@\n", fileName];
        [report appendFormat:@"Uygulama Sürümü    : TikTok v%@ (Build %@)\n", appVersion, appBuild];
        [report appendFormat:@"Cihaz Modeli       : %@ (iOS %@)\n", deviceModel, osVersion];
        [report appendFormat:@"Aktif Ekran (TopVC): %@\n", topVCName];
        [report appendString:@"----------------------------------------------------------------\n"];
        [report appendFormat:@"Hata Türü (Name)   : %@\n", name];
        [report appendFormat:@"Hata Sebebi(Reason): %@\n", reason];
        [report appendFormat:@"Açık Analiz        : %@\n", explanation];
        if (userInfo && userInfo.count > 0) {
            [report appendFormat:@"Kullanıcı Verisi   : %@\n", userInfo];
        }
        [report appendString:@"----------------------------------------------------------------\n"];
        [report appendString:@"Son Eylemler (Breadcrumbs):\n"];
        [report appendString:TTK_GetFormattedBreadcrumbs()];
        [report appendString:@"----------------------------------------------------------------\n"];
        [report appendString:@"Çağrı Yığını (Call Stack Trace):\n"];
        
        for (NSUInteger i = 0; i < callStack.count; i++) {
            NSString *frame = callStack[i];
            if ([frame containsString:@"TweakiTok"]) {
                [report appendFormat:@"  ▶ [%02lu] %@  <-- [TWEAKITOK KAYNAKLI!]\n", (unsigned long)i, frame];
            } else if ([frame containsString:@"TikTokComment"] || [frame containsString:@"Comment"]) {
                [report appendFormat:@"  ⚡ [%02lu] %@  <-- [YORUM MODÜLÜ]\n", (unsigned long)i, frame];
            } else {
                [report appendFormat:@"    [%02lu] %@\n", (unsigned long)i, frame];
            }
        }
        [report appendString:@"================================================================\n\n"];
        
        TTK_WriteRawLog([report UTF8String]);
        
        // Latest copy
        NSString *latestPath = [docs stringByAppendingPathComponent:@"TweakiTok_Crash_Latest.txt"];
        [report writeToFile:latestPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[TweakiTok] Crash log written to: %s", sCrashLogPath);
    } @catch (NSException *ex) {
        NSLog(@"[TweakiTok] Failed to format crash report: %@", ex);
    }
    
    if (sPreviousExceptionHandler) {
        sPreviousExceptionHandler(exception);
    }
}

static void TTK_SignalCrashHandler(int sig, siginfo_t *info, void *context) {
    time_t now = time(NULL);
    struct tm tm_info;
    localtime_r(&now, &tm_info);
    char timeBuf[64];
    strftime(timeBuf, sizeof(timeBuf), "%Y-%m-%d %H:%M:%S", &tm_info);
    
    char fileDateBuf[64];
    strftime(fileDateBuf, sizeof(fileDateBuf), "%Y-%m-%d_%H-%M-%S", &tm_info);
    
    char fileName[128];
    snprintf(fileName, sizeof(fileName), "TweakiTok_Crash_%s.txt", fileDateBuf);
    
    if (sDocsPath[0] != '\0') {
        snprintf(sCrashLogPath, sizeof(sCrashLogPath), "%s/%s", sDocsPath, fileName);
    } else {
        snprintf(sCrashLogPath, sizeof(sCrashLogPath), "%s", fileName);
    }
    
    void *addr = info ? info->si_addr : NULL;
    int code = info ? info->si_code : 0;
    const char *sigName = "UNKNOWN";
    switch (sig) {
        case SIGSEGV: sigName = "SIGSEGV (Segmentation Fault)"; break;
        case SIGBUS:  sigName = "SIGBUS (Bus Error)"; break;
        case SIGABRT: sigName = "SIGABRT (Abort)"; break;
        case SIGILL:  sigName = "SIGILL (Illegal Instruction)"; break;
        case SIGFPE:  sigName = "SIGFPE (Floating Point Exception)"; break;
        case SIGTRAP: sigName = "SIGTRAP (Trace/BPT Trap)"; break;
    }
    
    const char *explanation = TTK_GetSignalHumanExplanation(sig, code, addr);
    
    char header[2048];
    snprintf(header, sizeof(header),
             "\n================================================================\n"
             "🚨 TWEAKITOK CRASH REPORT (POSIX SIGNAL CRASH)\n"
             "================================================================\n"
             "Tarih / Saat       : %s\n"
             "Günlük Dosyası     : %s\n"
             "Alınan Sinyal      : %s (No: %d, Code: %d)\n"
             "Hata Adresi (Addr) : %p\n"
             "----------------------------------------------------------------\n"
             "Açık Analiz        : %s\n"
             "----------------------------------------------------------------\n"
             "Çağrı Yığını (Backtrace Symbols):\n",
             timeBuf, fileName, sigName, sig, code, addr, explanation);
    
    TTK_WriteRawLog(header);
    
    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **symbols = backtrace_symbols(callstack, frames);
    if (symbols) {
        for (int i = 0; i < frames; i++) {
            char line[512];
            const char *tag = "";
            if (strstr(symbols[i], "TweakiTok")) {
                tag = "  <-- [TWEAKITOK KAYNAKLI!]";
            } else if (strstr(symbols[i], "TikTokComment") || strstr(symbols[i], "Comment")) {
                tag = "  <-- [YORUM MODÜLÜ]";
            }
            snprintf(line, sizeof(line), "  [%02d] %s%s\n", i, symbols[i], tag);
            TTK_WriteRawLog(line);
        }
        free(symbols);
    }
    
    const char *footer = "================================================================\n\n";
    TTK_WriteRawLog(footer);
    
    signal(sig, SIG_DFL);
    raise(sig);
}

static BOOL sHandlersInstalled = NO;

static void TTK_InstallHandlers(void) {
    if (sHandlersInstalled) return;
    sHandlersInstalled = YES;
    
    sPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&TTK_UncaughtExceptionHandler);
    
    stack_t ss;
    ss.ss_sp = sAlternateStack;
    ss.ss_size = sizeof(sAlternateStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
    
    int signals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL};
    for (int i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        int sig = signals[i];
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = TTK_SignalCrashHandler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);
        
        sigaction(sig, &sa, &sPreviousSigActions[sig]);
    }
    NSLog(@"[TweakiTok] Global Crash Logger handlers successfully installed.");
}

void TTK_SetupGlobalCrashLogger(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        TTK_EnsureDocsPath();
        TTK_InstallHandlers();
        TTK_CheckPreviousSessionForAbnormalTermination();
        TTK_UpdateActiveSession("Launched");
        TTK_RecordBreadcrumb("App Launched & Crash Logger Initialized");
    });
}

NSString *TTK_GetCrashLogFilePath(void) {
    TTK_EnsureDocsPath();
    if (sCrashLogPath[0] != '\0') {
        return [NSString stringWithUTF8String:sCrashLogPath];
    }
    if (sDocsPath[0] == '\0') return nil;
    NSString *docs = [NSString stringWithUTF8String:sDocsPath];
    
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:&error];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'TweakiTok_Crash' AND SELF ENDSWITH '.txt'"];
    NSArray *crashFiles = [files filteredArrayUsingPredicate:predicate];
    if (crashFiles.count > 0) {
        NSArray *sorted = [crashFiles sortedArrayUsingSelector:@selector(compare:)];
        return [docs stringByAppendingPathComponent:sorted.lastObject];
    }
    
    return [docs stringByAppendingPathComponent:@"TweakiTok_Info.txt"];
}

BOOL TTK_IsDeveloperModeEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"developer_mode"];
}
