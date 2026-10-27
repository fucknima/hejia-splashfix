// ============================================================================
//  Tab 隐藏模块 v3 —— 按文字隐藏按钮，不动 viewControllers
//  Bundle: com.cmcc.zhihuiguanjia
// ----------------------------------------------------------------------------
//  ⚠️ v2 的严重 bug（用户实测：点「发现」出「我的」，点「我的」无效）：
//    我过滤了 UITabBarController.viewControllers，但 HYTabBar 的按钮是
//    独立构建的，索引不会跟着变，造成错位：
//      原始 [0]设备 [1]服务 [2]发现 [3]我的
//      剔除「发现」后 VC 变 3 个：[0]设备 [1]服务 [2]我的
//      点「发现」(2) → VC[2] = 我的   ✗
//      点「我的」(3) → 越界          ✗
//
//  v3 方案：完全不碰 viewControllers，索引永远正确。
//    改为在 HYTabBar / HYCustomTabBar 上，按按钮里的文字
//    （「服务」「发现」）定位到对应子视图并设为 hidden。
//    用文字定位而不是索引，因为：
//      - 服务页真实类是 HYExhibitionViewController（不叫 Service）
//      - 中间还有 AI 灵犀特殊位，索引不可靠
//
//  安全措施：
//    - 只设 hidden，不改 frame（frame 改动会触发递归布局，之前崩过）
//    - 深度限制 + 只处理 HYTabBar 系类
//    - 递归保护标志
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <substrate.h>

extern "C" void HTLog(const char *tag, NSString *msg);
#define TAB_LOG(...) HTLog("HeJiaTab", [NSString stringWithFormat:__VA_ARGS__])

extern "C" {

static NSString *const kHideServiceKey = @"HeJiaTool_HideService";
static NSString *const kHideFindKey    = @"HeJiaTool_HideFind";

static IMP HTOrig_tabbarLayout = NULL;
static __thread BOOL gInTabLayout = NO;

// ---------------------------------------------------------------------------
// 递归查找：这个视图里是否含有指定文字的标签
// ---------------------------------------------------------------------------
static BOOL HTViewHasText(id view, NSString *text, int depth);

static BOOL HTViewHasText(id view, NSString *text, int depth) {
    if (!view || depth > 6 || !text) return NO;

    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)view).text;
            if ([t isKindOfClass:[NSString class]] && [t isEqualToString:text]) return YES;
        }
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)view;
            NSString *t = [b titleForState:UIControlStateNormal];
            if ([t isKindOfClass:[NSString class]] && [t isEqualToString:text]) return YES;
        }
        if ([view isKindOfClass:[UIView class]]) {
            for (UIView *sub in ((UIView *)view).subviews) {
                if (HTViewHasText(sub, text, depth + 1)) return YES;
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// 隐藏按钮：遍历 tab bar 的直接子视图，含目标文字者设为 hidden
// ---------------------------------------------------------------------------
static void HTHideTabItems(UIView *tabBar) {
    if (!tabBar) return;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL hideService = [ud boolForKey:kHideServiceKey];
    BOOL hideFind    = [ud boolForKey:kHideFindKey];
    if (!hideService && !hideFind) return;

    NSMutableArray *targets = [NSMutableArray array];
    if (hideService) [targets addObject:@"服务"];
    if (hideFind)    [targets addObject:@"发现"];

    NSArray *subs = tabBar.subviews;
    if (!subs || subs.count == 0) return;

    int hiddenCount = 0;
    for (UIView *sub in subs) {
        // 跳过背景图
        NSString *cn = NSStringFromClass([sub class]);
        if ([cn containsString:@"ImageView"]) continue;

        for (NSString *t in targets) {
            if (HTViewHasText(sub, t, 0)) {
                if (!sub.hidden) {
                    sub.hidden = YES;      // 只改 hidden，安全
                    TAB_LOG(@"已隐藏 Tab 按钮：%@", t);
                }
                hiddenCount++;
                break;
            }
        }
    }
    (void)hiddenCount;
}

// ---------------------------------------------------------------------------
// hook HYTabBar / HYCustomTabBar 的 layoutSubviews
// ---------------------------------------------------------------------------
static void HTTabBarLayout(id self, SEL _cmd) {
    typedef void (*fn_t)(id, SEL);
    if (HTOrig_tabbarLayout) ((fn_t)HTOrig_tabbarLayout)(self, _cmd);

    if (gInTabLayout) return;
    gInTabLayout = YES;

    HTHideTabItems((UIView *)self);

    gInTabLayout = NO;
}

// ---------------------------------------------------------------------------
// 开关变化时，让所有 tab bar 重跑一次布局（触发隐藏）
// ---------------------------------------------------------------------------
static void HTRefreshTabBars(void) {
    UIWindow *keyWin = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWin = w; break; }
    }
    if (!keyWin) keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) return;

    NSMutableArray *stack = [NSMutableArray array];
    if (keyWin.rootViewController) [stack addObject:keyWin.rootViewController];

    int found = 0;
    while (stack.count > 0) {
        UIViewController *vc = [stack lastObject];
        [stack removeLastObject];

        // 命中 HYTabBar 系视图就应用一次
        if ([vc isKindOfClass:[UIViewController class]]) {
            UIView *v = vc.view;
            if (v) {
                Class barCls = objc_getClass("HYTabBar");
                if (barCls && [v isKindOfClass:barCls]) {
                    HTHideTabItems(v);
                    found++;
                }
            }
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        }
    }

    // 兜底：直接扫窗口层级
    if (found == 0) {
        NSMutableArray *views = [NSMutableArray array];
        [views addObject:keyWin];
        while (views.count > 0) {
            UIView *v = [views lastObject];
            [views removeLastObject];
            Class barCls = objc_getClass("HYTabBar");
            if (barCls && [v isKindOfClass:barCls]) {
                HTHideTabItems(v);
                found++;
            }
            for (UIView *s in v.subviews) [views addObject:s];
        }
    }

    TAB_LOG(@"刷新 tab bar：命中 %d 个", found);
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void HeJiaTabInit(void) {
    @autoreleasepool {
        TAB_LOG(@"════ Tab 模块 v3 加载（不动 viewControllers）════");

        // 只为确认结构，保留一个只读诊断
        Class tabCtrl = objc_getClass("HYTabBarController");
        if (tabCtrl) {
            TAB_LOG(@"找到 HYTabBarController");
        }

        // hook 两种可能的 tab bar 类
        const char *barNames[] = { "HYTabBar", "HYCustomTabBar", NULL };
        int hooked = 0;
        for (int i = 0; barNames[i]; i++) {
            Class c = objc_getClass(barNames[i]);
            if (!c) continue;
            Method m = class_getInstanceMethod(c, @selector(layoutSubviews));
            if (!m) continue;
            if (!HTOrig_tabbarLayout) {
                HTOrig_tabbarLayout = method_getImplementation(m);
            }
            method_setImplementation(m, (IMP)HTTabBarLayout);
            TAB_LOG(@"hook -[%s layoutSubviews]", barNames[i]);
            hooked++;
        }

        if (hooked == 0) {
            TAB_LOG(@"未找到 HYTabBar，隐藏功能不可用");
        }

        // 开关变化后重跑
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"HeJiaTool_TabbarReload"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(id note) {
            (void)note;
            HTRefreshTabBars();
        }];

        // 启动后延时补一次（等 tab bar 建好）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            HTRefreshTabBars();
        });

        TAB_LOG(@"════ Tab 模块 v3 完成 ════");
    }
}

} // extern "C"
