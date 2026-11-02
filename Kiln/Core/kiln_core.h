// Kiln core: certificate handling and IPA signing on top of OpenSSL + zsign.
// Pure C++ (no Apple frameworks) so it can be unit-tested on Linux.
#pragma once

#include <functional>
#include <string>
#include <vector>

namespace kiln {

// MARK: - Keys, CSRs and certificates

// Generates an RSA-2048 key pair and a SHA-256 PKCS#10 CSR for Apple's certificate API.
bool GenerateCSR(const std::string& commonName,
                 std::string& privateKeyPEM,
                 std::string& csrPEM,
                 std::string& error);

struct Identity {
    std::string certificateDER;
    std::vector<std::string> chainDER;  // intermediates, leaf excluded
    std::string privateKeyPEM;          // unencrypted PKCS#8 PEM
};

// Builds a PKCS#12 using legacy 3DES / SHA-1 MAC so iOS, macOS Keychain and older
// signing tools can all read it. certificate may be DER or PEM.
bool MakePKCS12(const std::string& certificate,
                const std::vector<std::string>& chain,
                const std::string& privateKeyPEM,
                const std::string& password,
                const std::string& friendlyName,
                std::string& p12Out,
                std::string& error);

bool ParsePKCS12(const std::string& p12,
                 const std::string& password,
                 Identity& out,
                 std::string& error);

// certificate may be a PEM bundle (leaf first) or a single DER cert.
// privateKey may be PEM (optionally encrypted with password) or DER.
bool ParseCertificateAndKey(const std::string& certificate,
                            const std::string& privateKey,
                            const std::string& password,
                            Identity& out,
                            std::string& error);

struct CertificateInfo {
    std::string commonName;
    std::string organization;
    std::string organizationalUnit;  // Apple Team ID for signing certs
    std::string serialHex;
    std::string sha1Hex;
    long long notBefore = 0;  // unix seconds
    long long notAfter = 0;
};

bool GetCertificateInfo(const std::string& certificate, CertificateInfo& out, std::string& error);

// Extracts the signed payload of a CMS/PKCS#7 blob (e.g. a .mobileprovision -> plist XML).
bool DecodeCMS(const std::string& cms, std::string& content, std::string& error);

// MARK: - Zip

bool ExtractZip(const std::string& zipPath, const std::string& folder, std::string& error);
bool ArchiveFolder(const std::string& folder, const std::string& zipPath, int level, std::string& error);
bool ListZipEntries(const std::string& zipPath, std::vector<std::string>& entries, std::string& error);
bool ReadZipEntry(const std::string& zipPath, const std::string& entry, std::string& data,
                  size_t maxSize, std::string& error);

// MARK: - Signing

struct SignOptions {
    std::string certificatePath;           // DER or PEM
    std::string privateKeyPath;            // PEM/DER key or a .p12
    std::string privateKeyPassword;
    std::vector<std::string> profilePaths; // first = main app; extra = extensions (matched by bundle id)
    std::string entitlementsPath;          // optional; default = profile entitlements
    std::string bundleID;                  // optional rename
    std::string displayName;
    std::string bundleVersion;
    std::string minimumOSVersion;
    std::vector<std::string> injectDylibs;
    bool weakInject = false;
    bool removeExtensions = false;
    bool removeWatchApp = false;
    bool removeUISupportedDevices = false;
    bool enableFileSharing = false;
    bool sha256Only = false;
};

using LogCallback = std::function<void(int level, const std::string& line)>;

// Signs the .app found inside `folder` (a directory containing Payload/xxx.app) in place.
bool SignFolder(const std::string& folder,
                const SignOptions& options,
                const LogCallback& log,
                std::string& appFolderOut,
                std::string& error);

}  // namespace kiln
