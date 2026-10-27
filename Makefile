ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = zhihuiguanjia

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HeJiaSplashFix
HeJiaSplashFix_FILES = SplashFix.mm
HeJiaSplashFix_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
HeJiaSplashFix_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
