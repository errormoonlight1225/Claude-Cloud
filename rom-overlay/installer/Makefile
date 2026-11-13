# Builds the ROM's NXRomInstaller as an iOS arm64 dylib exporting NXRomInstall.
# Nyxian dlopen()s it at flash time; RomGen ad-hoc signs it with the ROM key.

ARCH    ?= arm64
MIN_IOS ?= 15.0
BUILD   ?= build

SDK_IOS := $(shell xcrun -sdk iphoneos --show-sdk-path 2>/dev/null)
CC_IOS  := $(shell xcrun -sdk iphoneos -f clang 2>/dev/null)

.PHONY: ios clean
ios: $(BUILD)/installer

$(BUILD)/installer: nxrom_install.m | $(BUILD)
	@test -n "$(SDK_IOS)" || { echo "no iPhone SDK (need macOS + Xcode)"; exit 1; }
	$(CC_IOS) -arch $(ARCH) -isysroot $(SDK_IOS) -miphoneos-version-min=$(MIN_IOS) \
	  -fobjc-arc -Wall -dynamiclib -framework Foundation \
	  -install_name @executable_path/installer \
	  nxrom_install.m -o $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
