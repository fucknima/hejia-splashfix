// ============================================================================
//  PushProbe.mm — 抓一次摄像头 push 的 VC 类名和参数（只记录）
//  开屏自动选中摄像头后，把 push 的 VC 及其对象型 ivar 写进 HeJiaTool.log。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern "C" void HTLog(const char *tag, NSString *msg);

static NSString *PPTrim(id obj) {
    if (!obj) return @"nil";
    NSString *s = [obj isKindOfClass:[NSString class]] ? (NSString *)obj : [obj description];
    if (![s isKindOfClass:[NSString class]]) return @"?";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (s.length > 400) s = [[s substringToIndex:400] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([obj class]), s];
}

static void PPDumpVC(UIViewController *vc, NSString *why) {
    if (!vc) return;
    NSString *cn = NSStringFromClass([vc class]);
    NSMutableString *out = [NSMutableString stringWithFormat:@"[PUSH:%@] %@", why, cn];
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList([vc class], &n);
    for (unsigned int i = 0; i < n; i++) {
        const char *tn = ivar_getTypeEncoding(ivars[i]);
        if (!tn || tn[0] != '@') continue;
        @try {
            id v = object_getIvar(vc, ivars[i]);
            if (v) [out appendFormat:@"\n  %s = %@", ivar_getName(ivars[i]), PPTrim(v)];
        } @catch (__unused NSException *e) {}
    }
    free(ivars);
    HTLog("HeJiaProbe", out);
}

static void (*pp_orig_push)(id, SEL, UIViewController *, BOOL);

static void pp_push(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    if (pp_orig_push) pp_orig_push(self, _cmd, vc, animated);
    NSString *cn = NSStringFromClass([vc class]);
    if ([cn containsString:@"Play"] || [cn containsString:@"Live"] ||
        [cn containsString:@"Device"] || [cn containsString:@"Camera"] ||
        [cn containsString:@"Detail"]) {
        PPDumpVC(vc, @"push");
    }
}

static id (*pp_orig_init2)(id, SEL, id, id);
static id pp_init2(id self, SEL _cmd, id model, id xml) {
    id r = pp_orig_init2 ? pp_orig_init2(self, _cmd, model, xml) : self;
    NSString *cn = NSStringFromClass([self class]);
    if ([cn containsString:@"Play"] || [cn containsString:@"UniControl"]) {
        HTLog("HeJiaProbe", [NSString stringWithFormat:
            @"[INIT] %@ model=%@ xml=%@", cn, PPTrim(model), PPTrim(xml)]);
    }
    return r;
}

static id (*pp_orig_init3)(id, SEL, id, id, id);
static id pp_init3(id self, SEL _cmd, id model, id xml, id origin) {
    id r = pp_orig_init3 ? pp_orig_init3(self, _cmd, model, xml, origin) : self;
    NSString *cn = NSStringFromClass([self class]);
    if ([cn containsString:@"Play"] || [cn containsString:@"UniControl"]) {
        HTLog("HeJiaProbe", [NSString stringWithFormat:
            @"[INIT3] %@ model=%@ xml=%@ origin=%@", cn, PPTrim(model), PPTrim(xml), PPTrim(origin)]);
    }
    return r;
}

__attribute__((constructor))
static void HTPushProbeInit(void) {
    @autoreleasepool {
        Class nav = objc_getClass("UINavigationController");
        if (nav) {
            Method m = class_getInstanceMethod(nav, sel_registerName("pushViewController:animated:"));
            if (m) {
                pp_orig_push = (void (*)(id, SEL, UIViewController *, BOOL))method_getImplementation(m);
                method_setImplementation(m, (IMP)pp_push);
            }
        }
        const char *playNames[] = { "HYCNCDeviceUniControlVC", "HYCNCDevicePlayVC", NULL };
        for (int i = 0; playNames[i]; i++) {
            Class play = objc_getClass(playNames[i]);
            if (!play) continue;
            Method m2 = class_getInstanceMethod(play, sel_registerName("initWithDeviceModel:withXMLModel:"));
            if (m2) {
                pp_orig_init2 = (id (*)(id, SEL, id, id))method_getImplementation(m2);
                method_setImplementation(m2, (IMP)pp_init2);
            }
            Method m3 = class_getInstanceMethod(play, sel_registerName("initWithDeviceModel:withXMLModel:originModel:"));
            if (m3) {
                pp_orig_init3 = (id (*)(id, SEL, id, id, id))method_getImplementation(m3);
                method_setImplementation(m3, (IMP)pp_init3);
            }
        }
        HTLog("HeJiaProbe", @"════ PushProbe 已加载 ════");
    }
}
