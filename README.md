# HeJiaBypass（合并版）

移动爱家 `com.cmcc.zhihuiguanjia` 单 dylib：检测绕过 + Tab 隐藏 + 设置页 + 日志 + 广告屏蔽。
产物名 `HeJiaBypass.dylib`，直接替换旧文件，不要和旧的 NoAds 版同时注入。

## 合并内容

保留自旧 dylib（hejia-bypass）的全部非广告功能：

- 越狱/篡改/注入/调试/代理检测绕过（Tweak.xm）
- 隐藏「服务」「发现」Tab（TabHide.mm）
- 我的页入口 / 工具箱 / 设置页 / 日志（UIPanel.mm、SettingsVC.mm、LogFile.mm）

广告屏蔽重写为 v2（NoAds.mm），只改展示与开关：

- 开屏：`startAdLaunch:` 原流程照走，0.05s 后 `-[HYLaunchAdView dismissView]` 并隐藏 window，
  不再置空 `safeAdDataArray*` —— 这是开屏后黑屏的根因。
- 删除网络层拦截（旧版已证明会制造空广告窗口挡触摸）。
- 总开关 `HYGetAdSwitchState` -> NO、`isShowAd*` -> NO。
- 广告 SDK 只屏蔽 show/render/present，不碰 init/load/bidding。
- 自有 banner：`-[HYCNCAdBanner show]` no-op + `didMoveToWindow` 隐藏；
  `-[HYHardwareBannerManager isClose]` -> YES。
- 不做 WindowFix，不隐藏任何 keyWindow/主窗口。

## 已知限制

- 广告开关的“关”在下次冷启动生效（hook 安装后无法无损撤除）。
- MIGU 视频贴片仍走旧的展示层屏蔽；若出现播放器黑屏，把 NoAds.mm 里
  `NAIsAdSDKClass` 的 `MIGU` 前缀去掉即可。
- 真机行为未在本仓库 CI 验证，CI 只保证 Theos 编译通过。

## 构建

推送 main 或手动 `workflow_dispatch`，Actions 产物：`HeJiaBypass.dylib`（arm64 + arm64e）。
