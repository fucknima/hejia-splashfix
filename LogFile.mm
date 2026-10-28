// ============================================================================
//  日志落盘模块 v3
//  Bundle: com.cmcc.zhihuiguanjia
// ----------------------------------------------------------------------------
//  ⚠️ 崩溃历史：
//    v2: HTWriteLog 内部用 va_arg(cp, id) 解析 %@ 参数。
//        变参表里只要有一个非对象参数（CGRect 按值传、int、double…），
//        在 ARC 下就会被当成 id 去 objc_retain → EXC_BAD_ACCESS 崩溃
//        (栈：objc_retain <- HTWriteLog，thread com.apple.root.utility-qos)
//
//  v3 方案：彻底不在 C 函数里解析变参
//    调用方直接用 NSString 拼好内容，只传一个 NSString 进来：
//        HTLog(tag, NSString *line)
//        宏展开为：HTLog("tag", [NSString stringWithFormat:...])
//    这样 %@ 由系统的 stringWithFormat 处理，永远不会错位。
// ============================================================================

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <pthread.h>
#include <sys/stat.h>

#define LOG_MAX_BYTES (512 * 1024)
#define GROUP_ID      "group.com.cmcc.zhihuiguanjia"

static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;

// 日志总开关：设置页可关，关闭后不再写任何文件（含 stderr）
static volatile int gLogEnabled = 1;
static NSString *const kHTLogEnabledKey = @"HeJiaTool_LogEnabled";

extern "C" {

const char *HTGetLogFilePath(void);
const char *HTGetAdScanLogPath(void);
const char *HTGetLogDir(void);
void HTLog(const char *tag, NSString *msg);
void HTLogC(const char *tag, const char *cfmt, ...);
void HTScan(NSString *msg);
void HTSetLogEnabled(BOOL enabled);
BOOL HTGetLogEnabled(void);

// ---------------------------------------------------------------------------
// 目录：只写 App Group 共享容器
// ---------------------------------------------------------------------------
static const char *HTResolveDir(void) {
    static char dir[1200] = {0};
    static BOOL inited = NO;
    if (inited) return dir;

    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *chosen = nil;

        @try {
            NSURL *g = [fm containerURLForSecurityApplicationGroupIdentifier:
                           [NSString stringWithUTF8String:GROUP_ID]];
            if (g && g.path) {
                NSString *sub = [g.path stringByAppendingPathComponent:@"HeJiaTool"];
                NSError *e = nil;
                if ([fm createDirectoryAtPath:sub withIntermediateDirectories:YES
                                   attributes:nil error:&e]) {
                    chosen = sub;
                } else {
                    chosen = g.path;
                }
            }
        } @catch (NSException *ex) {
            (void)ex;
        }

        if (!chosen) {
            NSArray *docs = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES);
            if (docs.count > 0) {
                NSString *sub = [docs[0] stringByAppendingPathComponent:@"HeJiaTool"];
                NSError *e2 = nil;
                [fm createDirectoryAtPath:sub withIntermediateDirectories:YES
                               attributes:nil error:&e2];
                chosen = sub;
            } else {
                chosen = NSTemporaryDirectory();
            }
        }

        const char *u = chosen.UTF8String;
        if (u) strncpy(dir, u, sizeof(dir) - 1);
    }
    inited = YES;
    return dir;
}

const char *HTGetLogDir(void) { return HTResolveDir(); }

const char *HTGetLogFilePath(void) {
    static char p[1400] = {0};
    if (!p[0]) snprintf(p, sizeof(p), "%s/HeJiaTool.log", HTResolveDir());
    return p;
}

const char *HTGetAdScanLogPath(void) {
    static char p[1400] = {0};
    if (!p[0]) snprintf(p, sizeof(p), "%s/adscan.log", HTResolveDir());
    return p;
}

static void HTRotate(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return;
    if (st.st_size < LOG_MAX_BYTES) return;
    char bak[1500];
    snprintf(bak, sizeof(bak), "%s.1", path);
    rename(path, bak);
}

// ---------------------------------------------------------------------------
// 核心：写入已经拼好的 NSString（无变参解析，绝对安全）
// ---------------------------------------------------------------------------
static void HTWriteLine(const char *path, const char *tag, NSString *msg) {
    if (!path || !msg) return;
    if (!gLogEnabled) return;

    @autoreleasepool {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        NSString *ts = [df stringFromDate:[NSDate date]];

        NSString *line = tag
            ? [NSString stringWithFormat:@"%@ [%@] %@\n", ts,
                                        [NSString stringWithUTF8String:tag], msg]
            : [NSString stringWithFormat:@"%@ %@\n", ts, msg];

        const char *cs = line.UTF8String;
        if (!cs) return;

        fprintf(stderr, "%s", cs);

        pthread_mutex_lock(&gLogLock);
        HTRotate(path);
        FILE *fp = fopen(path, "a");
        if (fp) { fputs(cs, fp); fclose(fp); }
        pthread_mutex_unlock(&gLogLock);
    }
}

void HTLog(const char *tag, NSString *msg) {
    HTWriteLine(HTGetLogFilePath(), tag, msg);
}

void HTScan(NSString *msg) {
    HTWriteLine(HTGetAdScanLogPath(), NULL, msg);
}

void HTSetLogEnabled(BOOL enabled) {
    gLogEnabled = enabled ? 1 : 0;
    @try {
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kHTLogEnabledKey];
    } @catch (__unused NSException *e) {}
}

BOOL HTGetLogEnabled(void) { return gLogEnabled != 0; }

// 纯 C 格式版本（不含 %@），给不想用 NSString 的地方用
void HTLogC(const char *tag, const char *cfmt, ...) {
    if (!cfmt) return;
    char buf[2048];
    va_list ap;
    va_start(ap, cfmt);
    vsnprintf(buf, sizeof(buf), cfmt, ap);
    va_end(ap);
    NSString *s = [NSString stringWithUTF8String:buf];
    HTWriteLine(HTGetLogFilePath(), tag, s ?: @"");
}

// ---------------------------------------------------------------------------
__attribute__((constructor))
static void HTLogInit(void) {
    @autoreleasepool {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *ver = @"?";
        @try { ver = info[@"CFBundleShortVersionString"] ?: @"?"; } @catch (NSException *e) { (void)e; }

        @try {
            id v = [[NSUserDefaults standardUserDefaults] objectForKey:kHTLogEnabledKey];
            gLogEnabled = v ? ([[NSUserDefaults standardUserDefaults] boolForKey:kHTLogEnabledKey] ? 1 : 0) : 1;
        } @catch (__unused NSException *e) {}

        BOOL groupOK = NO;
        @try {
            NSURL *g = [[NSFileManager defaultManager]
                containerURLForSecurityApplicationGroupIdentifier:
                    [NSString stringWithUTF8String:GROUP_ID]];
            groupOK = (g != nil);
        } @catch (NSException *e) { (void)e; }

        HTLog("HeJiaTool", @"==================== 新会话 ====================");
        HTLog("HeJiaTool", [NSString stringWithFormat:@"App %@", ver]);
        HTLog("HeJiaTool", [NSString stringWithFormat:@"日志目录: %@",
                            [NSString stringWithUTF8String:HTGetLogDir()]]);
        HTLog("HeJiaTool", [NSString stringWithFormat:@"AppGroup 可用: %@",
                            groupOK ? @"YES" : @"NO"]);
    }
}

} // extern "C"
