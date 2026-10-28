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
static NSString *const kNAHomeAdKey  = @"HeJiaTool_NoHomeAd";
static NSString *const kNAToolKey    = @"HeJiaTool_NoTool";
static NSString *const kNACameraKey  = @"HeJiaTool_NoCamera";
static NSString *const kNAWalletKey  = @"HeJiaTool_NoWallet";
static NSString *const kNAFamilyKey  = @"HeJiaTool_NoFamily";
static NSString *const kNACameraLaunchKey = @"HeJiaTool_LaunchCamera";

static BOOL NABool(NSString *key, BOOL def) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    return [ud objectForKey:key] ? [ud boolForKey:key] : def;
}

static BOOL NAEnabled(void) { return NABool(kNAEnabledKey, YES); }

static BOOL NAModule(NSString *key) {
    if (!NAEnabled()) return NO;
    return NABool(key, YES);
}

static NSString *NAKeyForClass(NSString *cn) {
    if ([cn containsString:@"LaunchAd"]) return kNAEnabledKey;
    if ([cn containsString:@"GDRB"] || [cn containsString:@"Banner"] ||
        [cn containsString:@"CNCAd"] || [cn containsString:@"OperationADSnackBar"]) return kNAHomeAdKey;
    if ([cn containsString:@"Toolbar"] || [cn containsString:@"Tool"]) return kNAToolKey;
    if ([cn containsString:@"AFServices"]) return kNACameraKey;
    if ([cn containsString:@"Wallet"] || [cn containsString:@"FamilyLifeData"]) return kNAWalletKey;
    if ([cn containsString:@"GDFamilyNet"] || [cn containsString:@"FamilyAccountRights"]) return kNAFamilyKey;
    return kNAEnabledKey;
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
    // 开屏 window 一旦建出来立刻隐藏，避免先看到一帧广告/黑底
    id view = NAValue(self, @"launchAdView");
    if (!view) view = NAValue(self, @"launchAdForPadView");
    if ([view isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)view;
        if (v.window) v.window.hidden = YES;
        [v setHidden:YES];
        [v setAlpha:0];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)),
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

// 硬件页/首页 banner 类：只隐藏 banner 本身，不碰户型图控件
static void NACollapsePromoCard(UIView *v);

static void NAHideOnWindow(id self, SEL _cmd) {
    UIView *v = (UIView *)self;
    NSString *cn = NSStringFromClass([v class]);
    if (!NAModule(NAKeyForClass(cn))) return;
    if ([cn containsString:@"LaunchAdView"] && v.window) {
        v.window.hidden = YES;   // 开屏 window 是黑底，只藏 view 会闪黑
    }
    [v setHidden:YES];
    [v setAlpha:0];
    if ([cn containsString:@"GDFamilyNet"] || [cn containsString:@"FamilyLifeData"] ||
        [cn containsString:@"EssentialTool"] || [cn containsString:@"FamilyAccountRights"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NACollapsePromoCard(v); });
    }
}

typedef struct { Class cls; SEL sel; IMP orig; } NAHookRec;
static NAHookRec gHookRecs[128];
static int gHookRecCount = 0;

static IMP NAOrigIMP(Class c, SEL sel) {
    for (Class k = c; k; k = class_getSuperclass(k)) {
        for (int i = gHookRecCount - 1; i >= 0; i--) {
            if (gHookRecs[i].cls == k && gHookRecs[i].sel == sel) return gHookRecs[i].orig;
        }
    }
    return NULL;
}

static void NAHideInitFrame(id self, SEL _cmd, CGRect frame) {
    IMP o = NAOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, CGRect))o)(self, _cmd, frame);
    if (!NAModule(NAKeyForClass(NSStringFromClass([self class])))) return;
    [(UIView *)self setHidden:YES];
    [(UIView *)self setAlpha:0];
}

static void NAHideInitCoder(id self, SEL _cmd, id coder) {
    IMP o = NAOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, coder);
    if (!NAModule(NAKeyForClass(NSStringFromClass([self class])))) return;
    [(UIView *)self setHidden:YES];
    [(UIView *)self setAlpha:0];
}

static void NAHidePrepare(id self, SEL _cmd) {
    IMP o = NAOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
    if (!NAModule(NAKeyForClass(NSStringFromClass([self class])))) return;
    [(UIView *)self setHidden:YES];
    [(UIView *)self setAlpha:0];
}

static void NAInstallHideInit(Class c) {
    struct { const char *sel; IMP imp; const char *types; } specs[3] = {
        {"initWithFrame:", (IMP)NAHideInitFrame, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}"},
        {"initWithCoder:", (IMP)NAHideInitCoder, "v@:@"},
        {"prepareForReuse", (IMP)NAHidePrepare, "v@:"}
    };
    for (int i = 0; i < 3; i++) {
        if (gHookRecCount >= 120) return;
        SEL sel = sel_registerName(specs[i].sel);
        Method own = class_getInstanceMethod(c, sel);
        IMP inherited = own ? method_getImplementation(own) : NULL;
        if (class_addMethod(c, sel, specs[i].imp, specs[i].types)) {
            gHookRecs[gHookRecCount++] = (NAHookRec){c, sel, inherited};
        } else {
            Method m = class_getInstanceMethod(c, sel);
            if (m) {
                gHookRecs[gHookRecCount++] = (NAHookRec){c, sel, method_getImplementation(m)};
                method_setImplementation(m, specs[i].imp);
            }
        }
    }
}

static void NAAddHideClass(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { NA_LOG(@"找不到 %s", name); return; }
    NAInstallHideInit(c);
    SEL sel = sel_registerName("didMoveToWindow");
    if (NAClassHasOwnMethod(c, sel)) return;
    if (class_addMethod(c, sel, (IMP)NAHideOnWindow, "v16@0:8")) {
        NA_LOG(@"隐藏类 %s", name);
    }
}

// 分类推荐设备列表：直接把数据置空（数据层截断）
static void (*NAOrigClassify)(id, SEL, id) = NULL;
static void (*NAOrigClassifyTitle)(id, SEL, id, id) = NULL;

static void NAClassify(id self, SEL _cmd, id arr) {
    NA_SCAN("[CLASSIFY] drop %ld items\n",
            (long)([arr isKindOfClass:[NSArray class]] ? [arr count] : -1));
    if (NAOrigClassify) NAOrigClassify(self, _cmd, @[]);
}

static void NAClassifyTitle(id self, SEL _cmd, id arr, id title) {
    NA_SCAN("[CLASSIFY] drop %ld items (title=%@)\n",
            (long)([arr isKindOfClass:[NSArray class]] ? [arr count] : -1), title);
    if (NAOrigClassifyTitle) NAOrigClassifyTitle(self, _cmd, @[], title);
}

// 推广组件过滤：首页/我的页的组件数组在进 UI 前剔除推广块
static NSString *NAStr(id item, NSString *key) {
    id v = nil;
    @try {
        v = [item isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)item)[key]
                                                      : [item valueForKey:key];
    } @catch (__unused NSException *e) { return @""; }
    return [v isKindOfClass:[NSString class]] ? v : @"";
}

// 我的页里由低代码容器(JYMagicCube)渲染的钱包/亲情网卡片：
// 组件字典一旦下发，JY 引擎每秒重建视图，只在视图层隐藏会留白条/闪一下，
// 所以直接从组件数组里删掉，让宿主不创建容器。
static BOOL NAIsDroppedMyComponent(id item) {
    if (![item isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *d = item;
    NSMutableString *s = [NSMutableString string];
    for (id v in [d allValues]) {
        if ([v isKindOfClass:[NSString class]]) [s appendFormat:@" %@", v];
    }
    if (s.length == 0) return NO;
    BOOL wallet = NAModule(kNAWalletKey) &&
        ([s containsString:@"我的钱包"] || [s containsString:@"DK000301"]);
    BOOL family = NAModule(kNAFamilyKey) &&
        ([s containsString:@"家庭圈"] || [s containsString:@"爱家亲情网"] || [s containsString:@"DK000302"]);
    if (wallet || family) {
        NA_SCAN("[MY-COMP-DROP] wallet=%d family=%d %s\n", wallet, family,
                [[d description] UTF8String]);
        return YES;
    }
    return NO;
}

static BOOL NAIsPromoComponent(id item) {
    if (!item) return NO;
    NSMutableString *joined = [NSMutableString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
        NAStr(item, @"type"), NAStr(item, @"typeCategory"), NAStr(item, @"desc"),
        NAStr(item, @"id"), NAStr(item, @"name"), NAStr(item, @"title")];
    if ([item isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)item allValues]) {
            if ([v isKindOfClass:[NSString class]]) [joined appendFormat:@" %@", v];
        }
    } else if ([item isKindOfClass:[NSObject class]]) {
        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList([item class], &pc);
        for (unsigned int i = 0; i < pc; i++) {
            const char *pn = property_getName(props[i]);
            if (!pn) continue;
            @try {
                id v = [item valueForKey:[NSString stringWithUTF8String:pn]];
                if ([v isKindOfClass:[NSString class]]) [joined appendFormat:@" %@", v];
            } @catch (__unused NSException *e) {}
        }
        free(props);
    }
    NSString *s = joined.lowercaseString;
    static NSString *keys[] = {
        @"bigsale", @"banner", @"market", @"promotion", @"promoted",
        @"advert", @"operation", nil
    };
    for (int i = 0; keys[i]; i++) if ([s containsString:keys[i]]) return YES;
    return NO;
}

static NSArray *NAFilterComponents(id arr) {
    if (![arr isKindOfClass:[NSArray class]]) return arr;
    NSMutableArray *keep = [NSMutableArray arrayWithCapacity:[arr count]];
    for (id item in (NSArray *)arr) {
        if (!NAIsPromoComponent(item) && !NAIsDroppedMyComponent(item)) [keep addObject:item];
    }
    if (keep.count != [(NSArray *)arr count]) {
        NA_SCAN("[COMP-FILTER] %lu -> %lu\n",
                (unsigned long)[(NSArray *)arr count], (unsigned long)keep.count);
    }
    return keep;
}

static void (*NAOrigComp)(id, SEL, id, id, id) = NULL;
static void (*NAOrigMyInfo)(id, SEL, id, id, id, id) = NULL;

static BOOL NABlockOneArray(id block) {
    if (!block) return NO;
    struct NABlk { void *isa; int flags; int reserved; void *invoke;
        struct { unsigned long reserved; unsigned long size; const char *signature; } *descriptor; };
    struct NABlk *b = (struct NABlk *)(__bridge void *)block;
    const char *sig = (b && b->descriptor) ? b->descriptor->signature : NULL;
    if (!sig) return NO;
    int objs = 0;
    for (const char *p = sig; *p; p++) if (*p == '@' && p[1] != '?') objs++;
    return objs == 1;
}

static id NAWrapViewBlock(id block) {
    if (!NABlockOneArray(block)) return block;
    void (^orig)(NSArray *) = block;
    return [^(NSArray *views) {
        NSMutableArray *keep = [NSMutableArray array];
        for (id v in views) {
            NSString *cn = NSStringFromClass([v class]);
            BOOL drop = NO;
            if ([cn containsString:@"GDFamilyNet"] && NAModule(kNAFamilyKey)) drop = YES;
            if ([cn containsString:@"FamilyLifeData"] && NAModule(kNAWalletKey)) drop = YES;
            if ([cn containsString:@"EssentialTool"] && NAModule(kNAToolKey)) drop = YES;
            if ([cn containsString:@"FamilyAccountRights"] && NAModule(kNAFamilyKey)) drop = YES;
            if (!drop) [keep addObject:v];
        }
        orig(keep);
    } copy];
}

static void NAComp(id self, SEL _cmd, id arr, id tab, id block) {
    NSArray *out = NAFilterComponents(arr);
    if (NAOrigComp) NAOrigComp(self, _cmd, out, tab, NAWrapViewBlock(block));
}

static void NAMyInfo(id self, SEL _cmd, id arr, id tab, id real, id block) {
    NSArray *out = NAFilterComponents(arr);
    if (NAOrigMyInfo) NAOrigMyInfo(self, _cmd, out, tab, real, NAWrapViewBlock(block));
}

// 设备列表里的推广卡片：按模型类名剔除
// ---------------------------------------------------------------------------
// 摄像头 model 抓取 + 路由直达
//  路由: cmcc://digitalhome/Hardware/CNCDevice_Play?playType=0&hardwareType=..&iotDeviceId=..
// ---------------------------------------------------------------------------
static NSString *const kNACamDidKey = @"HeJiaTool_CameraDID";
static NSString *const kNACamHwKey  = @"HeJiaTool_CameraHWType";

static id NAVal(id obj, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v && v != [NSNull null]) return v;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static BOOL NALooksCamera(id item) {
    NSString *name = NAVal(item, @[@"desc", @"deviceName", @"name", @"nickName", @"deviceNickName"]);
    if ([name isKindOfClass:[NSString class]] &&
        ([name containsString:@"摄像头"] || [name.lowercaseString containsString:@"camera"])) return YES;
    NSString *cat = NAVal(item, @[@"subCategoryNameV2", @"subCategoryName", @"mainCategoryNameV2"]);
    if ([cat isKindOfClass:[NSString class]] && [cat containsString:@"摄像头"]) return YES;
    NSString *cn = NSStringFromClass([item class]).lowercaseString;
    if ([cn containsString:@"camera"]) return YES;
    id cam = NAVal(item, @[@"isCameraDevice", @"isCamera"]);
    if ([cam isKindOfClass:[NSNumber class]] && [cam boolValue]) return YES;
    return NO;
}

static void NACaptureCamera(id item) {
    if (!item || !NALooksCamera(item)) return;
    NSString *did = NAVal(item, @[@"id", @"macId", @"iotDeviceId", @"did", @"deviceId", @"devId", @"deviceMac"]);
    if (![did isKindOfClass:[NSString class]] || did.length == 0) return;
    id hw = NAVal(item, @[@"type", @"hardwareType", @"deviceType", @"deviceTypeId"]);
    long hwv = [hw respondsToSelector:@selector(longValue)] ? [hw longValue] : 0;
    // 路由里的 hardwareType 会被 App 当成 deviceTypeId 去取产品模型
    // (HYHardwareURLBridge -> getDeviceModelSilentByDeviceTypeId:)，
    // 所以用 model 的 type（2320794），不是配置键 10086。
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:did forKey:kNACamDidKey];
    [ud setInteger:hwv forKey:kNACamHwKey];
    NA_LOG(@"摄像头 model: did=%@ hw=%ld name=%@", did, hwv,
           NAVal(item, @[@"desc", @"deviceName", @"name", @"nickName"]) ?: @"?");
}

static UIWindow *NAKeyWindow(void);

static UIViewController *NATopVC(void) {
    UIWindow *kw = NAKeyWindow();
    UIViewController *vc = kw.rootViewController;
    int guard = 0;
    while (vc && guard++ < 8) {
        if ([vc isKindOfClass:[UITabBarController class]]) {
            vc = ((UITabBarController *)vc).selectedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            vc = ((UINavigationController *)vc).topViewController;
        } else if (vc.presentedViewController) {
            vc = vc.presentedViewController;
        } else break;
    }
    return vc;
}

static BOOL NATopIsLive(void) {
    NSString *cn = NSStringFromClass([NATopVC() class]);
    return [cn containsString:@"UniControl"];
}

// deviceClass: 0 = 不带该参数（走 hardwareType 取产品模型的分支）
//             1 = 平台设备类型 1，App 查表得 khDeviceType=1（IPC 摄像头），khSDKType=0x10000
static NSString *NACameraRouteURL(long deviceClass) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *did = [ud stringForKey:kNACamDidKey];
    long hw = (long)[ud integerForKey:kNACamHwKey];
    if (did.length == 0) return nil;
    NSString *enc = [did stringByAddingPercentEncodingWithAllowedCharacters:
                     [NSCharacterSet URLQueryAllowedCharacterSet]];
    return deviceClass > 0
        ? [NSString stringWithFormat:
           @"cmcc://digitalhome/Hardware/CNCDevice_Play?playType=0&hardwareType=%ld&iotDeviceId=%@&deviceClass=%ld&time=0",
           hw, enc ?: did, deviceClass]
        : [NSString stringWithFormat:
           @"cmcc://digitalhome/Hardware/CNCDevice_Play?playType=0&hardwareType=%ld&iotDeviceId=%@&time=0",
           hw, enc ?: did];
}

// 走 App 自己的摄像头路由入口：+[HYHardwareURLBridge openKHUrl:withTarget:withParams:]
// 它内部会 openKhUrl -> fetchKhDevice -> push HYCNCDeviceUniControlVC，不经过外层 URL 分发。
static BOOL NAOpenCameraRoute(long deviceClass) {
    NSString *str = NACameraRouteURL(deviceClass);
    if (!str) return NO;
    Class bridge = objc_getClass("HYHardwareURLBridge");
    SEL sel = sel_registerName("openKHUrl:withTarget:withParams:");
    if (!bridge || ![bridge respondsToSelector:sel]) return NO;
    id (*fn)(id, SEL, id, id, id) = (id (*)(id, SEL, id, id, id))[bridge methodForSelector:sel];
    if (!fn) return NO;
    id r = fn(bridge, sel, [NSURL URLWithString:str], nil, nil);
    NA_LOG(@"路由直播(bridge): %@ -> %@", str, r);
    return r != nil;
}

// 记录以“第一个摄像头”为准：NADeviceList 里调用
static BOOL NAIsPromoDevice(id item) {
    NSString *cn = NSStringFromClass([item class]).lowercaseString;
    static NSString *keys[] = { @"gdrb", @"advert", @"adcard", @"addevice",
                                @"promotion", @"promoted", @"banner", @"market", nil };
    for (int i = 0; keys[i]; i++) if ([cn containsString:keys[i]]) return YES;

    // HYHardwareListDeviceModel.bannerId 非空 = 设备列表里的广告位卡片
    @try {
        id bid = [item valueForKey:@"bannerId"];
        if ([bid isKindOfClass:[NSString class]] && [bid length] > 0) return YES;
        if ([bid isKindOfClass:[NSNumber class]] && [bid integerValue] != 0) return YES;
    } @catch (__unused NSException *e) {}

    for (NSString *k in @[@"isAd", @"isAdvertisement", @"adType", @"ylhInfo", @"ylhAdInfo"]) {
        @try {
            id v = [item valueForKey:k];
            if ([v isKindOfClass:[NSNumber class]] && [v boolValue]) return YES;
            if ([v isKindOfClass:[NSArray class]] && [v count] > 0) return YES;
            if ([v isKindOfClass:[NSString class]] && [v length] > 0) return YES;
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

static void (*NAOrigDeviceList)(id, SEL, id, long) = NULL;
static void NADeviceList(id self, SEL _cmd, id arr, long idx) {
    NSArray *out = arr;
    if ([arr isKindOfClass:[NSArray class]]) {
        NSMutableArray *keep = [NSMutableArray arrayWithCapacity:[arr count]];
        for (id item in (NSArray *)arr) {
            if (!NAIsPromoDevice(item)) {
                [keep addObject:item];
                NACaptureCamera(item);
            }
        }
        out = keep;
        if (keep.count != [(NSArray *)arr count]) {
            NA_SCAN("[DEV-FILTER] %lu -> %lu\n",
                    (unsigned long)[(NSArray *)arr count], (unsigned long)keep.count);
        }
    }
    if (NAOrigDeviceList) NAOrigDeviceList(self, _cmd, out, idx);
}

// 首页运营位/工具/服务推荐：直接截断数据源
static NSArray *NAEmptyArray(id self, SEL _cmd) { (void)self; (void)_cmd; return @[]; }

static void (*NAOrigSvcDataSource)(id, SEL, id) = NULL;

static void NASetEmptyArray(id self, SEL _cmd, id value) {
    (void)value;
    if (NAOrigSvcDataSource) NAOrigSvcDataSource(self, _cmd, @[]);
}

static id (*NAOrigSvcInit)(id, SEL, CGRect, id);

static id NASvcInit(id self, SEL _cmd, CGRect frame, id player) {
    if (NAOrigSvcInit) self = NAOrigSvcInit(self, _cmd, frame, player);
    [(UIView *)self setHidden:YES];
    [(UIView *)self setAlpha:0];
    return self;
}

static void NAInstallOperationCuts(void) {
    Class c = objc_getClass("HYHardwareOperationRecommendationManager");
    if (!c) { NA_LOG(@"找不到 HYHardwareOperationRecommendationManager"); return; }
    const char *sels[] = { "bannerItemsArray", "componentDictList", "oringedataDictList", NULL };
    for (int i = 0; sels[i]; i++) {
        Method m = class_getInstanceMethod(c, sel_registerName(sels[i]));
        if (!m) { NA_LOG(@"缺 %s", sels[i]); continue; }
        if (method_getTypeEncoding(m)[0] == '@') {
            method_setImplementation(m, (IMP)NAEmptyArray);
            NA_LOG(@"%@ -> []", [NSString stringWithUTF8String:sels[i]]);
        }
    }

    // 真正的源头：数据是通过 delegate 回调交给页面的，getter 置空拦不住。
    // 直接不发运营位/AD 请求，页面就没有可插的卡片。
    Method m = class_getInstanceMethod(c, sel_registerName("fetchOperationDataWithTabId:"));
    if (m) {
        method_setImplementation(m, (IMP)NAVoid1);
        NA_LOG(@"fetchOperationDataWithTabId: -> noop");
    }
    m = class_getInstanceMethod(c, sel_registerName("fetchAddDeviceADPlaceListWithTabId:"));
    if (m) {
        method_setImplementation(m, (IMP)NAVoid1);
        NA_LOG(@"fetchAddDeviceADPlaceListWithTabId: -> noop");
    }
}

// 文本级兜底：广告卡片带「广告」，服务推荐带「去订购/未开通」，工具区标题「工具」
static NSString *NAViewText(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return ((UILabel *)v).text;
    if ([v isKindOfClass:[UIButton class]]) return [(UIButton *)v titleForState:UIControlStateNormal];
    return nil;
}

static BOOL NAIsOurUI(UIView *v) {
    for (UIResponder *r = v.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            NSString *cn = NSStringFromClass([r class]);
            return [cn containsString:@"HTSettings"] || [cn containsString:@"HTLogPreview"];
        }
    }
    return NO;
}

static void NAHideAncestor(UIView *v, int up, NSArray<NSString *> *classHints) {
    UIView *cur = v;
    int steps = 0;
    UIView *fallback = nil;
    while (cur && steps < 8) {
        NSString *cn = NSStringFromClass([cur class]);
        for (NSString *h in classHints) {
            if ([cn containsString:h]) { cur.hidden = YES; return; }
        }
        if (!fallback && cur.superview && cur.superview != cur.window) fallback = cur;
        cur = cur.superview;
        steps++;
    }
    if (fallback) fallback.hidden = YES;
}

static void NAWalkViews(UIView *v, void (^cb)(UIView *)) {
    if (!v) return;
    cb(v);
    for (UIView *sub in v.subviews) NAWalkViews(sub, cb);
}

static BOOL NAHomeWindow(UIView *v) {
    for (UIResponder *r = v.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            NSString *cn = NSStringFromClass([r class]);
            if ([cn containsString:@"HardwareViewController"] || [cn containsString:@"HardwareDeviceViewController"]) return YES;
        }
    }
    return NO;
}

static BOOL NAIsHideClassName(NSString *cn) {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"GDRBBannerCollectionViewCell", @"GDRBBannerTableViewCell",
                  @"CommonHardwareSenceHalfViewBannerCell", @"HYBannerCollectionViewCell",
                  @"HYOperationADSnackBar", @"HardwareToolbarDeviceListView",
                  @"GDFamilyNet", @"FamilyLifeData", @"EssentialTool",
                  @"FamilyAccountRights", @"AFServicesCardView", @"AFServicesTimeTrackCell",
                  @"AFServicesSmartGuardCell", @"HardwareToolbarListCell"];
    });
    for (NSString *n in names) if ([cn containsString:n]) return YES;
    return NO;
}

static void NACollapsePromoCard(UIView *v) {
    if (!v) return;
    NSString *cn = NSStringFromClass([v class]);
    if (![cn containsString:@"GDFamilyNet"] && ![cn containsString:@"FamilyLifeData"]) return;
    UIView *cur = v.superview;
    CGFloat w = v.window ? v.window.bounds.size.width : 402.0;
    int steps = 0;
    while (cur && cur != cur.window && steps < 8) {
        if (cur.bounds.size.width >= w * 0.8 && cur.bounds.size.height >= 80) {
            cur.hidden = YES;
            [cur removeFromSuperview];
            return;
        }
        cur = cur.superview;
        steps++;
    }
}

static BOOL NAVCIsMyPage(UIView *v) {
    for (UIResponder *r = v.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            NSString *cn = NSStringFromClass([r class]);
            if ([cn containsString:@"MyInfo"]) return YES;
        }
    }
    return NO;
}

static BOOL NAHasVisibleText(UIView *v) {
    if (!v || v.hidden || v.alpha < 0.1) return NO;
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) t = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) t = [(UIButton *)v titleForState:UIControlStateNormal];
    if ([t isKindOfClass:[NSString class]] && t.length > 0) return YES;
    for (UIView *sub in v.subviews) if (NAHasVisibleText(sub)) return YES;
    return NO;
}

static void NAHideEmptyMyCards(UIView *root) {
    if (!root || !NAVCIsMyPage(root)) return;
    CGFloat sw = root.window ? root.window.bounds.size.width : 402.0;
    for (UIView *v in [root.subviews copy]) {
        if (v.hidden || v.alpha < 0.1) continue;
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        if (w >= sw * 0.8 && h >= 100 && h <= 420 && v.layer.cornerRadius >= 6) {
            UIColor *bg = v.backgroundColor;
            if (bg && CGColorGetAlpha(bg.CGColor) > 0.3 && !NAHasVisibleText(v)) {
                NSString *cn = NSStringFromClass([v class]);
                if ([cn containsString:@"Cell"]) {
                    v.hidden = YES;
                } else {
                    [v removeFromSuperview];
                }
                NA_SCAN("[EMPTY-CARD] removed %s\n", [cn UTF8String]);
                continue;
            }
        }
        NAHideEmptyMyCards(v);
    }
}

static void NASweepAds(void) {
    if (!NAEnabled()) return;
    NSArray *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *w in wins) {
        if (!w || w.hidden) continue;
        NAHideEmptyMyCards(w);
        NAWalkViews(w, ^(UIView *v) {
            if (NAIsOurUI(v)) return;
            NSString *cn = NSStringFromClass([v class]);
            if (NAIsHideClassName(cn)) {
                v.hidden = YES;
                v.alpha = 0;
                NACollapsePromoCard(v);
                return;
            }

            NSString *t = NAViewText(v);
            if (![t isKindOfClass:[NSString class]] || t.length == 0) return;
            if ([t isEqualToString:@"广告"] && NAModule(kNAHomeAdKey)) {
                NAHideAncestor(v, 0, @[@"Cell", @"Banner", @"Card"]);
            } else if (([t isEqualToString:@"去订购"] || [t isEqualToString:@"未开通"]) && NAModule(kNACameraKey)) {
                NAHideAncestor(v, 0, @[@"CollectionView", @"Collection", @"ScrollView", @"Cell"]);
            } else if ([t isEqualToString:@"工具"] && NAHomeWindow(v) && NAModule(kNAToolKey)) {
                NAHideAncestor(v, 1, @[@"Header", @"Section"]);
            } else if (([t isEqualToString:@"我的钱包"] && NAModule(kNAWalletKey)) ||
                       ([t isEqualToString:@"爱家亲情网"] && NAModule(kNAFamilyKey))) {
                CGFloat winW = v.window ? v.window.bounds.size.width : 402.0;
                UIView *cur = v;
                UIView *target = nil;
                while (cur && cur != cur.window) {
                    if (cur.bounds.size.width >= winW * 0.8 && cur.bounds.size.height >= 80) {
                        target = cur;
                        break;
                    }
                    cur = cur.superview;
                }
                if (target) {
                    target.hidden = YES;
                    UIView *parent = target.superview;
                    if (parent && fabs(parent.bounds.size.width - target.bounds.size.width) < 2 &&
                        fabs(parent.bounds.size.height - target.bounds.size.height) < 2) {
                        parent.hidden = YES;
                    }
                    NA_SCAN("[MY-CARD] hidden %s\n", [NSStringFromClass([target class]) UTF8String]);
                }
            }
        });
    }
}

static NSTimer *gSweepTimer;

static void NAStartSweep(void) {
    if (gSweepTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NASweepAds();
        gSweepTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      repeats:YES
                                                        block:^(__unused NSTimer *t) {
            NASweepAds();
        }];
    });
}

static void (*NAOrigHWAppear)(id, SEL, BOOL) = NULL;
static BOOL NALaunchedCamera = NO;

static BOOL NAViewHasCameraText(UIView *v, int depth) {
    if (!v || depth > 8) return NO;
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) t = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) t = [(UIButton *)v titleForState:UIControlStateNormal];
    if ([t isKindOfClass:[NSString class]] &&
        ([t containsString:@"摄像头"] || [t.lowercaseString containsString:@"camera"])) return YES;
    for (UIView *sub in v.subviews) if (NAViewHasCameraText(sub, depth + 1)) return YES;
    return NO;
}

static BOOL NASelectCameraCell(UIView *root) {
    if (!root) return NO;
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)v;
            for (UICollectionViewCell *cell in cv.visibleCells) {
                if (NAViewHasCameraText(cell, 0)) {
                    NSIndexPath *ip = [cv indexPathForCell:cell];
                    id d = cv.delegate;
                    if (ip && [d respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                        [d collectionView:cv didSelectItemAtIndexPath:ip];
                        NA_LOG(@"已选中摄像头 cell: %@", ip);
                        return YES;
                    }
                }
            }
        }
        if ([v isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)v;
            for (UITableViewCell *cell in tv.visibleCells) {
                if (NAViewHasCameraText(cell, 0)) {
                    NSIndexPath *ip = [tv indexPathForCell:cell];
                    id d = tv.delegate;
                    if (ip && [d respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        [d tableView:tv didSelectRowAtIndexPath:ip];
                        NA_LOG(@"已选中摄像头 cell: %@", ip);
                        return YES;
                    }
                }
            }
        }
        if (NASelectCameraCell(v)) return YES;
    }
    return NO;
}

static UIView *gLaunchCover = nil;

static UIWindow *NAKeyWindow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) return w;
    return [UIApplication sharedApplication].keyWindow;
}

static void NAShowLaunchCover(void) {
    UIWindow *kw = NAKeyWindow();
    if (!kw) return;
    if (!gLaunchCover) {
        gLaunchCover = [[UIView alloc] initWithFrame:kw.bounds];
        gLaunchCover.backgroundColor = [UIColor systemBackgroundColor];
        gLaunchCover.tag = 0x1A2B;
        gLaunchCover.userInteractionEnabled = NO;
    }
    [kw addSubview:gLaunchCover];
    [kw bringSubviewToFront:gLaunchCover];
    NA_LOG(@"遮罩展示");
    // 兜底：任何情况下 3 秒后必撤，避免卡在遮罩上
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gLaunchCover) { NA_LOG(@"遮罩超时强撤"); NAHideLaunchCover(); }
    });
}

static void NAHideLaunchCover(void) {
    if (gLaunchCover) {
        [gLaunchCover removeFromSuperview];
        gLaunchCover = nil;
    }
    // 防御：窗口可能换过，按 tag 清掉所有窗口上的残留
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIView *v = [w viewWithTag:0x1A2B];
        if (v) [v removeFromSuperview];
    }
    NA_LOG(@"遮罩已撤");
}

static void NATrySelectCamera(int attempt) {
    if (attempt > 20) { NA_LOG(@"摄像头 cell 重试结束"); NAHideLaunchCover(); return; }
    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) { kw = w; break; }
    UIViewController *top = kw.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (NASelectCameraCell(top.view)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NAHideLaunchCover(); });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ NATrySelectCamera(attempt + 1); });
}

static void (*NAOrigLiveAppear)(id, SEL, BOOL) = NULL;

static void NALiveAppear(id self, SEL _cmd, BOOL animated) {
    if (NAOrigLiveAppear) NAOrigLiveAppear(self, _cmd, animated);
    if (gLaunchCover) {
        NA_LOG(@"直播页已出现, 撤遮罩");
        NAHideLaunchCover();
    }
}

static void NAHWAppear(id self, SEL _cmd, BOOL animated) {
    if (NAOrigHWAppear) NAOrigHWAppear(self, _cmd, animated);
    if (NALaunchedCamera) return;
    if (!NAModule(kNACameraLaunchKey)) return;
    NALaunchedCamera = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NA_LOG(@"启动后走路由进直播（遮罩中间页）");
        NAShowLaunchCover();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 真路由：+[HYHardwareURLBridge openKHUrl:...]，deviceClass=1 -> khDeviceType=1 (IPC)
            NAOpenCameraRoute(1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (NATopIsLive()) {
                    NA_LOG(@"路由已进入直播页");
                    NAHideLaunchCover();
                } else {
                    NA_LOG(@"路由没到直播页, 回退 cell 选中");
                    NATrySelectCamera(0);
                }
            });
        });
    });
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

    NAAddHideClass("HYLaunchAdView");
    NAAddHideClass("HYLaunchAdForPadView");
    NAAddHideClass("HYAFServicesCardView");
    NAAddHideClass("HYAFServicesTimeTrackCell");
    NAAddHideClass("HYAFServicesSmartGuardCell");
    NAAddHideClass("HYAFServicesCommonCell");
    NAAddHideClass("HYAFServicesCloudCell");
    NAAddHideClass("HYAFServicesInspectionCell");
    NAAddHideClass("HYAFServicesKindCell");
    NAAddHideClass("HYAFServicesMoreCell");
    NAAddHideClass("HYAFServicesSmartTalkCell");
    NAAddHideClass("HYHardwareToolbarListCell");
    NAAddHideClass("HYHardwareNoDeviceToolbarListCell");
    NAAddHideClass("HYMyInfoGDFamilyNetComponent");
    NAAddHideClass("HYMyInfoFamilyLifeDataCardsView");
    NAAddHideClass("HYMyInfoEssentialToolComponent");
    NAAddHideClass("HYMyInfoFamilyAccountRightsComponent");
    NAAddHideClass("HYGDRBBannerCollectionViewCell");
    NAAddHideClass("HYNewGDRBBannerCollectionViewCell");
    NAAddHideClass("HYOldNewGDRBBannerCollectionViewCell");
    NAAddHideClass("HYYunnanGDRBBannerCollectionViewCell");
    NAAddHideClass("HYGDRBBannerTableViewCell");
    NAAddHideClass("HYNewGDRBBannerTableViewCell");
    NAAddHideClass("HYCommonHardwareSenceHalfViewBannerCell");
    NAAddHideClass("HYBannerCollectionViewCell");
    NAAddHideClass("HYOperationADSnackBar");

    Class comp = objc_getClass("HYComponentManager");
    if (comp) {
        Method m = class_getInstanceMethod(comp, sel_registerName("getViewWithComponentDictArray:tabId:completeBlock:"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            NAOrigComp = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)NAComp);
            NA_LOG(@"[HYComponentManager] 推广组件过滤已挂");
        }
    }
    Class myinfo = objc_getClass("HYMyInfoComponentManager");
    if (myinfo) {
        Method m = class_getInstanceMethod(myinfo, sel_registerName("getViewWithComponentDictArray:tabId:realTabId:completeBlock:"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            NAOrigMyInfo = (void (*)(id, SEL, id, id, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)NAMyInfo);
            NA_LOG(@"[HYMyInfoComponentManager] 推广组件过滤已挂");
        }
    }
    Class devList = objc_getClass("HYHardwareFamilyDeviceListView");
    if (devList) {
        Method m = class_getInstanceMethod(devList, sel_registerName("configWithAllDeviceArray:currentRoomIndex:"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            NAOrigDeviceList = (void (*)(id, SEL, id, long))method_getImplementation(m);
            method_setImplementation(m, (IMP)NADeviceList);
            NA_LOG(@"[HYHardwareFamilyDeviceListView] 推广设备过滤已挂");
        }
    }

    Class svcCard = objc_getClass("HYAFServicesCardView");
    if (svcCard) {
        Method m = class_getInstanceMethod(svcCard, sel_registerName("queryCardsInfo:"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            method_setImplementation(m, (IMP)NAVoid1);
            NA_LOG(@"[HYAFServicesCardView queryCardsInfo:] -> noop");
        }
        m = class_getInstanceMethod(svcCard, sel_registerName("refreshView"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            method_setImplementation(m, (IMP)NA_Void0);
            NA_LOG(@"[HYAFServicesCardView refreshView] -> noop");
        }
        m = class_getInstanceMethod(svcCard, sel_registerName("setDataSource:"));
        if (m) {
            NAOrigSvcDataSource = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)NASetEmptyArray);
            NA_LOG(@"[HYAFServicesCardView setDataSource:] -> []");
        }
        m = class_getInstanceMethod(svcCard, sel_registerName("initWithFrame:commonPlayer:"));
        if (m) {
            NAOrigSvcInit = (id (*)(id, SEL, CGRect, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)NASvcInit);
            NA_LOG(@"[HYAFServicesCardView initWithFrame:commonPlayer:] hidden");
        }
    }

    Class hwVC = objc_getClass("HYHardwareViewController");
    if (hwVC) {
        Method m = class_getInstanceMethod(hwVC, sel_registerName("viewDidAppear:"));
        if (m) {
            NAOrigHWAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
            method_setImplementation(m, (IMP)NAHWAppear);
            NA_LOG(@"启动后进摄像头页 hook 已挂");
        }
    }

    // 直播页真正出现就撤遮罩，不依赖定时器判断
    Class liveVC = objc_getClass("HYCNCDeviceUniControlVC");
    if (liveVC) {
        Method m = class_getInstanceMethod(liveVC, sel_registerName("viewDidAppear:"));
        if (m) {
            NAOrigLiveAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
            method_setImplementation(m, (IMP)NALiveAppear);
            NA_LOG(@"直播页出现撤遮罩 hook 已挂");
        }
    }

    Class devVC = objc_getClass("HYHardwareDeviceViewController");
    if (devVC) {
        Method m = class_getInstanceMethod(devVC, sel_registerName("dealWithYunyingADData"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            method_setImplementation(m, (IMP)NA_Void0);
            NA_LOG(@"-[HYHardwareDeviceViewController dealWithYunyingADData] -> noop");
        }
        m = class_getInstanceMethod(devVC, sel_registerName("showADOperationSnackBarWithArray:"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            method_setImplementation(m, (IMP)NA_Void1);
            NA_LOG(@"-[HYHardwareDeviceViewController showADOperationSnackBarWithArray:] -> noop");
        }
    }

    Class classify = objc_getClass("HYHardwareClassifyBannerDeviceListView");
    if (classify) {
        Method m = class_getInstanceMethod(classify, sel_registerName("configWithAllDeviceArray:"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            NAOrigClassify = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)NAClassify);
            NA_LOG(@"-[HYHardwareClassifyBannerDeviceListView configWithAllDeviceArray:] -> empty");
        }
        m = class_getInstanceMethod(classify, sel_registerName("configWithAllDeviceArray:title:"));
        if (m && method_getTypeEncoding(m)[0] == 'v') {
            NAOrigClassifyTitle = (void (*)(id, SEL, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)NAClassifyTitle);
            NA_LOG(@"-[HYHardwareClassifyBannerDeviceListView configWithAllDeviceArray:title:] -> empty");
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

    // 轻量 hook 立刻装：首页的广告 cell 在 2.5 秒前就可能已经创建，
    // 晚装 didMoveToWindow 不会补触发（这是上一版广告没消失的根因）。
    NAPatchSwitch();
    NAPatchContainers();
    NAInstallOperationCuts();
    NAStartSweep();

    // 只有全类扫描延后，避免启动看门狗
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            if (!NAEnabled()) return;
            NA_LOG(@"开始延后扫描");
            NAPatchShowFlags();
            NAPatchAdSDKClasses();
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
