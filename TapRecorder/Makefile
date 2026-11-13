TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TapRecorder

TapRecorder_FILES = Tweak.x Sources/TRHID.m Sources/TRRecorder.m Sources/TRPanel.m
TapRecorder_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TapRecorder_FRAMEWORKS = UIKit CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

# Linux toolchains don't set the new arm64e ABI flag; set it and re-sign.
# (No-op on macOS/Xcode builds, which already set it.)
after-all::
	@python3 tools/fix_arm64e_abi.py $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib
	@$(TARGET_CODESIGN) -S $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib
