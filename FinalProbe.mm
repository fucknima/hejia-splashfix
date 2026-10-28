// ============================================================================
//  FinalProbe.mm — 一次性信息采集（只记录）
//  输出: Documents/HeJiaTool/finalprobe.log
//  采集: 设备数组 / 摄像头 adapter / 路由 / 我的页组件与视图树 / 导航栈 / Tab
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern "C" void HTLog(const char *tag, NSString *msg);
extern "C" const char *HTGetLogDir(void);

static NSString *FPTrim(id obj) {
    if (!obj) return @"nil";
    NSString *s = nil;
    @try { s = [obj isKindOfClass:[NSString class]] ? (NSString *)obj : [obj description]; }
    @catch (__unused NSException *e) { return @"<desc error>"; }
    if (![s isKindOfClass:[NSString class]]) return @"?";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (s.length > 300) s = [[s substringToIndex:300] stringByAppendingString:@"…"];
    return s;
}

static NSString *FPPath(void) {
    NSString *dir = HTGetLogDir() ? [NSString stringWithUTF8String:HTGetLogDir()] : nil;
    if (!dir.length) {
        dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
               stringByAppendingPathComponent:@"HeJiaTool"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"finalprobe.log"];
}

static void FPWrite(NSString *section, NSString *body) {
    if (!body) return;
    NSString *path = FPPath();
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *entry = [NSString stringWithFormat:@"\n===== %@ %@ =====\n%@\n",
                       section, [df stringFromDate:[NSDate date]], body];
    @synchronized (path) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (__unused NSException *e) {}
        }
    }
    NSLog(@"[FinalProbe] wrote %@ (%lu chars)", section, (unsigned long)body.length);
}

static NSString *FPDumpObj(id obj, int depth) {
    if (!obj) return @"nil";
    NSMutableString *s = [NSMutableString string];
    Class c = [obj class];
    NSString *cn = NSStringFromClass(c);
    [s appendFormat:@"class=%@ desc=%@", cn, FPTrim(obj)];

    // 视图/控制器/集合只给类名和描述，绝不 KVC（会提前触发 loadView 崩溃）
    if ([obj isKindOfClass:[UIView class]] || [obj isKindOfClass:[UIViewController class]] ||
        [obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        return s;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj;
        NSUInteger i = 0;
        for (id key in d) {
            if (i++ > 40) break;
            [s appendFormat:@"\n  %@ = %@", FPTrim(key), FPTrim(d[key])];
        }
        return s;
    }
    // 只对 model/adapter/data 这类做 ivar 反射，且只看对象型 ivar
    if (!([cn containsString:@"Model"] || [cn containsString:@"Adapter"] ||
          [cn containsString:@"Data"] || [cn containsString:@"Info"] ||
          [cn containsString:@"Item"])) {
        return s;
    }
    if (depth <= 0) return s;
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(c, &n);
    for (unsigned int i = 0; i < n; i++) {
        const char *tn = ivar_getTypeEncoding(ivars[i]);
        if (!tn || tn[0] != '@') continue;
        @try {
            id v = object_getIvar(obj, ivars[i]);
            if (v) [s appendFormat:@"\n  ivar %s = %@", ivar_getName(ivars[i]), FPDumpObj(v, depth - 1)];
        } @catch (__unused NSException *e) {}
    }
    free(ivars);
    return s;
}

static void FPDumpView(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 10 || out.length > 120000) return;
    CGRect f = v.frame;
    UIColor *bg = v.backgroundColor;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (bg) {
        @try { [bg getRed:&r green:&g blue:&b alpha:&a]; } @catch (__unused NSException *e) {}
    }
    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) text = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) text = [(UIButton *)v titleForState:UIControlStateNormal];
    if (text.length > 40) text = [text substringToIndex:40];

    [out appendFormat:@"%*s%@ f=(%.0f,%.0f,%.0f,%.0f) hidden=%d alpha=%.2f bg=(%.2f,%.2f,%.2f,%.2f) cr=%.1f%@\n",
        depth * 2, "", NSStringFromClass([v class]),
        f.origin.x, f.origin.y, f.size.width, f.size.height,
        v.hidden, v.alpha, r, g, b, a, v.layer.cornerRadius,
        text.length ? [NSString stringWithFormat:@" text=%@", text] : @""];

    for (UIView *sub in v.subviews) FPDumpView(sub, depth + 1, out);
}

static NSString *FPStack(UINavigationController *nav) {
    NSMutableString *s = [NSMutableString string];
    for (UIViewController *vc in nav.viewControllers) {
        [s appendFormat:@"%@ > ", NSStringFromClass([vc class])];
    }
    return s;
}

static NSString *FPTopStack(void) {
    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) { kw = w; break; }
    UIViewController *vc = kw.rootViewController;
    NSMutableString *s = [NSMutableString string];
    int guard = 0;
    while (vc && guard++ < 10) {
        [s appendFormat:@"%@ > ", NSStringFromClass([vc class])];
        if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController *)vc).selectedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).topViewController;
        else if (vc.presentedViewController) vc = vc.presentedViewController;
        else break;
    }
    return s;
}

// ---------------------------------------------------------------------------
// 设备数组
// ---------------------------------------------------------------------------
static void (*fp_orig_deviceList)(id, SEL, id, long);

static void fp_deviceList(id self, SEL _cmd, id arr, long idx) {
    static int logCount = 0;
    if (logCount++ > 2) {
        if (fp_orig_deviceList) fp_orig_deviceList(self, _cmd, arr, idx);
        return;
    }
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"listView=%@ idx=%ld count=%lu\n", NSStringFromClass([self class]), idx,
            (unsigned long)([arr isKindOfClass:[NSArray class]] ? [arr count] : 0)];
        if ([arr isKindOfClass:[NSArray class]]) {
            NSArray *a = arr;
            for (NSUInteger i = 0; i < a.count; i++) {
                [out appendFormat:@"\n--- item %lu ---\n%@\n", (unsigned long)i, FPDumpObj(a[i], 1)];
            }
        }
        FPWrite(@"DEVICE", out);
    }
    if (fp_orig_deviceList) fp_orig_deviceList(self, _cmd, arr, idx);
}

// ---------------------------------------------------------------------------
// 摄像头 adapter / VC
// ---------------------------------------------------------------------------
static id (*fp_orig_adapterInit)(id, SEL, id);
static id fp_adapterInit(id self, SEL _cmd, id device) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"initWithDevcie arg:\n%@", FPDumpObj(device, 1)];
    FPWrite(@"ADAPTER", out);
    return fp_orig_adapterInit ? fp_orig_adapterInit(self, _cmd, device) : self;
}

static id (*fp_orig_uniInit4)(id, SEL, id, id, id);
static id fp_uniInit4(id self, SEL _cmd, id url, id query, id native) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"initWithNavigatorURL:\n url=%@\n query=%@\n native=%@\n",
        FPTrim(url), FPTrim(query), FPTrim(native)];
    FPWrite(@"CAMERA-INIT", out);
    return fp_orig_uniInit4 ? fp_orig_uniInit4(self, _cmd, url, query, native) : self;
}

static id (*fp_orig_uniInitModel)(id, SEL, id, id, id);
static id fp_uniInitModel(id self, SEL _cmd, id model, id xml, id origin) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"initWithDeviceModel:\n model=%@\n xml=%@\n origin=%@\n",
        FPDumpObj(model, 1), FPTrim(xml), FPTrim(origin)];
    FPWrite(@"CAMERA-INIT", out);
    return fp_orig_uniInitModel ? fp_orig_uniInitModel(self, _cmd, model, xml, origin) : self;
}

static void (*fp_orig_push)(id, SEL, UIViewController *, BOOL);
static void fp_push(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    if (fp_orig_push) fp_orig_push(self, _cmd, vc, animated);
    NSString *cn = NSStringFromClass([vc class]);
    if ([cn containsString:@"UniControl"] || [cn containsString:@"Play"] || [cn containsString:@"Live"]) {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"pushed=%@\n", cn];
        @try {
            id kh = [vc valueForKey:@"khDevice"];
            if (kh) [out appendFormat:@"khDevice=%@\n", FPDumpObj(kh, 1)];
        } @catch (__unused NSException *e) {}
        [out appendFormat:@"stack=%@",
            [self isKindOfClass:[UINavigationController class]] ? FPStack((UINavigationController *)self) : @"?"];
        FPWrite(@"PUSH", out);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIWindow *kw = nil;
            for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) { kw = w; break; }
            UIView *root = kw.rootViewController.view;
            NSMutableString *tree = [NSMutableString string];
            FPDumpView(root, 0, tree);
            FPWrite(@"LIVE-TREE", tree);
            FPWrite(@"NAV", [NSString stringWithFormat:@"stack=%@", FPTopStack()]);
        });
    }
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------
static BOOL (*fp_orig_openURL)(id, SEL, id, id, id);
static BOOL fp_openURL(id self, SEL _cmd, id app, id url, id options) {
    NSString *u = [url isKindOfClass:[NSURL class]] ? [(NSURL *)url absoluteString] : FPTrim(url);
    BOOL ok = fp_orig_openURL ? fp_orig_openURL(self, _cmd, app, url, options) : NO;
    FPWrite(@"ROUTE", [NSString stringWithFormat:@"openURL: %@ -> %d", u, ok]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FPWrite(@"ROUTE-STACK", FPTopStack());
    });
    return ok;
}

// ---------------------------------------------------------------------------
// 我的页组件 / 视图树
// ---------------------------------------------------------------------------
static void (*fp_orig_myComp)(id, SEL, id, id, id, id);
static void fp_myComp(id self, SEL _cmd, id arr, id tab, id real, id block) {
    static int logCount = 0;
    if (logCount++ > 2) {
        if (fp_orig_myComp) fp_orig_myComp(self, _cmd, arr, tab, real, block);
        return;
    }
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"tab=%@ real=%@ count=%lu\n", FPTrim(tab), FPTrim(real),
        (unsigned long)([arr isKindOfClass:[NSArray class]] ? [arr count] : 0)];
    if ([arr isKindOfClass:[NSArray class]]) {
        NSArray *a = arr;
        for (NSUInteger i = 0; i < a.count && i < 40; i++) {
            [out appendFormat:@"\n--- comp %lu ---\n%@\n", (unsigned long)i, FPDumpObj(a[i], 1)];
        }
    }
    FPWrite(@"MY-COMPONENTS", out);
    if (fp_orig_myComp) fp_orig_myComp(self, _cmd, arr, tab, real, block);
}

static void (*fp_orig_viewDidAppear)(id, SEL, BOOL);
static void fp_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (fp_orig_viewDidAppear) fp_orig_viewDidAppear(self, _cmd, animated);
    NSString *cn = NSStringFromClass([self class]);
    if (![cn containsString:@"MyInfo"]) return;
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        if ([seen containsObject:cn]) return;
        [seen addObject:cn];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *vc = self;
        NSMutableString *tree = [NSMutableString string];
        FPDumpView(vc.view, 0, tree);
        FPWrite(@"MY-TREE", [NSString stringWithFormat:@"vc=%@\n%@", cn, tree]);

        // tab bar 状态
        UIWindow *kw = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) { kw = w; break; }
        NSMutableArray *stack = [NSMutableArray arrayWithObject:kw];
        NSMutableString *tab = [NSMutableString string];
        while (stack.count) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            NSString *vn = NSStringFromClass([v class]);
            if ([vn containsString:@"TabBar"] && ! [vn containsString:@"Button"]) {
                [tab appendFormat:@"\n%@ f=%@ hidden=%d alpha=%.2f\n",
                    vn, NSStringFromCGRect(v.frame), v.hidden, v.alpha];
                for (UIView *s in v.subviews) {
                    [tab appendFormat:@"   %@ f=%@ hidden=%d alpha=%.2f\n",
                        NSStringFromClass([s class]), NSStringFromCGRect(s.frame), s.hidden, s.alpha];
                }
            }
            for (UIView *s in v.subviews) [stack addObject:s];
        }
        FPWrite(@"TAB", tab);
    });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void HTFinalProbeInit(void) {
    @autoreleasepool {
        HTLog("FinalProbe", @"════ FinalProbe 已加载 ════");

        Class list = objc_getClass("HYHardwareFamilyDeviceListView");
        if (list) {
            Method m = class_getInstanceMethod(list, sel_registerName("configWithAllDeviceArray:currentRoomIndex:"));
            if (m) {
                fp_orig_deviceList = (void (*)(id, SEL, id, long))method_getImplementation(m);
                method_setImplementation(m, (IMP)fp_deviceList);
            }
        }

        Class adapter = objc_getClass("HYZdkDeviceAdapter");
        if (adapter) {
            Method m = class_getInstanceMethod(adapter, sel_registerName("initWithDevcie:"));
            if (m) {
                fp_orig_adapterInit = (id (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)fp_adapterInit);
            }
        }

        Class uni = objc_getClass("HYCNCDeviceUniControlVC");
        if (uni) {
            Method m = class_getInstanceMethod(uni, sel_registerName("initWithNavigatorURL:query:nativeParams:"));
            if (m) {
                fp_orig_uniInit4 = (id (*)(id, SEL, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)fp_uniInit4);
            }
            m = class_getInstanceMethod(uni, sel_registerName("initWithDeviceModel:withXMLModel:originModel:"));
            if (m) {
                fp_orig_uniInitModel = (id (*)(id, SEL, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)fp_uniInitModel);
            }
        }

        Class nav = objc_getClass("UINavigationController");
        if (nav) {
            Method m = class_getInstanceMethod(nav, sel_registerName("pushViewController:animated:"));
            if (m) {
                fp_orig_push = (void (*)(id, SEL, UIViewController *, BOOL))method_getImplementation(m);
                method_setImplementation(m, (IMP)fp_push);
            }
        }

        Class appDel = objc_getClass("AppDelegate");
        if (appDel) {
            Method m = class_getInstanceMethod(appDel, sel_registerName("application:openURL:options:"));
            if (m) {
                fp_orig_openURL = (BOOL (*)(id, SEL, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)fp_openURL);
            }
        }

        Class myInfo = objc_getClass("HYMyInfoComponentManager");
        if (myInfo) {
            Method m = class_getInstanceMethod(myInfo, sel_registerName("getViewWithComponentDictArray:tabId:realTabId:completeBlock:"));
            if (m) {
                fp_orig_myComp = (void (*)(id, SEL, id, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)fp_myComp);
            }
        }

        Method m = class_getInstanceMethod([UIViewController class], sel_registerName("viewDidAppear:"));
        if (m) {
            fp_orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
            method_setImplementation(m, (IMP)fp_viewDidAppear);
        }
    }
}
