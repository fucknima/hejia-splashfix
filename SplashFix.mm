#include <stdarg.h>
// HeJiaSplashFix — 移动爱家开屏广告黑屏修复
// 目标: com.cmcc.zhihuiguanjia / HYLaunchAdManager
// 做法: 保留开屏流程, 在 startAdLaunch: 之后立刻走 view 自己的 dismissView,
//       再隐藏窗口。不置空广告数据, 不碰主窗口, 只在窗口仍然可见时兜底隐藏。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*HTOrigStartAdLaunch)(id, SEL, id) = NULL;

static void HTLogMsg(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[HeJiaSplashFix] %@", s);
}

static id HTValue(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void HTDismissLaunch(id manager, NSInteger attempt) {
    id view = HTValue(manager, @"launchAdView");
    if (!view) view = HTValue(manager, @"launchAdForPadView");
    if (!view) {
        if (attempt < 4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ HTDismissLaunch(manager, attempt + 1); });
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
    HTLogMsg(@"开屏已关闭 view=%@ window=%@", v, win);
}

static void HTStartAdLaunch(id self, SEL _cmd, id arg) {
    if (HTOrigStartAdLaunch) HTOrigStartAdLaunch(self, _cmd, arg);
    HTLogMsg(@"startAdLaunch: 触发");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ HTDismissLaunch(self, 0); });
}

// 兜底: 若 3 秒后主窗口仍被其他地方隐藏(例如 WindowFix 误判), 恢复一次。
static void HTCheckMainWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    id delegate = app.delegate;
    UIWindow *win = nil;
    if ([delegate respondsToSelector:@selector(window)]) {
        @try { win = [delegate valueForKey:@"window"]; } @catch (__unused NSException *e) {}
    }
    if (!win) win = app.keyWindow;
    if (win && win.isHidden && win.rootViewController) {
        win.hidden = NO;
        HTLogMsg(@"主窗口曾被隐藏, 已恢复: %@", win);
    }
}

__attribute__((constructor))
static void HTSplashFixInit(void) {
    @autoreleasepool {
        Class cls = objc_getClass("HYLaunchAdManager");
        if (!cls) { HTLogMsg(@"找不到 HYLaunchAdManager"); return; }
        Method m = class_getInstanceMethod(cls, sel_registerName("startAdLaunch:"));
        if (!m) { HTLogMsg(@"找不到 startAdLaunch:"); return; }
        const char *types = method_getTypeEncoding(m);
        if (!types || types[0] != 'v' || types[1] != '2' || types[2] != '4') {
            HTLogMsg(@"startAdLaunch: 签名不符, 跳过: %s", types ?: "?");
            return;
        }
        HTOrigStartAdLaunch = (void (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)HTStartAdLaunch);
        HTLogMsg(@"已挂 startAdLaunch:");

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ HTCheckMainWindow(); });
        }];
    }
}
