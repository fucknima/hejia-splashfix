// ============================================================================
//  HeJiaTool 设置页 v3
//  每一项去除都单独列出来；启动后可自动进摄像头页。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdlib.h>
#include <unistd.h>

extern "C" void HTLog(const char *tag, NSString *msg);
extern "C" const char *HTGetLogFilePath(void);
extern "C" const char *HTGetAdScanLogPath(void);

#define SVC_LOG(...) HTLog("HeJiaUI", [NSString stringWithFormat:__VA_ARGS__])

extern "C" {

static NSString *const kNoAdsKey       = @"HeJiaTool_NoAds";
static NSString *const kNoHomeAdKey    = @"HeJiaTool_NoHomeAd";
static NSString *const kNoToolKey      = @"HeJiaTool_NoTool";
static NSString *const kNoCameraKey    = @"HeJiaTool_NoCamera";
static NSString *const kNoWalletKey    = @"HeJiaTool_NoWallet";
static NSString *const kNoFamilyKey    = @"HeJiaTool_NoFamily";
static NSString *const kHideServiceKey = @"HeJiaTool_HideService";
static NSString *const kHideFindKey    = @"HeJiaTool_HideFind";
static NSString *const kHideAIKey      = @"HeJiaTool_HideAI";
static NSString *const kLaunchCameraKey= @"HeJiaTool_LaunchCamera";

static void HTPostTabbarChanged(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"HeJiaTool_TabbarReload" object:nil];
}

// ---------------------------------------------------------------------------
// 日志预览
// ---------------------------------------------------------------------------
@interface HTLogPreviewViewController : UIViewController
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *displayTitle;
@end

@implementation HTLogPreviewViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.displayTitle ?: @"日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.selectable = YES;
    tv.alwaysBounceVertical = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(8, 8, 24, 8);
    NSString *text = [NSString stringWithContentsOfFile:self.filePath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    tv.text = text.length ? text : @"（文件为空或不存在）";
    [self.view addSubview:tv];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(close)];
}
- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

// ---------------------------------------------------------------------------
// 清数据：App 容器 + App Group 共享容器
// ---------------------------------------------------------------------------
static void HTClearSharedContainers(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *roots = [NSMutableArray array];
    for (NSString *gid in @[@"group.com.cmcc.zhihuiguanjia", @"group.zhangkelin.top"]) {
        NSURL *u = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
        if (u) [roots addObject:u];
    }
    NSString *home = NSHomeDirectory();
    for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
        [roots addObject:[NSURL fileURLWithPath:[home stringByAppendingPathComponent:sub]]];
    }
    NSInteger removed = 0;
    for (NSURL *root in roots) {
        NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:root
                                   includingPropertiesForKeys:nil
                                                      options:0
                                                        error:NULL];
        for (NSURL *item in items) {
            if ([fm removeItemAtURL:item error:NULL]) removed++;
        }
    }
    SVC_LOG(@"清除数据完成: %ld 项", (long)removed);
}

// ---------------------------------------------------------------------------
// 设置页
// ---------------------------------------------------------------------------
@interface HTSettingsViewController : UITableViewController
@end

@implementation HTSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(dismissSelf)];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 6; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    (void)tv;
    switch (s) {
        case 0: return @"广告与推广";
        case 1: return @"底部导航";
        case 2: return @"启动";
        case 3: return @"数据";
        case 4: return @"安全";
        default: return @"日志与诊断";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    (void)tv;
    if (s == 0) return @"总开关关闭后全部停止。细分项默认开启，改动在下次冷启动完全生效。";
    if (s == 1) return @"最少保留「设备」和「我的」；隐藏后可见项会等距重排。";
    if (s == 2) return @"启动并进入设备页后，自动打开摄像头页。";
    if (s == 3) return @"清除 App 与所有 App Group 共享容器的数据（设置、缓存、登录态、日志），完成后退出。";
    if (s == 4) return @"过签名检测默认开启且不可关闭，否则应用会被判定为已篡改。";
    if (s == 5) return @"点击直接预览日志内容。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv;
    switch (s) {
        case 0: return 6;
        case 1: return 3;
        case 2: return 1;
        case 3: return 2;
        case 4: return 1;
        default: return 2;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"HTSettingCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        UISwitch *sw = [[UISwitch alloc] init];
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (ip.section == 0 || ip.section == 1 || ip.section == 2) {
        NSString *keys[10] = {
            kNoAdsKey, kNoHomeAdKey, kNoToolKey, kNoCameraKey, kNoWalletKey, kNoFamilyKey,
            kHideServiceKey, kHideFindKey, kHideAIKey, kLaunchCameraKey
        };
        NSString *titles[10] = {
            @"屏蔽广告与推广（总开关）", @"首页/设备页广告卡", @"工具推广",
            @"摄像头服务推荐", @"我的钱包", @"爱家亲情网",
            @"隐藏「服务」", @"隐藏「发现」", @"隐藏 AI 灵犀", @"启动后进入摄像头页"
        };
        int base = (ip.section == 0) ? 0 : (ip.section == 1 ? 6 : 9);
        int idx = base + (int)ip.row;
        cell.textLabel.text = titles[idx];
        sw.hidden = NO;
        sw.enabled = YES;
        sw.tag = 100 + idx;
        BOOL on = [ud objectForKey:keys[idx]] ? [ud boolForKey:keys[idx]] : YES;
        [sw setOn:on animated:NO];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 3) {
        cell.textLabel.text = ip.row == 0 ? @"清除数据" : @"重启 App";
        cell.textLabel.textColor = ip.row == 0 ? [UIColor systemRedColor] : [UIColor labelColor];
        sw.hidden = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (ip.section == 4) {
        cell.textLabel.text = @"过签名检测";
        sw.hidden = NO;
        sw.enabled = NO;
        sw.tag = 200;
        [sw setOn:YES animated:NO];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = ip.row == 0 ? @"主日志  HeJiaTool.log" : @"扫描明细  adscan.log";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        sw.hidden = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 3) {
        if (ip.row == 1) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ _exit(0); });
            return;
        }
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"清除所有数据？"
                             message:@"会删除 App 与所有共享容器里的设置、缓存、登录态和日志，完成后立即退出。此操作不可恢复。"
                      preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"全部清除并退出"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *x) {
            UIAlertController *p = [UIAlertController alertControllerWithTitle:@"正在清除数据…"
                                                                       message:@"完成后会自动退出"
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [self presentViewController:p animated:YES completion:nil];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                HTClearSharedContainers();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ _exit(0); });
            });
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.view;
        a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    if (ip.section == 4) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"过签名检测"
                             message:@"该项已强制开启，用于绕过应用的篡改检测，不可修改。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    if (ip.section == 5) {
        const char *p = (ip.row == 0) ? HTGetLogFilePath() : HTGetAdScanLogPath();
        HTLogPreviewViewController *vc = [[HTLogPreviewViewController alloc] init];
        vc.filePath = [NSString stringWithUTF8String:p ?: ""];
        vc.displayTitle = ip.row == 0 ? @"主日志" : @"扫描明细";
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:nav animated:YES completion:nil];
    }
}

#pragma mark - 开关

- (void)switchChanged:(UISwitch *)sw {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *keys[10] = {
        kNoAdsKey, kNoHomeAdKey, kNoToolKey, kNoCameraKey, kNoWalletKey, kNoFamilyKey,
        kHideServiceKey, kHideFindKey, kHideAIKey, kLaunchCameraKey
    };
    int idx = (int)sw.tag - 100;
    if (idx >= 0 && idx < 10) {
        [ud setBool:sw.isOn forKey:keys[idx]];
        SVC_LOG(@"设置[%d] = %@", idx, sw.isOn ? @"开" : @"关");
        if (idx >= 6 && idx <= 8) HTPostTabbarChanged();
        if (idx == 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"HeJiaTool_NoAdsChanged" object:nil];
        }
    }
}

@end

extern "C" UIViewController *HTMakeSettingsVC(void) {
    return [[HTSettingsViewController alloc] init];
}

} // extern "C"
