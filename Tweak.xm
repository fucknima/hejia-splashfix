// ============================================================================
//  移动爱家 (zhihuiguanjia) 检测绕过 Tweak
//  Bundle : com.cmcc.zhihuiguanjia
//  Author : nanoMuse      Version: 1.0.0
// ----------------------------------------------------------------------------
//  说明
//   目标 App 内嵌 XJSpeechManager.framework，自带 5 个 Detector：
//     JailbreakDetector / TamperingDetector / InjectionDetector /
//     DebugDetector    / ProxyDetector
//   其中 TamperingDetector.isTampered 会读取 Info.plist 里的
//   embedded.mobileprovision，再与框架内置的 2 个 CDHash 白名单比对；
//   isTamperedWithExpectedTeamID: 会从 mobileprovision 中取
//   application-identifier 的 TeamID 段与期望值比较。
//   → 解密包 CDHash 必然变化 / 重签后 TeamID 必然变化，故两者都是 NO。
//   另覆盖 BlackbeesFrameworkSDK 的 BBJailbreakDetector 与常见 C 层检测。
// ============================================================================

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <dlfcn.h>

#include <substrate.h>

// --- iOS SDK 缺失的声明（tweak 通用补法）----------------------------------
// 1) caddr_t：iOS SDK 不导出
#ifndef _CADDR_T
typedef char *caddr_t;
#define _CADDR_T
#endif
// 2) ptrace：iOS SDK 无 <sys/ptrace.h>；Theos 以 ObjC++ 编译，需 extern "C"
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
#ifdef __cplusplus
extern "C" int ptrace(int request, pid_t pid, caddr_t addr, int data);
#else
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
#endif

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
extern "C" void HTLog(const char *tag, NSString *msg);
#define HM_LOG(...) HTLog("HeJiaBypass", [NSString stringWithFormat:__VA_ARGS__])

// ---------------------------------------------------------------------------
// 工具：仅当方法真实存在才替换，避免向不存在的类注入导致崩溃
// ---------------------------------------------------------------------------
static IMP HMHookedClassMethod(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        HM_LOG(@"[%@ %@] 不存在，跳过", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_setImplementation(m, newImp);
    HM_LOG(@"hook 类方法 [%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
    return old;
}

__attribute__((unused))
static IMP HMHookedInstanceMethod(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        HM_LOG(@"[%@ %@] 不存在，跳过", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_setImplementation(m, newImp);
    HM_LOG(@"hook 实例方法 [%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
    return old;
}

// ---------------------------------------------------------------------------
// 通用「安全」返回值实现（签名必须与目标方法完全一致）
// ---------------------------------------------------------------------------
// 无参数，返回 BOOL（类方法 / 实例方法通用：self + _cmd）
static BOOL HMReturnNO(id self, SEL _cmd) { return NO; }
// 一个 id 参数，返回 BOOL
static BOOL HMReturnNO_arg1(id self, SEL _cmd, id a) { return NO; }
// 三个 id 参数，返回 void
__attribute__((unused))
static void HMReturnVoid_arg3(id self, SEL _cmd, id a, id b, id c) { }

// ---------------------------------------------------------------------------
// 1. XJSpeechManager —— 5 个 Detector
// ---------------------------------------------------------------------------
static void HMHookXJSpeechManager(void) {
    Class t;

    t = objc_getClass("_TtC15XJSpeechManager17JailbreakDetector");
    if (t) HMHookedClassMethod(object_getClass(t), @selector(isJailbroken), (IMP)HMReturnNO);

    t = objc_getClass("_TtC15XJSpeechManager17TamperingDetector");
    if (t) {
        Class meta = object_getClass(t);
        HMHookedClassMethod(meta, @selector(isTampered), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(isTamperedWithExpectedTeamID:), (IMP)HMReturnNO_arg1);
    }

    t = objc_getClass("_TtC15XJSpeechManager17InjectionDetector");
    if (t) HMHookedClassMethod(object_getClass(t), @selector(isInjected), (IMP)HMReturnNO);

    t = objc_getClass("_TtC15XJSpeechManager13DebugDetector");
    if (t) HMHookedClassMethod(object_getClass(t), @selector(isBeingDebugged), (IMP)HMReturnNO);

    t = objc_getClass("_TtC15XJSpeechManager13ProxyDetector");
    if (t) {
        Class meta = object_getClass(t);
        HMHookedClassMethod(meta, @selector(isProxyEnabled), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(isExternalProxyEnabled), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(isVPNTunnelActive), (IMP)HMReturnNO);
    }
}

// ---------------------------------------------------------------------------
// 2. BlackbeesFrameworkSDK —— 4 组检测类（全部是类方法）
//    BBJailbreakDetector : isJailbroken / hasSuspiciousFiles /
//                          canWriteOutsideSandbox / hasInjectedDynamicLibrary /
//                          hasCydiaURLScheme
//    BBHookDetector      : isHooked / hasSuspiciousFiles /
//                          hasSuspiciousEnv / hasFunctionHooked
//    BBProxyDetector     : isUsingProxy
//    BBAntiDebug         : enable / disableDebugger / checkDebugger  (void)
// ---------------------------------------------------------------------------
static void HMVoid(id self, SEL _cmd) { }

static void HMHookBlackbees(void) {
    Class c;

    c = objc_getClass("BBJailbreakDetector");
    if (c) {
        Class meta = object_getClass(c);
        HMHookedClassMethod(meta, @selector(isJailbroken), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(hasSuspiciousFiles), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(canWriteOutsideSandbox), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(hasInjectedDynamicLibrary), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(hasCydiaURLScheme), (IMP)HMReturnNO);
    }

    c = objc_getClass("BBHookDetector");
    if (c) {
        Class meta = object_getClass(c);
        HMHookedClassMethod(meta, @selector(isHooked), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(hasSuspiciousFiles), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(hasSuspiciousEnv), (IMP)HMReturnNO);
        HMHookedClassMethod(meta, @selector(hasFunctionHooked), (IMP)HMReturnNO);
    }

    c = objc_getClass("BBProxyDetector");
    if (c) {
        HMHookedClassMethod(object_getClass(c), @selector(isUsingProxy), (IMP)HMReturnNO);
    }

    // 调试器附加/阻断逻辑，直接置空，避免它调用 PT_DENY_ATTACH
    c = objc_getClass("BBAntiDebug");
    if (c) {
        Class meta = object_getClass(c);
        HMHookedClassMethod(meta, @selector(enable), (IMP)HMVoid);
        HMHookedClassMethod(meta, @selector(disableDebugger), (IMP)HMVoid);
        HMHookedClassMethod(meta, @selector(checkDebugger), (IMP)HMVoid);
    }
}

// ---------------------------------------------------------------------------
// 3. 主包里存在的防篡改 / andlink 环境检查（3 参数版本）
//    ⚠️ 这两种方法在主二进制中确实存在，但所属类名未在静态分析中确认，
//    因此改为「运行期按方法名全量扫描」：遍历所有已加载类，
//    谁实现了该选择器就 hook 谁，避免类名写错导致静默失效。
// ---------------------------------------------------------------------------
// 判断某个类是否属于【当前主 App 进程】的镜像
// ⚠️ 注意：不能只排除 /System/Library，那样会把同进程内其他 App 的
//    注入类也当成自己的（实测误伤了 NHEWebsocketSession 导致登录失败）
static BOOL HMClassBelongsToApp(Class c) {
    Dl_info info;
    if (!dladdr((__bridge const void *)c, &info) || !info.dli_fname) return NO;

    // 系统库直接排除
    if (strstr(info.dli_fname, "/System/Library/") ||
        strstr(info.dli_fname, "/usr/lib/") ||
        strstr(info.dli_fname, "/Developer/")) {
        return NO;
    }

    // 必须位于本 App 的 .app 目录内
    static char appPath[1024] = {0};
    static BOOL pathReady = NO;
    if (!pathReady) {
        const char *bundle = [[[NSBundle mainBundle] bundlePath] UTF8String];
        if (bundle) strncpy(appPath, bundle, sizeof(appPath) - 1);
        pathReady = YES;
    }
    if (!appPath[0]) return NO;
    return strstr(info.dli_fname, appPath) != NULL;
}

__attribute__((unused))
static int HMHookAllClassesImplementing(SEL sel, IMP newImp, const char *label) {
    int count = 0;
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (!all) return 0;

    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        if (!c) continue;

        // 先按方法表筛选：没有本类自己实现该选择器的直接跳过，
        // 这样绝大多数无关类都不会走到 dladdr，性能可控
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(c, &mcount);
        if (!methods) continue;

        Method hit = NULL;
        for (unsigned int j = 0; j < mcount; j++) {
            if (sel_isEqual(method_getName(methods[j]), sel)) {
                if (method_getImplementation(methods[j]) == newImp) {  // 已 hook
                    hit = NULL;
                    break;
                }
                hit = methods[j];
                break;
            }
        }

        if (hit && HMClassBelongsToApp(c)) {
            method_setImplementation(hit, newImp);
            HM_LOG(@"hook [%@ %@] (%@)",
                   [NSString stringWithUTF8String:class_getName(c) ?: "?"],
                   NSStringFromSelector(sel),
                   [NSString stringWithUTF8String:label ?: "?"]);
            count++;
        }
        free(methods);
    }
    free(all);
    return count;
}

// 主包业务层：已移除
// ⚠️ 曾经用「全类扫描」hook deviceAntiTamperAction:value:callbackHandle:，
//    结果误伤到 NHEWebsocketSession（非本 App 的类），导致长连接失效、
//    登录卡死。这两个方法不再 hook，风险远大于收益。
static void HMHookMainAppExtra(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    HM_LOG(@"主包业务层 hook 已停用（避免误伤）");
}

// ---------------------------------------------------------------------------
// 4. C 层：文件存在性 / sysctl / ptrace / 系统代理
// ---------------------------------------------------------------------------
static BOOL (*original_fileExistsAtPath)(id, SEL, NSString *, BOOL *) = NULL;

static BOOL HMFileExistsAtPath(id self, SEL _cmd, NSString *path, BOOL *isDirectory) {
    static NSArray<NSString *> *banned = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        banned = @[
            @"/Applications/Cydia.app",
            @"/Library/MobileSubstrate",
            @"/Library/MobileSubstrate/MobileSubstrate.dylib",
            @"/Library/MobileSubstrate/DynamicLibraries",
            @"/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist",
            @"/System/Library/LaunchDaemons/com.ikey.bbot.plist",
            @"/private/var/lib/apt",
            @"/private/var/lib/cydia",
            @"/private/var/stash",
            @"/private/var/mobile/Library/SBSettings/Themes",
            @"/etc/apt",
            @"/bin/bash",
            @"/usr/sbin/sshd",
            @"/usr/libexec/ssh-keysign",
            @"/usr/bin/ssh",
            @"/etc/ssh/sshd_config",
            @"/usr/lib/libsubstrate.dylib",
            @"/usr/lib/libcycript.dylib",
            @"/usr/bin/cycript",
            @"/usr/local/bin/frida-server",
            @"/usr/bin/frida-server",
            @"/Applications/Frida.app",
            @"/var/jb",
        ];
    });

    if ([path isKindOfClass:[NSString class]]) {
        for (NSString *b in banned) {
            if ([path isEqualToString:b] ||
                [path hasPrefix:[b stringByAppendingString:@"/"]]) {
                if (isDirectory) *isDirectory = NO;
                return NO;
            }
        }
        // 越狱检测常用的「写沙盒外测试文件」
        if ([path hasPrefix:@"/private/jailbreak_test_"] ||
            [path containsString:@"jailbreak_test"]) {
            if (isDirectory) *isDirectory = NO;
            return NO;
        }
        // 签名来源判断：伪装成 App Store 正版
        // - embedded.mobileprovision 存在 => 侧载/重签，必须报「不存在」
        // - sandboxReceipt            => 沙盒包，同样按不存在处理
        if ([path containsString:@"embedded.mobileprovision"] ||
            [path containsString:@"sandboxReceipt"]) {
            if (isDirectory) *isDirectory = NO;
            return NO;
        }
    }
    if (original_fileExistsAtPath) {
        return original_fileExistsAtPath(self, _cmd, path, isDirectory);
    }
    if (isDirectory) *isDirectory = NO;
    return NO;
}

// sysctl：清除 kinfo_proc 的 P_TRACED 标记
// 注意：iOS SDK 已不导出 <sys/proc.h>，struct kinfo_proc 不可用，
//       因此改为按原始内存偏移扫描（arm64 上 p_flag 位于结构体偏移 32）。
static int (*original_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;

#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

// arm64 的 struct extern_proc 中 p_flag 的偏移
#define HM_P_FLAG_OFFSET 32
#define HM_KINFO_PROC_SIZE 0x88   // sizeof(struct kinfo_proc) on arm64

static int HM_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                     void *newp, size_t newlen) {
    if (!original_sysctl) return -1;

    int ret = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

    // 调试检测惯用写法：sysctl([CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()])
    if (ret == 0 && name && namelen >= 4 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_PID &&
        oldp && oldlenp && *oldlenp >= HM_KINFO_PROC_SIZE) {
        int *flag = (int *)((unsigned char *)oldp + HM_P_FLAG_OFFSET);
        *flag &= ~P_TRACED;
    }
    return ret;
}

static int (*original_ptrace)(int, pid_t, caddr_t, int) = NULL;

static int HM_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    // 屏蔽 PT_DENY_ATTACH（31）：直接返回 0，既不附加调试器也不阻止
    if (request == 31) return 0;
    if (original_ptrace) return original_ptrace(request, pid, addr, data);
    return 0;
}

// ---------------------------------------------------------------------------
// 4.5 签名来源伪装（关键：消除「重签名风险」弹窗）
//
// 主二进制里没有任何 SecStaticCode/SecCodeCheckValidity 系统校验调用，
// 只用到了这些「路径/存在性」判断，然后上报服务端：
//     appStoreReceiptURL   (NSBundle)
//     sandboxReceipt       (receipt 路径含此片段 = 沙盒/侧载)
//     embedded.mobileprovision
// 沙盒注入/侧载时 appStoreReceiptURL 会变成 /var/containers/.../sandboxReceipt，
// 服务端据此判定「重签名」并下发弹窗。
// 这里统一伪装成 App Store 正版环境。
// ---------------------------------------------------------------------------
static NSURL *(*original_appStoreReceiptURL)(id, SEL) = NULL;
static NSURL *HM_appStoreReceiptURL(id self, SEL _cmd) {
    // 返回标准 App Store receipt 路径（真实文件不存在也无妨，
    // 检测方通常只判断路径形态，不做真实校验）
    NSString *path = [@"~/Documents/../StoreKit/receipt" stringByExpandingTildeInPath];
    (void)path;
    return [NSURL fileURLWithPath:@"/var/mobile/Containers/Bundle/Application/StoreKit/receipt"];
}

// 文件是否存在：把 embedded.mobileprovision / sandboxReceipt 的判断也纳入控制
static BOOL HMFileExistsAtPath(id self, SEL _cmd, NSString *path, BOOL *isDirectory);

// 系统代理：返回空字典（既无 HTTP 也无 HTTPS 代理）
static CFDictionaryRef (*original_copyProxySettings)(void) = NULL;
static CFDictionaryRef HM_CopySystemProxySettings(void) {
    if (original_copyProxySettings) {
        CFDictionaryRef d = original_copyProxySettings();
        if (d) CFRelease(d);
    }
    return CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
}

// ---------------------------------------------------------------------------
// NSBundle pathForResource:ofType: —— 拦截 embedded.mobileprovision 查询
// App 可能用 pathForResource:@"embedded" ofType:@"mobileprovision" 取路径
// ---------------------------------------------------------------------------
static NSString *(*original_pathForResource)(id, SEL, NSString *, NSString *) = NULL;

static NSString *HM_pathForResourceOfType(id self, SEL _cmd, NSString *name, NSString *type) {
    if ([name isEqualToString:@"embedded"] && [type isEqualToString:@"mobileprovision"]) {
        HM_LOG(@"拦截 pathForResource:embedded mobileprovision -> nil");
        return nil;
    }
    if (original_pathForResource) {
        return original_pathForResource(self, _cmd, name, type);
    }
    return nil;
}

static void HMInstallCHooks(void) {
    // NSBundle.appStoreReceiptURL —— 侧载时指向 sandboxReceipt
    Class NSBundleCls = objc_getClass("NSBundle");
    if (NSBundleCls) {
        Method m = class_getInstanceMethod(NSBundleCls, @selector(appStoreReceiptURL));
        if (m) {
            original_appStoreReceiptURL = (NSURL *(*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)HM_appStoreReceiptURL);
            HM_LOG(@"hook -[NSBundle appStoreReceiptURL] -> 伪装 App Store");
        }
    }

    // NSBundle pathForResource:ofType:
    Class NSBundleC = objc_getClass("NSBundle");
    if (NSBundleC) {
        Method m = class_getInstanceMethod(NSBundleC, @selector(pathForResource:ofType:));
        if (m) {
            original_pathForResource = (NSString *(*)(id, SEL, NSString *, NSString *))
                                        method_getImplementation(m);
            method_setImplementation(m, (IMP)HM_pathForResourceOfType);
            HM_LOG(@"hook -[NSBundle pathForResource:ofType:]");
        }
    }

    Class NSFileMgr = objc_getClass("NSFileManager");
    if (NSFileMgr) {
        Method m = class_getInstanceMethod(NSFileMgr, @selector(fileExistsAtPath:isDirectory:));
        if (m) {
            original_fileExistsAtPath = (BOOL (*)(id, SEL, NSString *, BOOL *))
                                        method_getImplementation(m);
            method_setImplementation(m, (IMP)HMFileExistsAtPath);
            HM_LOG(@"hook -[NSFileManager fileExistsAtPath:isDirectory:]");
        }
    }

    MSHookFunction((void *)sysctl, (void *)HM_sysctl, (void **)&original_sysctl);
    HM_LOG(@"hook sysctl");

    MSHookFunction((void *)ptrace, (void *)HM_ptrace, (void **)&original_ptrace);
    HM_LOG(@"hook ptrace");

    MSHookFunction((void *)CFNetworkCopySystemProxySettings,
                   (void *)HM_CopySystemProxySettings,
                   (void **)&original_copyProxySettings);
    HM_LOG(@"hook CFNetworkCopySystemProxySettings");
}

// ---------------------------------------------------------------------------
// 5. 延迟钩子：兜住运行期 dlopen 的框架
// ---------------------------------------------------------------------------
static void HMScheduleLateHooks(void) {
    // 用全局队列而非主队列：避免 App 主线程启动期卡住时延迟任务不执行
    static const int64_t delays[] = { 1, 3, 6, 12 };
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * NSEC_PER_SEC), q, ^{
            @autoreleasepool {
                HMHookBlackbees();
                HMHookMainAppExtra();
            }
        });
    }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void HeJiaBypassInit(void) {
    @autoreleasepool {
        HM_LOG(@"════ 移动爱家检测绕过 v1.0.0 已加载 ════");

        // 轻量钩子：直接 hook 指定类，成本极低
        HMHookXJSpeechManager();
        HMHookBlackbees();
        HMInstallCHooks();

        // 重活：全类扫描（几十万类）→ 延后到后台，避免阻塞首屏
        // 否则会与 UI 初始化叠加触发 0x8BADF00D 看门狗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool { HMHookMainAppExtra(); }
        });

        HMScheduleLateHooks();

        HM_LOG(@"════ 初始化完成 ════");
    }
}
