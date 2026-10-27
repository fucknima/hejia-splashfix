// ============================================================================
//  HeJiaTool 唤起模块 v6（摇一摇）
//  Bundle: com.cmcc.zhihuiguanjia
// ----------------------------------------------------------------------------
//  唯一触发方式：摇一摇手机
//
//  历史（已移除）：
//    - 布局 hook        → 无限递归 0x8BADF00D
//    - addSubview        → UIVisualEffectView 断言 SIGABRT
//    - 三指长按手势      → 被 App 手势吞掉，实测无效
//    - UIWindow.sendEvent → 实测从未被调用
//    - 状态栏双击        → 依附 sendEvent，同样无效
//  motionEnded: 是唯一实测可用的路径，保留单一实现，避免冗余代码。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#include <CoreFoundation/CoreFoundation.h>

#include <substrate.h>

extern "C" void HTLog(const char *tag, NSString *msg);
extern "C" const char *HTGetLogFilePath(void);
#define UI_LOG(...) HTLog("HeJiaUI", [NSString stringWithFormat:__VA_ARGS__])

extern "C" UIViewController *HTMakeSettingsVC(void);

extern "C" {

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
static IMP HTOrig_motionEnded = NULL;

static const void *kHTMenuShowingKey = &kHTMenuShowingKey;

// ---------------------------------------------------------------------------
// 取最顶层控制器
// ---------------------------------------------------------------------------
static UIViewController *HTTopMost(void) {
    UIWindow *keyWin = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWin = w; break; }
    }
    if (!keyWin) keyWin = [UIApplication sharedApplication].keyWindow;

    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

// ---------------------------------------------------------------------------
// 弹出主菜单
// ---------------------------------------------------------------------------
static void HTShowMenu(void) {
    // 防重复弹
    if (objc_getAssociatedObject([UIApplication sharedApplication],
                                 kHTMenuShowingKey)) return;

    UIViewController *top = HTTopMost();
    if (!top) { UI_LOG(@"找不到顶层控制器"); return; }

    UI_LOG(@"菜单触发成功");

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"HeJiaTool 工具箱"
                         message:@"选择要执行的操作"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"⚙️  打开设置"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        (void)a;
        UIViewController *vc = HTMakeSettingsVC();
        if (!vc) return;
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [HTTopMost() presentViewController:nav animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"📄  复制日志路径"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        (void)a;
        const char *p = HTGetLogFilePath();
        NSString *path = [NSString stringWithUTF8String:p ?: ""];
        [UIPasteboard generalPasteboard].string = path;
        UI_LOG(@"已复制日志路径");

        UIAlertController *ok = [UIAlertController
            alertControllerWithTitle:@"日志路径已复制"
                             message:path
                      preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"好"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
        [HTTopMost() presentViewController:ok animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"🧹  清理广告缓存"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        (void)a;
        // 清 NSURLCache
        NSURLCache *cache = [NSURLCache sharedURLCache];
        [cache removeAllCachedResponses];
        // 清用户默认值里的运营位缓存
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        for (NSString *k in @[@"TabbarsDictCache", @"TabBarPageDictCacheKey",
                              @"shouldModifyTabbarInfoDict", @"ModifyTabbarInfoDict",
                              @"ModifyTabbarsDictForProvice"]) {
            [ud removeObjectForKey:k];
        }
        UI_LOG(@"已清理广告/运营位缓存");

        UIAlertController *ok = [UIAlertController
            alertControllerWithTitle:@"已清理"
                             message:@"缓存已清除，请重启 App 生效"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"好"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
        [HTTopMost() presentViewController:ok animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = top.view;
        pop.sourceRect = CGRectMake(top.view.bounds.size.width / 2,
                                    top.view.bounds.size.height / 2, 1, 1);
    }

    objc_setAssociatedObject([UIApplication sharedApplication],
                             kHTMenuShowingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [top presentViewController:sheet animated:YES completion:^{
        objc_setAssociatedObject([UIApplication sharedApplication],
                                 kHTMenuShowingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
}

// ---------------------------------------------------------------------------
//   优势：完全绕过手势系统，任何手势都抢不走
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// 摇一摇
// ---------------------------------------------------------------------------
static void HTMotionEnded(id self, SEL _cmd, NSInteger subtype, UIEvent *event) {
    typedef void (*fn_t)(id, SEL, NSInteger, UIEvent *);
    if (HTOrig_motionEnded) ((fn_t)HTOrig_motionEnded)(self, _cmd, subtype, event);

    // UIEventSubtypeMotionShake = 1
    if (subtype == 1) {
        UI_LOG(@"摇一摇触发");
        HTShowMenu();
    }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void HeJiaUIInit(void) {
    @autoreleasepool {
        UI_LOG(@"════ 唤起模块 v6 加载（摇一摇）════");

        Class winCls = objc_getClass("UIWindow");
        if (winCls) {
            // 路线 C
            Method m2 = class_getInstanceMethod(winCls, @selector(motionEnded:withEvent:));
            if (m2) {
                HTOrig_motionEnded = method_getImplementation(m2);
                method_setImplementation(m2, (IMP)HTMotionEnded);
                UI_LOG(@"hook -[UIWindow motionEnded:withEvent:]");
            }
        }

        UI_LOG(@"════ 唤起就绪：摇一摇手机 ════");
    }
}

} // extern "C"
