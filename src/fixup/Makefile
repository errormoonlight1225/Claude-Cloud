# nxfixup: relocates and signs the Mach-O files of /var/jb on the device
# (see nxfixup.c). dpkg runs it after every transaction.
#
#   make ios    build/nxfixup for iOS arm64 (macOS + Xcode)
#   make test   build for the host and run the tests (any OS with a C compiler)

MIN_IOS ?= 15.0
ARCH    ?= arm64
BUILD   ?= build

SDK_IOS := $(shell xcrun -sdk iphoneos --show-sdk-path 2>/dev/null)
CC_IOS  := $(shell xcrun -sdk iphoneos -f clang 2>/dev/null)
LDID    := $(shell command -v ldid 2>/dev/null)
SRC     := nxfixup.c ../rtpatch/jbmap.h

.PHONY: ios test clean

ios: $(SRC)
	@test -n "$(SDK_IOS)" || { echo "no iPhone SDK (need macOS + Xcode)"; exit 1; }
	@mkdir -p $(BUILD)
	$(CC_IOS) -arch $(ARCH) -isysroot $(SDK_IOS) -miphoneos-version-min=$(MIN_IOS) \
	    -O2 -Wall -Wextra nxfixup.c -o $(BUILD)/nxfixup
	@if [ -n "$(LDID)" ]; then $(LDID) -S $(BUILD)/nxfixup; fi

# Two host builds: the plain tool (no signer, as outside Nyxian) and one linked
# with a stand-in for Nyxian's signing call.
test: $(SRC) test/fake_signer.c
	@mkdir -p $(BUILD)
	$(CC) -O1 -g -Wall -Wextra nxfixup.c -o $(BUILD)/host-nxfixup -ldl
	$(CC) -O1 -g -Wall -Wextra -rdynamic nxfixup.c test/fake_signer.c -o $(BUILD)/host-nxfixup-signer -ldl
	python3 -I ../../scripts/test-relocate.py --tool "$(BUILD)/host-nxfixup --no-sign" \
	    --signing-tool "$(BUILD)/host-nxfixup-signer"

clean:
	rm -rf $(BUILD)
