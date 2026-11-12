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

.PHONY: all ios host clean sign
all: ios

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
