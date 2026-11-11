#import "CrashLogger.h"
#import "BHIManager.h"

#import <signal.h>
#import <execinfo.h>
#import <sys/utsname.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <time.h>

static NSUncaughtExceptionHandler *sPreviousExceptionHandler = NULL;
static struct sigaction sPreviousSigActions[32];
static char sCrashLogPath[1024] = {0};
static volatile BOOL sDeveloperModeCached = NO;
static char sAlternateStack[SIGSTKSZ * 4];

static NSString *TTK_GetDeviceModel(void) {
    struct utsname systemInfo;
    if (uname(&systemInfo) == 0) {
        return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    }
    return @"Unknown";
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
            return @"[Geçersiz Metot / Unrecognized Selector]: Bir nesneye o nesnede tanımlı olmayan bir fonksiyon/metot çağrısı yapıldı. (Örn: TikTok güncellemesiyle metot imzası değişti veya nil/farklı türde bir nesneye çağrı yapıldı).";
        }
        return @"[Geçersiz Parametre / Invalid Argument]: Bir fonksiyona veya diziye kabul edilemez (nil veya hatalı türde) bir parametre gönderildi.";
    } else if ([name isEqualToString:@"NSRangeException"]) {
        return @"[Dizi Sınır Aşımı / Range Out of Bounds]: Bir dizi (Array), liste veya metin sınırlarının dışındaki bir indekse erişilmeye çalışıldı (Örn: Boş listeden eleman isteme).";
    } else if ([name isEqualToString:@"NSInternalInconsistencyException"]) {
        return @"[Dahili Tutarsızlık / Internal Inconsistency]: UIKit veya dahili bir kütüphane beklenmedik bir durumla karşılaştı (Örn: TableView/CollectionView güncelleme hatası).";
    } else if ([name isEqualToString:@"NSGenericException"]) {
        return @"[Genel Hata / Generic Exception]: İşletim sistemi veya kütüphane seviyesinde genel bir hata oluştu.";
    }
    return @"[Bilinmeyen İstisna / Unhandled Exception]: Yakalanamayan bir Objective-C / Swift çalışma zamanı hatası oluştu.";
}

static const char *TTK_GetSignalHumanExplanation(int sig, int code, void *addr) {
    switch (sig) {
        case SIGSEGV:
            if (addr == NULL || (uintptr_t)addr < 0x1000) {
                return "[Bellek Hatası / NULL Pointer Dereference]: Uygulama NULL / nil (sıfır) olan bir bellek adresine erişmeye çalıştı. Muhtemelen boş bir nesne veya işaretçi referans alındı.";
            }
            return "[Bellek Hatası / Segmentation Fault]: Uygulama geçersiz, silinmiş (deallocated / zombie) veya korumalı bir bellek adresine okuma/yazma yapmaya çalıştı.";
        case SIGBUS:
            return "[Veriyolu Hatası / Bus Error]: Bellek hizalama hatası veya geçersiz donanım/sayfalama bellek erişimi gerçekleşti.";
        case SIGABRT:
            return "[Zorla Sonlandırma / Abort]: Uygulama abort() çağrısı yaptı. Genellikle bir C++ assert(), unhandled exception veya bellek tahsis (malloc) bozulması sonucu oluşur.";
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

static void TTK_UncaughtExceptionHandler(NSException *exception) {
    // Sadece Geliştirici Modu açıksa log kaydet
    if ([BHIManager developerMode]) {
        @try {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS Z"];
            NSString *dateStr = [formatter stringFromDate:[NSDate date]];
            
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
            NSLog(@"[TweakiTok] Crash log written to: %s", sCrashLogPath);
        } @catch (NSException *ex) {
            NSLog(@"[TweakiTok] Failed to format crash report: %@", ex);
        }
    }
    
    // Önceki exception handler'a devret
    if (sPreviousExceptionHandler) {
        sPreviousExceptionHandler(exception);
    }
}

static void TTK_SignalCrashHandler(int sig, siginfo_t *info, void *context) {
    if (sDeveloperModeCached) {
        time_t now = time(NULL);
        struct tm tm_info;
        localtime_r(&now, &tm_info);
        char timeBuf[64];
        strftime(timeBuf, sizeof(timeBuf), "%Y-%m-%d %H:%M:%S", &tm_info);
        
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
                 "Alınan Sinyal      : %s (No: %d, Code: %d)\n"
                 "Hata Adresi (Addr) : %p\n"
                 "----------------------------------------------------------------\n"
                 "Açık Analiz        : %s\n"
                 "----------------------------------------------------------------\n"
                 "Çağrı Yığını (Backtrace Symbols):\n",
                 timeBuf, sigName, sig, code, addr, explanation);
        
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
    }
    
    // Varsayılan sinyal davranışına dön ve uygulamanın donmasını engellemek için yeniden sinyal gönder
    signal(sig, SIG_DFL);
    raise(sig);
}

static BOOL sHandlersInstalled = NO;

static void TTK_InstallHandlersIfNeeded(void) {
    if (sHandlersInstalled) return;
    sHandlersInstalled = YES;
    
    // 1. Uncaught Exception Handler kur
    sPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&TTK_UncaughtExceptionHandler);
    
    // 2. Sinyal çöküşleri için yedek stack (sigaltstack) tahsis et
    stack_t ss;
    ss.ss_sp = sAlternateStack;
    ss.ss_size = sizeof(sAlternateStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
    
    // 3. POSIX Sinyallerini dinle (SIGTRAP/SIGFPE hariç tutularak anti-cheat/debugger çakışması önlendi)
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
        // 1. Documents klasörünü hazırla ve dosya yolunu önceden kaydet
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject;
        if (docs) {
            [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *filePath = [docs stringByAppendingPathComponent:@"TweakiTok_Crash.txt"];
            strncpy(sCrashLogPath, [filePath UTF8String], sizeof(sCrashLogPath) - 1);
        }
        
        // 2. Geliştirici Modu durumunu kontrol et
        sDeveloperModeCached = [[NSUserDefaults standardUserDefaults] boolForKey:@"developer_mode"];
        if (sDeveloperModeCached) {
            TTK_InstallHandlersIfNeeded();
        }
        
        // 3. Ayar açılırsa dinamik olarak handler'ları kur
        [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            sDeveloperModeCached = [[NSUserDefaults standardUserDefaults] boolForKey:@"developer_mode"];
            if (sDeveloperModeCached) {
                TTK_InstallHandlersIfNeeded();
            }
        }];
    });
}

NSString *TTK_GetCrashLogFilePath(void) {
    if (sCrashLogPath[0] != '\0') {
        return [NSString stringWithUTF8String:sCrashLogPath];
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths.firstObject stringByAppendingPathComponent:@"TweakiTok_Crash.txt"];
}

BOOL TTK_IsDeveloperModeEnabled(void) {
    return sDeveloperModeCached;
}
