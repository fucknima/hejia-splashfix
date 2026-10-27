// ============================================================================
//  NoAds.mm — 广告屏蔽 v2（开屏黑屏修复版）
//  Bundle: com.cmcc.zhihuiguanjia
// ----------------------------------------------------------------------------
//  与旧版（hejia-bypass/NoAds.xm）的差异：
//    ✗ 删掉网络层拦截：返回空 body / about:blank 会让广告容器留一个空窗口，
//      既挡触摸又可能整块黑，旧版实测已经把它移除了。
//    ✗ 删掉 HYLaunchAdManager 数据置空：getLaunchViewData 是 void，
//      safeAdDataArray* 被置 nil 后开屏 window 仍会创建 → 开屏后黑屏。
//    ✓ 开屏改为「保留流程 + 立即 dismiss」：startAdLaunch: 之后调
//      -[HYLaunchAdView dismissView] 并隐藏它的 window，走完 onAdDismissed。
//    ✓ 只做展示层/开关层抑制，不碰 init/load/bidding/超时。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>
#include <dlfcn.h>

extern "C" void HTLog(const char *tag, NSString *msg);
extern "C" void HTLogC(const char *tag, const char *cfmt, ...);

#define NA_LOG(...)  HTLog("HeJiaNoAds", [NSString stringWithFormat:__VA_ARGS__])
#define NA_SCAN(cfmt, ...) HTLogC("SCAN", cfmt, ##__VA_ARGS__)

extern "C" {

static NSString *const kNAEnabledKey = @"HeJiaTool_NoAds";

static BOOL NAEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kNAEnabledKey];
    return v ? [v boolValue] : YES;   // 未设置 = 开
}

// ===========================================================================
//  1) 开屏：显示流程照走，视图立刻关掉
// ===========================================================================
static void (*NAOrigStartAdLaunch)(id, SEL, id) = NULL;
static BOOL NAHasSplashHook = NO;

static id NAValue(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void NADismissLaunch(id manager, NSInteger attempt) {
    id view = NAValue(manager, @"launchAdView");
    if (!view) view = NAValue(manager, @"launchAdForPadView");
    if (!view) {
        if (attempt < 4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ NADismissLaunch(manager, attempt + 1); });
        }
        return;
    }
    if (![view isKindOfClass:[UIView class]]) return;

    UIView *v = (UIView *)view;
    UIView *win = v.window;
    SEL sel = sel_registerName("dismissView");
    if ([v respondsToSelector:sel]) {
        void (*fn)(id, SEL) = (void (*)(id, SEL))[v methodForSelector:sel];
        if (fn) fn(v, sel);
    }
    [v setHidden:YES];
    [v setAlpha:0];
    if (win) win.hidden = YES;
    NA_LOG(@"开屏已关闭 view=%@ window=%@", v, win);
}

static void NAStartAdLaunch(id self, SEL _cmd, id arg) {
    if (NAOrigStartAdLaunch) NAOrigStartAdLaunch(self, _cmd, arg);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ NADismissLaunch(self, 0); });
}

static void NAInstallSplash(void) {
    if (NAHasSplashHook) return;
    Class cls = objc_getClass("HYLaunchAdManager");
    if (!cls) { NA_LOG(@"找不到 HYLaunchAdManager"); return; }
    Method m = class_getInstanceMethod(cls, sel_registerName("startAdLaunch:"));
    if (!m) { NA_LOG(@"找不到 -startAdLaunch:"); return; }
    const char *types = method_getTypeEncoding(m);
    if (!types || types[0] != 'v' || types[1] != '2' || types[2] != '4') {
        NA_LOG(@"startAdLaunch: 签名不符, 跳过: %s", types ?: "?");
        return;
    }
    NAOrigStartAdLaunch = (void (*)(id, SEL, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)NAStartAdLaunch);
    NAHasSplashHook = YES;
    NA_LOG(@"hook -[HYLaunchAdManager startAdLaunch:]");
}

// ===========================================================================
//  2) 总开关：HYGetAdSwitchState
// ===========================================================================
static BOOL NANO0(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
static void NAVoid1(id self, SEL _cmd, id a) { (void)self; (void)_cmd; (void)a; }

static void NAPatchSwitch(void) {
    Class c = objc_getClass("HYGetAdSwitchState");
    if (!c) { NA_LOG(@"未找到 HYGetAdSwitchState"); return; }

    Method m = class_getInstanceMethod(c, sel_registerName("getSwitchState"));
    if (m) { method_setImplementation(m, (IMP)NANO0); NA_LOG(@"getSwitchState -> NO"); }
    m = class_getInstanceMethod(c, sel_registerName("switchState"));
    if (m) { method_setImplementation(m, (IMP)NANO0); NA_LOG(@"switchState -> NO"); }
    m = class_getInstanceMethod(c, sel_registerName("setSwitchState:"));
    if (m) { method_setImplementation(m, (IMP)NAVoid1); NA_LOG(@"setSwitchState: -> noop"); }

    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"adSwitchCloseStateStr"];
}

// ===========================================================================
//  3) isShowAd* 标志位
// ===========================================================================
static BOOL NAIsAppClass(Class c) {
    Dl_info info;
    if (!dladdr((__bridge const void *)c, &info) || !info.dli_fname) return NO;
    if (strstr(info.dli_fname, "/System/Library/") ||
        strstr(info.dli_fname, "/usr/lib/")) return NO;
    return YES;
}

static int NAArgc(const char *sel) {
    int n = 0;
    if (!sel) return 0;
    for (const char *p = sel; *p; p++) if (*p == ':') n++;
    return n;
}

static void NAPatchShowFlags(void) {
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (!all) return;
    int n = 0;
    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        if (!c || !NAIsAppClass(c)) continue;
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(c, &cnt);
        if (!ms) continue;
        for (unsigned int j = 0; j < cnt; j++) {
            const char *sn = sel_getName(method_getName(ms[j]));
            const char *types = method_getTypeEncoding(ms[j]);
            if (!sn || !types || types[0] != 'B' || NAArgc(sn) != 0) continue;
            if (strncmp(sn, "isShowAd", 8) && strncmp(sn, "isShowAD", 8)) continue;
            method_setImplementation(ms[j], (IMP)NANO0);
            n++;
        }
        free(ms);
    }
    free(all);
    NA_LOG(@"isShowAd* 屏蔽 %d 个", n);
}

// ===========================================================================
//  4) 广告 SDK：只屏蔽展示方法（不碰 init/start/load/bidding）
// ===========================================================================
static void NA_Void0(id self, SEL _cmd) { (void)self; (void)_cmd; }
static void NA_Void1(id self, SEL _cmd, id a) { (void)self; (void)_cmd; (void)a; }
static void NA_Void2(id self, SEL _cmd, id a, id b) { (void)self; (void)_cmd; (void)a; (void)b; }
static void NA_Void3(id self, SEL _cmd, id a, id b, id c) {
    (void)self; (void)_cmd; (void)a; (void)b; (void)c;
}
static void NA_Void4(id self, SEL _cmd, id a, id b, id c, id d) {
    (void)self; (void)_cmd; (void)a; (void)b; (void)c; (void)d;
}
static id NA_Nil0(id self, SEL _cmd) { (void)self; (void)_cmd; return nil; }
static id NA_Nil1(id self, SEL _cmd, id a) { (void)self; (void)_cmd; (void)a; return nil; }
static id NA_Nil2(id self, SEL _cmd, id a, id b) { (void)self; (void)_cmd; (void)a; (void)b; return nil; }
static id NA_Nil3(id self, SEL _cmd, id a, id b, id c) {
    (void)self; (void)_cmd; (void)a; (void)b; (void)c; return nil;
}
static id NA_Nil4(id self, SEL _cmd, id a, id b, id c, id d) {
    (void)self; (void)_cmd; (void)a; (void)b; (void)c; (void)d; return nil;
}

static IMP NANilFor(int argc) {
    switch (argc) {
        case 0: return (IMP)NA_Nil0;
        case 1: return (IMP)NA_Nil1;
        case 2: return (IMP)NA_Nil2;
        case 3: return (IMP)NA_Nil3;
        default: return (IMP)NA_Nil4;
    }
}

static IMP NAVoidFor(int argc) {
    switch (argc) {
        case 0: return (IMP)NA_Void0;
        case 1: return (IMP)NA_Void1;
        case 2: return (IMP)NA_Void2;
        case 3: return (IMP)NA_Void3;
        default: return (IMP)NA_Void4;
    }
}

static BOOL NAIsAdSDKClass(const char *name) {
    static const char *prefixes[] = {
        "ABU", "BUAd", "BUNative", "BUSplash", "BUM",
        "GDT", "KSAd", "BaiduMobAd",
        "JAD", "CSJ", "DSP", "MIGUAd", "MIGUAD",
        "Sigmob", "Gromore", "MADX", "CXAd", "CXJAd",
        "MSAd", "MediaMobAd", "Pangle",
        NULL
    };
    for (int i = 0; prefixes[i]; i++) {
        if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0) return YES;
    }
    return NO;
}

static void NAPatchAdSDKClasses(void) {
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (!all) return;

    int patched = 0;
    int statABU = 0, statGDT = 0, statKS = 0, statBaidu = 0, statJAD = 0,
        statDSP = 0, statMIGU = 0, statOther = 0;

    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        if (!c) continue;
        const char *cn = class_getName(c);
        if (!cn || !NAIsAdSDKClass(cn)) continue;
        if (!NAIsAppClass(c)) continue;

        if (!strncmp(cn, "ABU", 3) || !strncmp(cn, "BUAd", 4)) statABU++;
        else if (!strncmp(cn, "GDT", 3)) statGDT++;
        else if (!strncmp(cn, "KSAd", 4)) statKS++;
        else if (!strncmp(cn, "BaiduMobAd", 10)) statBaidu++;
        else if (!strncmp(cn, "JAD", 3)) statJAD++;
        else if (!strncmp(cn, "DSP", 3)) statDSP++;
        else if (!strncmp(cn, "MIGU", 4)) statMIGU++;
        else statOther++;

        for (int pass = 0; pass < 2; pass++) {
            Class target = pass == 0 ? object_getClass(c) : c;
            unsigned int cnt = 0;
            Method *ms = class_copyMethodList(target, &cnt);
            if (!ms) continue;
            for (unsigned int j = 0; j < cnt; j++) {
                const char *sn = sel_getName(method_getName(ms[j]));
                const char *types = method_getTypeEncoding(ms[j]);
                if (!sn || !types) continue;

                // 生命周期/加载类一律不动
                if (strstr(sn, "init") || strstr(sn, "start") ||
                    strstr(sn, "register") || strstr(sn, "setup") ||
                    strstr(sn, "load") || strstr(sn, "Load") ||
                    strstr(sn, "request") || strstr(sn, "Request") ||
                    strstr(sn, "fetch") || strstr(sn, "Fetch")) continue;

                BOOL isShow = (strstr(sn, "show") || strstr(sn, "Show") ||
                               strstr(sn, "render") || strstr(sn, "Render") ||
                               strstr(sn, "present") || strstr(sn, "Present"));
                if (!isShow) continue;

                if (types[0] == 'v') {
                    method_setImplementation(ms[j], NAVoidFor(NAArgc(sn)));
                    patched++;
                } else if (types[0] == '@') {
                    method_setImplementation(ms[j], NANilFor(NAArgc(sn)));
                    patched++;
                }
            }
            free(ms);
        }
    }
    free(all);

    NA_SCAN("\n===== 广告 SDK 扫描 =====\n");
    NA_SCAN("# 类总数: %u\n", total);
    NA_SCAN("  穿山甲/ABU:%d 优量汇:%d 快手:%d 百度:%d 京准通:%d DSP:%d 咪咕:%d 其他:%d\n",
            statABU, statGDT, statKS, statBaidu, statJAD, statDSP, statMIGU, statOther);
    NA_SCAN("# 已屏蔽方法: %d\n", patched);
    NA_LOG(@"广告 SDK 展示方法屏蔽 %d 个", patched);
}

// ===========================================================================
//  5) App 自有广告位
// ===========================================================================
static void (*NAOrigBannerDidMove)(id, SEL) = NULL;

static void NABannerDidMoveToWindow(id self, SEL _cmd) {
    if (NAOrigBannerDidMove) NAOrigBannerDidMove(self, _cmd);
    [(UIView *)self setHidden:YES];
    [(UIView *)self setAlpha:0];
}

static void NABannerShow(id self, SEL _cmd) {
    // 不调原实现：不展示、不上报，但对象本身保留
    [(UIView *)self setHidden:YES];
    [(UIView *)self setAlpha:0];
    NA_SCAN("[BANNER] suppressed %s\n", object_getClassName(self));
}

static BOOL NAIsClose(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }

static BOOL NAClassHasOwnMethod(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(ms[i]) == sel) { found = YES; break; }
    }
    free(ms);
    return found;
}

static void NAPatchContainers(void) {
    Class banner = objc_getClass("HYCNCAdBanner");
    if (banner) {
        Method show = class_getInstanceMethod(banner, sel_registerName("show"));
        if (show && method_getTypeEncoding(show)[0] == 'v') {
            method_setImplementation(show, (IMP)NABannerShow);
            NA_LOG(@"-[HYCNCAdBanner show] -> noop");
        }
        SEL dmw = sel_registerName("didMoveToWindow");
        if (!NAClassHasOwnMethod(banner, dmw)) {
            Class super = class_getSuperclass(banner);
            NAOrigBannerDidMove = super
                ? (void (*)(id, SEL))class_getMethodImplementation(super, dmw) : NULL;
            if (class_addMethod(banner, dmw, (IMP)NABannerDidMoveToWindow, "v16@0:8")) {
                NA_LOG(@"-[HYCNCAdBanner didMoveToWindow] 已挂");
            }
        }
    }

    Class hw = objc_getClass("HYHardwareBannerManager");
    if (hw) {
        Method m = class_getInstanceMethod(hw, sel_registerName("isClose"));
        if (m && method_getTypeEncoding(m)[0] == 'B') {
            method_setImplementation(m, (IMP)NAIsClose);
            NA_LOG(@"-[HYHardwareBannerManager isClose] -> YES");
        }
    }
}

// ===========================================================================
//  入口
// ===========================================================================
static BOOL NAInstalled = NO;

static void NAInstallAll(void) {
    if (!NAEnabled()) { NA_LOG(@"广告屏蔽已关闭, 跳过"); return; }
    NAInstallSplash();
    if (NAInstalled) return;
    NAInstalled = YES;

    // 扫描较重，延后到后台，避免启动看门狗
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            if (!NAEnabled()) return;
            NA_LOG(@"开始延后扫描");
            NAPatchSwitch();
            NAPatchShowFlags();
            NAPatchAdSDKClasses();
            NAPatchContainers();
            NA_LOG(@"════ 广告屏蔽完成 ════");
        }
    });
}

__attribute__((constructor))
static void HTNoAdsInit(void) {
    @autoreleasepool {
        NA_LOG(@"════ 广告屏蔽 v2 加载 ════");
        NAInstallAll();
        [[NSNotificationCenter defaultCenter] addObserverForName:@"HeJiaTool_NoAdsChanged"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            NAInstallAll();
        }];
    }
}

} // extern "C"
