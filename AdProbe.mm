// ============================================================================
//  AdProbe.mm — 广告现场抓取（只记录，不拦截）
// ----------------------------------------------------------------------------
//  一个可拖动的悬浮按钮。在出现广告的页面点一下，就把：
//    - 当前 VC 链、App 版本、开关状态
//    - 所有 window 的完整视图树（类名/坐标/隐藏/alpha/所属 VC/文本摘要）
//    - 广告类名汇总（方便直接看是哪个类）
//    - 最近 300 条候选方法调用（组件/广告服务/页面出现）
//  写进 Documents/HeJiaTool/adprobe-<时间>.log。
//
//  ⚠️ 本模块只读：所有 hook 都调用原实现，不改变任何返回值。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>

extern "C" void HTLog(const char *tag, NSString *msg);
extern "C" const char *HTGetLogDir(void);

#define AP_LOG(...) HTLog("HeJiaProbe", [NSString stringWithFormat:__VA_ARGS__])

extern "C" {

// ---------------------------------------------------------------------------
// 事件环形缓冲
// ---------------------------------------------------------------------------
static NSMutableArray<NSString *> *gEvents;
static NSDateFormatter *gTimeFmt;

static NSString *APNow(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gTimeFmt = [[NSDateFormatter alloc] init];
        gTimeFmt.dateFormat = @"HH:mm:ss.SSS";
    });
    return [gTimeFmt stringFromDate:[NSDate date]];
}

static void APEvent(NSString *line) {
    @synchronized (gEvents ?: (id)[NSNull null]) {
        if (!gEvents) gEvents = [NSMutableArray array];
        [gEvents addObject:[NSString stringWithFormat:@"%@ %@", APNow(), line]];
        if (gEvents.count > 300) [gEvents removeObjectAtIndex:0];
    }
}

static BOOL APLooksLikeAd(NSString *cls) {
    if (!cls) return NO;
    NSString *s = cls.lowercaseString;
    static NSString *keys[] = {
        @"advert", @"banner", @"splash", @"promotion", @"promoted",
        @"bigsale", @"operation", @"recommend", @"market", @"ads",
        @"adview", @"adcell", @"adcard", @"aditem", @"adslot", nil
    };
    for (int i = 0; keys[i]; i++) {
        if ([s containsString:keys[i]]) return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// 视图树
// ---------------------------------------------------------------------------
static UIViewController *APViewControllerOf(UIView *v) {
    UIResponder *r = v.nextResponder;
    int guard = 0;
    while (r && guard++ < 32) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

static NSString *APTextOf(UIView *v) {
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) t = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) t = [(UIButton *)v titleForState:UIControlStateNormal];
    else if ([v isKindOfClass:[UITextField class]]) t = ((UITextField *)v).text;
    else if ([v isKindOfClass:[UITextView class]]) t = ((UITextView *)v).text;
    if (![t isKindOfClass:[NSString class]] || t.length == 0) return @"";
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (t.length > 40) t = [[t substringToIndex:40] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@" text=\"%@\"", t];
}

static void APDumpView(UIView *v, int depth, NSMutableString *out, int *budget) {
    if (!v || depth > 10 || *budget <= 0) return;
    (*budget)--;
    CGRect f = v.frame;
    NSString *cls = NSStringFromClass([v class]);
    UIViewController *vc = APViewControllerOf(v);
    [out appendFormat:@"%*s%@ f=(%.0f,%.0f,%.0f,%.0f)%@%@%@%@\n",
        depth * 2, "", cls,
        f.origin.x, f.origin.y, f.size.width, f.size.height,
        v.hidden ? @" hidden" : @"",
        v.alpha < 0.99 ? [NSString stringWithFormat:@" alpha=%.2f", v.alpha] : @"",
        vc ? [NSString stringWithFormat:@" vc=%@", NSStringFromClass([vc class])] : @"",
        APTextOf(v)];
    if (APLooksLikeAd(cls)) {
        [out appendFormat:@"%*s  ^^^ AD-LIKE super=%@ addr=%p\n",
            depth * 2, "",
            v.superview ? NSStringFromClass([v.superview class]) : @"nil", v];
    }
    for (UIView *sub in v.subviews) APDumpView(sub, depth + 1, out, budget);
}

static NSString *APVCLine(UIViewController *vc, int depth) {
    if (!vc || depth > 8) return @"";
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%*s%@\n", depth * 2, "", NSStringFromClass([vc class])];
    if ([vc isKindOfClass:[UINavigationController class]]) {
        [s appendString:APVCLine(((UINavigationController *)vc).topViewController, depth + 1)];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        [s appendString:APVCLine(((UITabBarController *)vc).selectedViewController, depth + 1)];
    } else if (vc.presentedViewController) {
        [s appendString:APVCLine(vc.presentedViewController, depth + 1)];
    }
    for (UIViewController *c in vc.childViewControllers) {
        [s appendString:APVCLine(c, depth + 1)];
    }
    return s;
}

// ---------------------------------------------------------------------------
// 抓取
// ---------------------------------------------------------------------------
static void APCapture(void) {
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        NSMutableString *out = [NSMutableString string];

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *stamp = [df stringFromDate:[NSDate date]];

        [out appendFormat:@"===== HeJia AdProbe =====\n"];
        [out appendFormat:@"time: %@\n", stamp];
        [out appendFormat:@"app: %@ (%@)\n",
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]];
        [out appendFormat:@"noAds: %@\n",
            [[NSUserDefaults standardUserDefaults] objectForKey:@"HeJiaTool_NoAds"] ?:
            @"(unset=ON)"];

        [out appendString:@"\n----- VC chain -----\n"];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.tag == 0xAD8) continue;
                [out appendFormat:@"window %@ level=%.0f hidden=%d key=%d\n",
                    NSStringFromClass([w class]), w.windowLevel, w.isHidden, w.isKeyWindow];
                [out appendString:APVCLine(w.rootViewController, 1)];
            }
        }
        if (app.connectedScenes.count == 0) {
            for (UIWindow *w in app.windows) {
                if (w.tag == 0xAD8) continue;
                [out appendFormat:@"window %@ level=%.0f hidden=%d key=%d\n",
                    NSStringFromClass([w class]), w.windowLevel, w.isHidden, w.isKeyWindow];
                [out appendString:APVCLine(w.rootViewController, 1)];
            }
        }

        [out appendString:@"\n----- view tree -----\n"];
        int budget = 4000;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.tag == 0xAD8 || w.isHidden) continue;
                [out appendFormat:@"\n# window %@ level=%.0f\n",
                    NSStringFromClass([w class]), w.windowLevel];
                APDumpView(w, 0, out, &budget);
            }
        }
        if (app.connectedScenes.count == 0) {
            for (UIWindow *w in app.windows) {
                if (w.tag == 0xAD8 || w.isHidden) continue;
                [out appendFormat:@"\n# window %@ level=%.0f\n",
                    NSStringFromClass([w class]), w.windowLevel];
                APDumpView(w, 0, out, &budget);
            }
        }

        [out appendString:@"\n----- events (last 300) -----\n"];
        @synchronized (gEvents ?: (id)[NSNull null]) {
            for (NSString *e in gEvents ?: @[]) [out appendFormat:@"%@\n", e];
        }

        [out appendString:@"\n----- ad-like class summary -----\n"];
        NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.tag == 0xAD8) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                while (stack.count) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    NSString *cls = NSStringFromClass([v class]);
                    if (APLooksLikeAd(cls)) {
                        counts[cls] = @([counts[cls] integerValue] + 1);
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        for (NSString *cls in [counts keysSortedByValueUsingSelector:@selector(compare:)]) {
            [out appendFormat:@"%@ x%@\n", cls, counts[cls]];
        }

        [out appendString:@"===== end =====\n"];

        NSString *dir = HTGetLogDir() ? [NSString stringWithUTF8String:HTGetLogDir()] : nil;
        if (!dir.length) {
            dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"HeJiaTool"];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *name = [NSString stringWithFormat:@"adprobe-%@.log",
                          [[stamp stringByReplacingOccurrencesOfString:@":" withString:@""]
                           stringByReplacingOccurrencesOfString:@" " withString:@"_"]];
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSError *err = nil;
        BOOL ok = [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        AP_LOG(@"抓取%@: %@", ok ? @"成功" : @"失败", path);

        NSString *msg = ok ? path : (err.localizedDescription ?: @"写入失败");
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *top = nil;
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.tag == 0xAD8) continue;
                    if (w.isKeyWindow) top = w.rootViewController;
                }
            }
            while (top.presentedViewController) top = top.presentedViewController;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已记录广告现场"
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
                [UIPasteboard generalPasteboard].string = msg;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:a animated:YES completion:nil];
        });
    }
}

// ---------------------------------------------------------------------------
// 悬浮按钮
// ---------------------------------------------------------------------------
@interface APButton : UIView
@end

@implementation APButton {
    CGPoint _start;
    BOOL _moved;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.85 green:0.1 blue:0.1 alpha:0.65];
        self.layer.cornerRadius = 22;
        self.layer.masksToBounds = YES;
        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"记";
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont boldSystemFontOfSize:16];
        l.textAlignment = NSTextAlignmentCenter;
        l.userInteractionEnabled = NO;
        [self addSubview:l];
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _start = [[touches anyObject] locationInWindow];
    _moved = NO;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [[touches anyObject] locationInWindow];
    CGFloat dx = p.x - _start.x, dy = p.y - _start.y;
    if (fabs(dx) > 4 || fabs(dy) > 4) _moved = YES;
    CGPoint c = CGPointMake(self.center.x + dx, self.center.y + dy);
    CGRect b = self.window.bounds;
    c.x = MAX(24, MIN(b.size.width - 24, c.x));
    c.y = MAX(80, MIN(b.size.height - 34, c.y));
    self.center = c;
    _start = p;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_moved) APCapture();
}
@end

static UIWindow *gProbeWin;

static void APInstallButton(void) {
    if (gProbeWin) return;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.tag = 0xAD8;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.userInteractionEnabled = NO;
    w.rootViewController = root;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                w.windowScene = (UIWindowScene *)s;
                break;
            }
        }
        if (!w.windowScene) {
            for (UIWindow *kw in [UIApplication sharedApplication].windows) {
                if (kw.windowScene) { w.windowScene = kw.windowScene; break; }
            }
        }
    }
    APButton *b = [[APButton alloc] initWithFrame:CGRectMake(12, 220, 44, 44)];
    [w addSubview:b];
    w.hidden = NO;
    gProbeWin = w;
    AP_LOG(@"悬浮按钮已就绪");
}

// ---------------------------------------------------------------------------
// 只读 trace：组件 / 广告服务 / 页面出现
// ---------------------------------------------------------------------------
static void (*ap_orig_viewDidAppear)(id, SEL, BOOL);
static void ap_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    @autoreleasepool { APEvent([NSString stringWithFormat:@"[VC] %@", NSStringFromClass([self class])]); }
    if (ap_orig_viewDidAppear) ap_orig_viewDidAppear(self, _cmd, animated);
}

static void (*ap_orig_comp)(id, SEL, id, id, id);
static void ap_comp(id self, SEL _cmd, id arr, id tab, id block) {
    APEvent([NSString stringWithFormat:@"[COMP] %@ tab=%@ n=%ld",
             NSStringFromClass([self class]), tab,
             (long)([arr isKindOfClass:[NSArray class]] ? [arr count] : -1)]);
    if (ap_orig_comp) ap_orig_comp(self, _cmd, arr, tab, block);
}

static void (*ap_orig_myinfo)(id, SEL, id, id, id, id);
static void ap_myinfo(id self, SEL _cmd, id arr, id tab, id real, id block) {
    APEvent([NSString stringWithFormat:@"[MYINFO] tab=%@ real=%@ n=%ld", tab, real,
             (long)([arr isKindOfClass:[NSArray class]] ? [arr count] : -1)]);
    if (ap_orig_myinfo) ap_orig_myinfo(self, _cmd, arr, tab, real, block);
}

static void (*ap_orig_fetchAdvert)(id, SEL, id, id);
static void ap_fetchAdvert(id self, SEL _cmd, id req, id block) {
    APEvent(@"[AdSvc] fetchAdvertNewReq");
    if (ap_orig_fetchAdvert) ap_orig_fetchAdvert(self, _cmd, req, block);
}

static void (*ap_orig_memberPopup)(id, SEL);
static void ap_memberPopup(id self, SEL _cmd) {
    APEvent(@"[Popup] showMemberFreeFlowPopup");
    if (ap_orig_memberPopup) ap_orig_memberPopup(self, _cmd);
}

static void (*ap_orig_adPopupView)(id, SEL);
static void ap_adPopupView(id self, SEL _cmd) {
    APEvent(@"[Popup] showMcsAdPopupView");
    if (ap_orig_adPopupView) ap_orig_adPopupView(self, _cmd);
}

static void (*ap_orig_mcsCheck)(id, SEL);
static void ap_mcsCheck(id self, SEL _cmd) {
    APEvent(@"[Popup] mcsCheckAdPopup");
    if (ap_orig_mcsCheck) ap_orig_mcsCheck(self, _cmd);
}

static void (*ap_orig_hwList)(id, SEL, id, long);
static void ap_hwList(id self, SEL _cmd, id arr, long idx) {
    APEvent([NSString stringWithFormat:@"[HWList] %@ n=%ld idx=%ld",
             NSStringFromClass([self class]),
             (long)([arr isKindOfClass:[NSArray class]] ? [arr count] : -1), idx]);
    if (ap_orig_hwList) ap_orig_hwList(self, _cmd, arr, idx);
}

static void (*ap_orig_bannerList)(id, SEL, id);
static void ap_bannerList(id self, SEL _cmd, id tab) {
    APEvent([NSString stringWithFormat:@"[BannerList] tab=%@", tab]);
    if (ap_orig_bannerList) ap_orig_bannerList(self, _cmd, tab);
}

#define AP_HOOK(cls, sel, wrapper, origp, types) do { \
    Class c_ = objc_getClass(cls); \
    if (c_) { \
        Method m_ = class_getInstanceMethod(c_, sel_registerName(sel)); \
        if (m_ && method_getTypeEncoding(m_)) { \
            origp = (void *)method_getImplementation(m_); \
            method_setImplementation(m_, (IMP)(wrapper)); \
        } \
    } \
} while (0)

__attribute__((constructor))
static void HTAdProbeInit(void) {
    @autoreleasepool {
        AP_LOG(@"════ AdProbe 加载 ════");
        AP_HOOK("UIViewController", "viewDidAppear:", ap_viewDidAppear, ap_orig_viewDidAppear, "v24@0:8B16");
        AP_HOOK("HYComponentManager", "getViewWithComponentDictArray:tabId:completeBlock:",
                ap_comp, ap_orig_comp, "v40@0:8@16@24@?32");
        AP_HOOK("HYMyInfoComponentManager", "getViewWithComponentDictArray:tabId:realTabId:completeBlock:",
                ap_myinfo, ap_orig_myinfo, "v48@0:8@16@24@32@?40");
        AP_HOOK("McsAdvertsModuleService", "fetchAdvertNewReq:block:",
                ap_fetchAdvert, ap_orig_fetchAdvert, "v32@0:8@16@?24");
        AP_HOOK("McsMemberAdManager", "showMemberFreeFlowPopup",
                ap_memberPopup, ap_orig_memberPopup, "v16@0:8");
        AP_HOOK("McsMemBerAdPopupView", "showMcsAdPopupView",
                ap_adPopupView, ap_orig_adPopupView, "v16@0:8");
        AP_HOOK("McsFamilyMainViewController", "mcsCheckAdPopup",
                ap_mcsCheck, ap_orig_mcsCheck, "v16@0:8");
        AP_HOOK("HYHardwareFamilyDeviceListView", "configWithAllDeviceArray:currentRoomIndex:",
                ap_hwList, ap_orig_hwList, "v32@0:8@16q24");
        AP_HOOK("HYGetUserBannerContentListService", "getUserBannerContentListWithTabId:",
                ap_bannerList, ap_orig_bannerList, "v24@0:8@16");

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ APInstallButton(); });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ APInstallButton(); });
    }
}

} // extern "C"
