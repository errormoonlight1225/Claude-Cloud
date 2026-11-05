#!/bin/bash
# Syntax-check Objective-C and C sources for iOS 12: every unguarded use of
# an API newer than iOS 12 is an error. Usage: objc_check.sh DIR [-I...]
# CLANG and SDK default to the Linux setup typecheck.py documents.
set -u
CLANG="${CLANG:-/opt/ios/swift-6.3.3-RELEASE-ubuntu24.04/usr/bin/clang}"
SDK="${SDK:-/opt/ios/xsdks/iPhoneOS26.5.sdk}"
dir="$1"; shift
status=0
while IFS= read -r -d '' f; do
    out=$("$CLANG" -fsyntax-only -target arm64e-apple-ios12.0 -isysroot "$SDK" -fobjc-arc -fmodules \
        -fmodules-cache-path=/opt/ios/clangcache -I"$(dirname "$f")" "$@" \
        -Werror=unguarded-availability-new -Werror=unguarded-availability "$f" 2>&1 | grep -E "error:")
    if [ -n "$out" ]; then echo "== $f"; echo "$out"; status=1; fi
done < <(find "$dir" \( -name '*.m' -o -name '*.c' -o -name '*.mm' \) -print0)
exit $status
