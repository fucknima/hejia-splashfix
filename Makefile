ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = zhihuiguanjia

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HeJiaBypass

# 检测绕过 + Tab 隐藏 + 设置页 + 日志 + 广告屏蔽(v2)
HeJiaBypass_FILES = Tweak.xm NoAds.mm PushProbe.mm UIPanel.mm SettingsVC.mm TabHide.mm LogFile.mm

HeJiaBypass_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
HeJiaBypass_FRAMEWORKS = Foundation UIKit CoreFoundation CFNetwork
HeJiaBypass_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
