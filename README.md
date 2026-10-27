# HeJiaSplashFix

移动爱家（`com.cmcc.zhihuiguanjia`）开屏广告 window 不销毁导致黑屏的最小修复。

## 它做什么

- hook `-[HYLaunchAdManager startAdLaunch:]`，保留原流程（不置空广告数据），
  0.05s 后调用 `-[HYLaunchAdView dismissView]` 并隐藏其 window。
- 3s 后检查一次 AppDelegate 主窗口；若被误隐藏则恢复（兜底 WindowFix 误判）。
- 不拦截网络、不屏蔽广告数据、不改主窗口，广告屏蔽仍由 HeJiaBypass 负责。

## 用法

把 `HeJiaSplashFix.dylib` 放进 `Payload/zhihuiguanjia.app/Frameworks/`，
给主二进制加一条 `LC_LOAD_DYLIB`（`@executable_path/Frameworks/HeJiaSplashFix.dylib`），
然后按你的方式重签。

> 与 HeJiaBypass.dylib 共存；两个都不要重复 hook 同一个 selector。

## 构建

GitHub Actions 自动构建，产物在 Actions 的 `HeJiaSplashFix.dylib` artifact。
