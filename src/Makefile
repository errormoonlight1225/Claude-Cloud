# nxlaunchd / nxlaunchctl build.
#
# Default target builds for iOS arm64 with the iPhone SDK and signs with ldid
# (for a jailbroken rootless device). `make host` builds for the current macOS
# for quick local testing. PREFIX sets the install prefix baked into the socket
# and state paths (default /var/jb, the rootless bootstrap location).

PREFIX    ?= /var/jb
MIN_IOS   ?= 15.0
ARCH      ?= arm64
BUILD     ?= build

COMMON_SRC   = common/nxjob.m common/nxcontrol.m
LAUNCHD_SRC  = $(COMMON_SRC) launchd/nxmanager.m launchd/main.m
LAUNCHCTL_SRC= $(COMMON_SRC) launchctl/main.m

CFLAGS_COMMON = -fobjc-arc -Wall -Wno-unused-variable -I common -I launchd \
                -DNX_PREFIX='"$(PREFIX)"' -O2

# --- iOS (device) ---
SDK_IOS   := $(shell xcrun -sdk iphoneos --show-sdk-path 2>/dev/null)
CC_IOS    := $(shell xcrun -sdk iphoneos -f clang 2>/dev/null)
LDID      := $(shell command -v ldid 2>/dev/null)
IOSFLAGS  = -arch $(ARCH) -isysroot $(SDK_IOS) -miphoneos-version-min=$(MIN_IOS) \
            -framework Foundation

.PHONY: all ios slot host clean sign
all: ios

# nxlaunchd for the ROM slot. Nyxian starts a ROM's own programs by dlopen()ing
# them and calling main (the template's Hello app is built the same way), and a
# sealed slot file cannot be converted on the device, so it is a dylib here.
slot: $(BUILD)/slot/nxlaunchd

$(BUILD)/slot/nxlaunchd: $(LAUNCHD_SRC)
	@test -n "$(SDK_IOS)" || { echo "no iPhone SDK (need macOS + Xcode)"; exit 1; }
	@mkdir -p $(BUILD)/slot
	$(CC_IOS) $(CFLAGS_COMMON) $(IOSFLAGS) -dynamiclib -install_name @rpath/nxlaunchd \
	    $(LAUNCHD_SRC) -o $@

ios: $(BUILD)/nxlaunchd $(BUILD)/nxlaunchctl sign

$(BUILD)/nxlaunchd: $(LAUNCHD_SRC) | $(BUILD)
	@test -n "$(SDK_IOS)" || { echo "no iPhone SDK (need macOS + Xcode)"; exit 1; }
	$(CC_IOS) $(CFLAGS_COMMON) $(IOSFLAGS) $(LAUNCHD_SRC) -o $@

$(BUILD)/nxlaunchctl: $(LAUNCHCTL_SRC) | $(BUILD)
	@test -n "$(SDK_IOS)" || { echo "no iPhone SDK (need macOS + Xcode)"; exit 1; }
	$(CC_IOS) $(CFLAGS_COMMON) $(IOSFLAGS) $(LAUNCHCTL_SRC) -o $@

# Sign for a jailbroken device. The daemon wants the platform/exec entitlements
# the host environment grants; adjust entitlements/nxlaunchd.entitlements to taste.
sign: $(BUILD)/nxlaunchd $(BUILD)/nxlaunchctl
	@if [ -n "$(LDID)" ]; then \
	  $(LDID) -Sentitlements/nxlaunchd.entitlements $(BUILD)/nxlaunchd; \
	  $(LDID) -Sentitlements/nxlaunchctl.entitlements $(BUILD)/nxlaunchctl; \
	  echo "signed with ldid"; \
	else echo "ldid not found: binaries are unsigned"; fi

# --- host (macOS) smoke build ---
host: $(BUILD)/host-nxlaunchd $(BUILD)/host-nxlaunchctl

$(BUILD)/host-nxlaunchd: $(LAUNCHD_SRC) | $(BUILD)
	clang $(CFLAGS_COMMON) -framework Foundation $(LAUNCHD_SRC) -o $@

$(BUILD)/host-nxlaunchctl: $(LAUNCHCTL_SRC) | $(BUILD)
	clang $(CFLAGS_COMMON) -framework Foundation $(LAUNCHCTL_SRC) -o $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
