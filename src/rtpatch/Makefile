# rtpatch: the /var/jb path layer every guest process loads (see nxjbpath.c).
#
#   make ios    build/rtpatch for iOS arm64 (macOS + Xcode)
#   make test   build and run the host test (any OS with a C compiler)

MIN_IOS ?= 15.0
ARCH    ?= arm64
BUILD   ?= build

SDK_IOS := $(shell xcrun -sdk iphoneos --show-sdk-path 2>/dev/null)
CC_IOS  := $(shell xcrun -sdk iphoneos -f clang 2>/dev/null)
LDID    := $(shell command -v ldid 2>/dev/null)

.PHONY: ios test clean

# No install-time dependencies besides libSystem: the slots are looked up with
# dlsym at load time, so the library loads whatever the Nyxian version exports.
ios: nxjbpath.c jbmap.h
	@test -n "$(SDK_IOS)" || { echo "no iPhone SDK (need macOS + Xcode)"; exit 1; }
	@mkdir -p $(BUILD)
	$(CC_IOS) -arch $(ARCH) -isysroot $(SDK_IOS) -miphoneos-version-min=$(MIN_IOS) \
	    -O2 -Wall -Wextra -dynamiclib -install_name @rpath/rtpatch \
	    nxjbpath.c -o $(BUILD)/rtpatch
	@if [ -n "$(LDID)" ]; then $(LDID) -S $(BUILD)/rtpatch; fi

test: nxjbpath.c jbmap.h test/test_jbpath.c
	@mkdir -p $(BUILD)
	$(CC) -O1 -g -Wall -Wextra -rdynamic test/test_jbpath.c -o $(BUILD)/test_jbpath -ldl
	@d=$$(mktemp -d) && NXJB_VROOT=$$d NXJB_DEBUG=1 $(BUILD)/test_jbpath; rc=$$?; rm -rf $$d; exit $$rc

clean:
	rm -rf $(BUILD)
