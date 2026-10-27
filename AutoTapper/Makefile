# AutoTapper - Theos Makefile
# Dopamine (rootless) 构建:  make package FINALPACKAGE=1
# 需先设置 THEOS 环境变量与 iOS SDK

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0

# rootless 打包(Dopamine 必须)。如需 rootful(旧越狱)把下一行改为 rootful
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoTapper

AutoTapper_FILES = Tweak.xm
AutoTapper_CFLAGS = -fobjc-arc
AutoTapper_FRAMEWORKS = UIKit CoreGraphics
AutoTapper_PRIVATE_FRAMEWORKS = IOKit
AutoTapper_LIBRARIES =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"
