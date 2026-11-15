# Small stand-ins the bootstrap needs (see nxnoop.c).
MIN_IOS ?= 15.0
ARCH    ?= arm64
BUILD   ?= build
SDK_IOS := $(shell xcrun -sdk iphoneos --show-sdk-path 2>/dev/null)
CC_IOS  := $(shell xcrun -sdk iphoneos -f clang 2>/dev/null)

.PHONY: ios clean
ios: nxnoop.c
	@test -n "$(SDK_IOS)" || { echo "no iPhone SDK (need macOS + Xcode)"; exit 1; }
	@mkdir -p $(BUILD)
	$(CC_IOS) -arch $(ARCH) -isysroot $(SDK_IOS) -miphoneos-version-min=$(MIN_IOS) -Os -Wall nxnoop.c -o $(BUILD)/nxnoop

clean:
	rm -rf $(BUILD)
