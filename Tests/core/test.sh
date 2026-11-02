#!/usr/bin/env bash
# End-to-end test of kiln_core: CSR -> (fake Apple CA) cert -> p12 -> profile -> sign IPA.
set -eu
BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
cd "$W"
pass() { echo "  ok - $*"; }

echo "1. CSR generation"
"$BIN" csr "Kiln Test Key" key.pem csr.pem
openssl req -in csr.pem -noout -verify 2>&1 | grep -q "verify OK"
openssl req -in csr.pem -noout -text | grep -q "Signature Algorithm: sha256WithRSAEncryption"
openssl req -in csr.pem -noout -text | grep -q "Public-Key: (2048 bit)"
pass "RSA-2048 / SHA-256 CSR verifies"

echo "2. Fake Apple CA issues the certificate"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 -subj "/CN=Fake Apple WWDR/O=Fake" 2>/dev/null
openssl x509 -req -in csr.pem -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 \
  -subj "/UID=TEAM123456/CN=Apple Development: Kiln Tester (ABCDE12345)/OU=TEAM123456/O=Kiln Tester/C=US" \
  -outform DER -out cert.der 2>/dev/null
"$BIN" info cert.der > info.txt
grep -q "^ou=TEAM123456$" info.txt
grep -q "^cn=Apple Development: Kiln Tester (ABCDE12345)$" info.txt
pass "certificate info parsed ($(grep sha1 info.txt))"

echo "3. PKCS#12 export"
"$BIN" p12 cert.der key.pem "s3cret" out.p12
openssl pkcs12 -in out.p12 -passin pass:s3cret -info -noout > p12info.txt 2>&1
grep -q "MAC: sha1" p12info.txt
grep -q "pbeWithSHA1And3-KeyTripleDES-CBC" p12info.txt
openssl pkcs12 -in out.p12 -passin pass:s3cret -nodes -out p12dump.pem 2>/dev/null
grep -q "BEGIN PRIVATE KEY" p12dump.pem
if openssl pkcs12 -in out.p12 -passin pass:wrong -noout 2>/dev/null; then echo "wrong password accepted"; exit 1; fi
pass "legacy 3DES/SHA1 p12 readable by OpenSSL, wrong password rejected"

echo "4. PKCS#12 import round trip"
"$BIN" parsep12 out.p12 "s3cret" rt.der rt.key >/dev/null
cmp cert.der rt.der
if "$BIN" parsep12 out.p12 "nope" a b 2>/dev/null; then echo "parse with wrong password succeeded"; exit 1; fi
openssl x509 -inform DER -in cert.der -out cert.pem
cat ca.pem cert.pem > bundle.pem
"$BIN" pair bundle.pem key.pem "" | grep -q "chain=1"
pass "p12 + PEM bundle import (leaf detected among 2 certs)"

echo "5. Provisioning profile decode"
CERT_B64="$(base64 -w0 cert.der)"
cat > profile.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>AppIDName</key><string>Kiln Test</string>
<key>ApplicationIdentifierPrefix</key><array><string>TEAM123456</string></array>
<key>DeveloperCertificates</key><array><data>$CERT_B64</data></array>
<key>Entitlements</key><dict>
  <key>application-identifier</key><string>TEAM123456.com.kiln.test</string>
  <key>com.apple.developer.team-identifier</key><string>TEAM123456</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>TEAM123456.*</string></array>
</dict>
<key>ExpirationDate</key><date>2030-01-01T00:00:00Z</date>
<key>Name</key><string>Kiln Test Profile</string>
<key>TeamIdentifier</key><array><string>TEAM123456</string></array>
<key>TeamName</key><string>Kiln Tester</string>
<key>UUID</key><string>8F1D2B66-0000-4000-8000-000000000001</string>
</dict></plist>
PLIST
openssl cms -sign -nodetach -binary -outform DER -in profile.plist -signer ca.pem -inkey ca.key -out test.mobileprovision
"$BIN" cms test.mobileprovision | grep -q "TEAM123456.com.kiln.test"
pass "CMS profile payload extracted"

echo "6. IPA zip helpers"
mkdir -p src/Payload/Demo.app
cp "$HERE/fixtures/demo.dylib" src/Payload/Demo.app/Demo
# Pretend the arm64 dylib fixture is an app executable (mach_header.filetype = MH_EXECUTE).
python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[12:16]=(2).to_bytes(4,"little"); open(p,"wb").write(b)' src/Payload/Demo.app/Demo
cat > src/Payload/Demo.app/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Demo</string>
<key>CFBundleIdentifier</key><string>com.original.demo</string>
<key>CFBundleName</key><string>Demo</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
"$BIN" zip src demo.ipa
"$BIN" list demo.ipa | grep -q "^Payload/Demo.app/Info.plist$"
"$BIN" read demo.ipa Payload/Demo.app/Info.plist | grep -q com.original.demo
pass "ipa created, listed and entry read"

echo "7. Signing"
"$BIN" unzip demo.ipa work
"$BIN" sign work cert.der key.pem test.mobileprovision com.kiln.test > sign.log || { cat sign.log; exit 1; }
APP=work/Payload/Demo.app
test -f "$APP/embedded.mobileprovision"
test -f "$APP/_CodeSignature/CodeResources"
grep -q "com.kiln.test" "$APP/Info.plist"
grep -q "Kiln Test" "$APP/Info.plist"
python3 - "$APP/Demo" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
assert magic == 0xfeedfacf, hex(magic)
off = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, off)
    if cmd == 0x1d:  # LC_CODE_SIGNATURE
        dataoff, datasize = struct.unpack_from("<II", data, off + 8)
        sb_magic = struct.unpack_from(">I", data, dataoff)[0]
        assert sb_magic == 0xfade0cc0, hex(sb_magic)   # embedded signature superblob
        blob = data[dataoff:dataoff + datasize]
        assert b"TEAM123456.com.kiln.test" in blob, "entitlements missing"
        assert b"Apple Development: Kiln Tester" in blob or b"Kiln Tester" in blob, "CMS signer missing"
        print("  superblob size", datasize)
        break
    off += size
else:
    raise SystemExit("no LC_CODE_SIGNATURE")
PY
"$BIN" zip work signed.ipa
"$BIN" list signed.ipa | grep -q "Payload/Demo.app/_CodeSignature/CodeResources"
pass "app re-signed with new bundle id, entitlements and CMS signature"

echo "All core tests passed."
