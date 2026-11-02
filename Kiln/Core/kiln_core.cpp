#include "kiln_core.h"

#include <cstring>
#include <ctime>
#include <memory>
#include <mutex>

#include <openssl/bio.h>
#include <openssl/cms.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include "archive.h"
#include "bundle.h"
#include "fs.h"
#include "log.h"
#include "openssl.h"
#include "third-party/minizip/unzip.h"

namespace kiln {
namespace {

// MARK: RAII helpers

struct BIODeleter { void operator()(BIO* p) const { BIO_free_all(p); } };
struct PKeyDeleter { void operator()(EVP_PKEY* p) const { EVP_PKEY_free(p); } };
struct X509Deleter { void operator()(X509* p) const { X509_free(p); } };
struct ReqDeleter { void operator()(X509_REQ* p) const { X509_REQ_free(p); } };
struct P12Deleter { void operator()(PKCS12* p) const { PKCS12_free(p); } };
struct CMSDeleter { void operator()(CMS_ContentInfo* p) const { CMS_ContentInfo_free(p); } };
struct PKeyCtxDeleter { void operator()(EVP_PKEY_CTX* p) const { EVP_PKEY_CTX_free(p); } };
struct X509StackDeleter { void operator()(STACK_OF(X509)* p) const { sk_X509_pop_free(p, X509_free); } };

using BIOPtr = std::unique_ptr<BIO, BIODeleter>;
using PKeyPtr = std::unique_ptr<EVP_PKEY, PKeyDeleter>;
using X509Ptr = std::unique_ptr<X509, X509Deleter>;
using X509StackPtr = std::unique_ptr<STACK_OF(X509), X509StackDeleter>;

std::string OpenSSLError(const std::string& prefix) {
    std::string message = prefix;
    unsigned long code;
    bool first = true;
    while ((code = ERR_get_error()) != 0) {
        char buf[256];
        ERR_error_string_n(code, buf, sizeof(buf));
        message += first ? ": " : "; ";
        message += buf;
        first = false;
    }
    return message;
}

BIOPtr MemBIO(const std::string& data) {
    return BIOPtr(BIO_new_mem_buf(data.data(), static_cast<int>(data.size())));
}

std::string BIOString(BIO* bio) {
    char* ptr = nullptr;
    long len = BIO_get_mem_data(bio, &ptr);
    return (len > 0 && ptr) ? std::string(ptr, static_cast<size_t>(len)) : std::string();
}

bool LooksLikePEM(const std::string& data) {
    return data.find("-----BEGIN") != std::string::npos;
}

std::string ToDER(X509* cert) {
    int len = i2d_X509(cert, nullptr);
    if (len <= 0) return std::string();
    std::string der(static_cast<size_t>(len), '\0');
    unsigned char* p = reinterpret_cast<unsigned char*>(&der[0]);
    i2d_X509(cert, &p);
    return der;
}

std::string KeyToPEM(EVP_PKEY* key) {
    BIOPtr bio(BIO_new(BIO_s_mem()));
    if (!PEM_write_bio_PrivateKey(bio.get(), key, nullptr, nullptr, 0, nullptr, nullptr)) {
        return std::string();
    }
    return BIOString(bio.get());
}

// Parses every certificate in a PEM bundle, or a single DER cert.
bool ReadCertificates(const std::string& data, std::vector<X509Ptr>& out) {
    if (LooksLikePEM(data)) {
        BIOPtr bio = MemBIO(data);
        while (X509* cert = PEM_read_bio_X509(bio.get(), nullptr, nullptr, nullptr)) {
            out.emplace_back(cert);
        }
        ERR_clear_error();  // reading past the last cert sets an EOF error
    } else {
        const unsigned char* p = reinterpret_cast<const unsigned char*>(data.data());
        if (X509* cert = d2i_X509(nullptr, &p, static_cast<long>(data.size()))) {
            out.emplace_back(cert);
        }
    }
    return !out.empty();
}

int PasswordCallback(char* buf, int size, int, void* userdata) {
    const std::string* password = static_cast<const std::string*>(userdata);
    if (!password || password->empty()) return 0;
    int len = static_cast<int>(password->size());
    if (len > size) len = size;
    memcpy(buf, password->data(), static_cast<size_t>(len));
    return len;
}

PKeyPtr ReadPrivateKey(const std::string& data, const std::string& password) {
    BIOPtr bio = MemBIO(data);
    EVP_PKEY* key = nullptr;
    if (LooksLikePEM(data)) {
        key = PEM_read_bio_PrivateKey(bio.get(), nullptr, PasswordCallback,
                                      const_cast<std::string*>(&password));
    } else {
        key = d2i_PrivateKey_bio(bio.get(), nullptr);
    }
    return PKeyPtr(key);
}

std::string NameEntry(X509_NAME* name, int nid) {
    int index = X509_NAME_get_index_by_NID(name, nid, -1);
    if (index < 0) return std::string();
    ASN1_STRING* asn = X509_NAME_ENTRY_get_data(X509_NAME_get_entry(name, index));
    unsigned char* utf8 = nullptr;
    int len = ASN1_STRING_to_UTF8(&utf8, asn);
    if (len < 0) return std::string();
    std::string value(reinterpret_cast<char*>(utf8), static_cast<size_t>(len));
    OPENSSL_free(utf8);
    return value;
}

long long ASN1TimeToUnix(const ASN1_TIME* time) {
    struct tm tm;
    memset(&tm, 0, sizeof(tm));
    if (!ASN1_TIME_to_tm(time, &tm)) return 0;
#if defined(_WIN32)
    return static_cast<long long>(_mkgmtime(&tm));
#else
    return static_cast<long long>(timegm(&tm));
#endif
}

std::string Hex(const unsigned char* bytes, size_t len) {
    static const char* digits = "0123456789ABCDEF";
    std::string out;
    out.reserve(len * 2);
    for (size_t i = 0; i < len; i++) {
        out.push_back(digits[bytes[i] >> 4]);
        out.push_back(digits[bytes[i] & 0x0F]);
    }
    return out;
}

// zsign logs through a process-wide hook; serialise signing and route its output.
std::mutex g_signMutex;

struct LogContext {
    const LogCallback* callback;
    std::vector<std::string> errors;
};

void ZLogHook(void* ctx, int level, const char* line) {
    LogContext* context = static_cast<LogContext*>(ctx);
    std::string text(line ? line : "");
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
    if (text.empty()) return;
    if (level == ZLog::E_ERROR) context->errors.push_back(text);
    if (context->callback && *context->callback) (*context->callback)(level, text);
}

std::string JoinErrors(const std::vector<std::string>& errors, const std::string& fallback) {
    if (errors.empty()) return fallback;
    std::string out;
    for (const std::string& e : errors) {
        std::string line = e;
        size_t start = line.find_first_not_of(">\t ");
        if (start != std::string::npos) line = line.substr(start);
        if (!out.empty()) out += "\n";
        out += line;
    }
    return out;
}

}  // namespace

// MARK: - Keys, CSRs and certificates

bool GenerateCSR(const std::string& commonName, std::string& privateKeyPEM, std::string& csrPEM,
                 std::string& error) {
    ERR_clear_error();
    std::unique_ptr<EVP_PKEY_CTX, PKeyCtxDeleter> ctx(EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr));
    EVP_PKEY* rawKey = nullptr;
    if (!ctx || EVP_PKEY_keygen_init(ctx.get()) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(ctx.get(), 2048) <= 0 ||
        EVP_PKEY_keygen(ctx.get(), &rawKey) <= 0) {
        error = OpenSSLError("RSA key generation failed");
        return false;
    }
    PKeyPtr key(rawKey);

    std::unique_ptr<X509_REQ, ReqDeleter> req(X509_REQ_new());
    X509_NAME* name = X509_REQ_get_subject_name(req.get());
    const std::string cn = commonName.empty() ? std::string("Kiln") : commonName;
    if (!X509_REQ_set_version(req.get(), 0) ||
        !X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_UTF8,
                                    reinterpret_cast<const unsigned char*>(cn.c_str()), -1, -1, 0) ||
        !X509_NAME_add_entry_by_txt(name, "C", MBSTRING_ASC,
                                    reinterpret_cast<const unsigned char*>("US"), -1, -1, 0) ||
        !X509_REQ_set_pubkey(req.get(), key.get()) ||
        X509_REQ_sign(req.get(), key.get(), EVP_sha256()) <= 0) {
        error = OpenSSLError("CSR creation failed");
        return false;
    }

    BIOPtr bio(BIO_new(BIO_s_mem()));
    if (!PEM_write_bio_X509_REQ(bio.get(), req.get())) {
        error = OpenSSLError("CSR encoding failed");
        return false;
    }
    csrPEM = BIOString(bio.get());
    privateKeyPEM = KeyToPEM(key.get());
    if (csrPEM.empty() || privateKeyPEM.empty()) {
        error = OpenSSLError("PEM encoding failed");
        return false;
    }
    return true;
}

bool MakePKCS12(const std::string& certificate, const std::vector<std::string>& chain,
                const std::string& privateKeyPEM, const std::string& password,
                const std::string& friendlyName, std::string& p12Out, std::string& error) {
    ERR_clear_error();
    std::vector<X509Ptr> certs;
    if (!ReadCertificates(certificate, certs)) {
        error = OpenSSLError("Invalid certificate");
        return false;
    }
    PKeyPtr key = ReadPrivateKey(privateKeyPEM, std::string());
    if (!key) {
        error = OpenSSLError("Invalid private key");
        return false;
    }
    if (X509_check_private_key(certs[0].get(), key.get()) != 1) {
        error = "The private key does not match the certificate";
        return false;
    }

    X509StackPtr ca(sk_X509_new_null());
    for (size_t i = 1; i < certs.size(); i++) {
        sk_X509_push(ca.get(), X509_dup(certs[i].get()));
    }
    for (const std::string& extra : chain) {
        std::vector<X509Ptr> extras;
        if (ReadCertificates(extra, extras)) {
            for (X509Ptr& c : extras) sk_X509_push(ca.get(), c.release());
        }
    }

    const int legacy = NID_pbe_WithSHA1And3_Key_TripleDES_CBC;
    std::unique_ptr<PKCS12, P12Deleter> p12(
        PKCS12_create(password.c_str(), friendlyName.empty() ? nullptr : friendlyName.c_str(),
                      key.get(), certs[0].get(), sk_X509_num(ca.get()) > 0 ? ca.get() : nullptr,
                      legacy, legacy, PKCS12_DEFAULT_ITER, -1, 0));
    if (!p12 || !PKCS12_set_mac(p12.get(), password.c_str(), -1, nullptr, 0,
                                PKCS12_DEFAULT_ITER, EVP_sha1())) {
        error = OpenSSLError("PKCS#12 creation failed");
        return false;
    }

    BIOPtr bio(BIO_new(BIO_s_mem()));
    if (!i2d_PKCS12_bio(bio.get(), p12.get())) {
        error = OpenSSLError("PKCS#12 encoding failed");
        return false;
    }
    p12Out = BIOString(bio.get());
    return !p12Out.empty();
}

bool ParsePKCS12(const std::string& p12Data, const std::string& password, Identity& out,
                 std::string& error) {
    ERR_clear_error();
    BIOPtr bio = MemBIO(p12Data);
    std::unique_ptr<PKCS12, P12Deleter> p12(d2i_PKCS12_bio(bio.get(), nullptr));
    if (!p12) {
        error = OpenSSLError("Not a valid .p12 file");
        return false;
    }
    EVP_PKEY* rawKey = nullptr;
    X509* rawCert = nullptr;
    STACK_OF(X509)* rawCA = nullptr;
    if (!PKCS12_parse(p12.get(), password.c_str(), &rawKey, &rawCert, &rawCA)) {
        error = OpenSSLError("Wrong password or unsupported .p12 encryption");
        return false;
    }
    PKeyPtr key(rawKey);
    X509Ptr cert(rawCert);
    X509StackPtr ca(rawCA);
    if (!key || !cert) {
        error = "The .p12 must contain both a certificate and its private key";
        return false;
    }
    out.certificateDER = ToDER(cert.get());
    out.privateKeyPEM = KeyToPEM(key.get());
    out.chainDER.clear();
    if (ca) {
        for (int i = 0; i < sk_X509_num(ca.get()); i++) {
            out.chainDER.push_back(ToDER(sk_X509_value(ca.get(), i)));
        }
    }
    return true;
}

bool ParseCertificateAndKey(const std::string& certificate, const std::string& privateKey,
                            const std::string& password, Identity& out, std::string& error) {
    ERR_clear_error();
    std::vector<X509Ptr> certs;
    if (!ReadCertificates(certificate, certs)) {
        error = OpenSSLError("Invalid certificate file");
        return false;
    }
    PKeyPtr key = ReadPrivateKey(privateKey, password);
    if (!key) {
        error = OpenSSLError("Invalid private key file (or wrong password)");
        return false;
    }
    // Leaf = whichever cert matches the key; the rest is the chain.
    size_t leaf = certs.size();
    for (size_t i = 0; i < certs.size(); i++) {
        if (X509_check_private_key(certs[i].get(), key.get()) == 1) {
            leaf = i;
            break;
        }
    }
    ERR_clear_error();
    if (leaf == certs.size()) {
        error = "The private key does not match any certificate in the file";
        return false;
    }
    out.certificateDER = ToDER(certs[leaf].get());
    out.privateKeyPEM = KeyToPEM(key.get());
    out.chainDER.clear();
    for (size_t i = 0; i < certs.size(); i++) {
        if (i != leaf) out.chainDER.push_back(ToDER(certs[i].get()));
    }
    return true;
}

bool GetCertificateInfo(const std::string& certificate, CertificateInfo& out, std::string& error) {
    ERR_clear_error();
    std::vector<X509Ptr> certs;
    if (!ReadCertificates(certificate, certs)) {
        error = OpenSSLError("Invalid certificate");
        return false;
    }
    X509* cert = certs[0].get();
    X509_NAME* subject = X509_get_subject_name(cert);
    out.commonName = NameEntry(subject, NID_commonName);
    out.organization = NameEntry(subject, NID_organizationName);
    out.organizationalUnit = NameEntry(subject, NID_organizationalUnitName);
    out.notBefore = ASN1TimeToUnix(X509_get0_notBefore(cert));
    out.notAfter = ASN1TimeToUnix(X509_get0_notAfter(cert));

    const ASN1_INTEGER* serial = X509_get0_serialNumber(cert);
    out.serialHex = Hex(serial->data, static_cast<size_t>(serial->length));

    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int len = 0;
    if (X509_digest(cert, EVP_sha1(), digest, &len)) out.sha1Hex = Hex(digest, len);
    return true;
}

bool DecodeCMS(const std::string& cms, std::string& content, std::string& error) {
    ERR_clear_error();
    BIOPtr in = MemBIO(cms);
    std::unique_ptr<CMS_ContentInfo, CMSDeleter> info(d2i_CMS_bio(in.get(), nullptr));
    if (!info) {
        error = OpenSSLError("Not a valid signed profile");
        return false;
    }
    ASN1_OCTET_STRING** pos = CMS_get0_content(info.get());
    if (!pos || !*pos) {
        error = "The profile has no embedded content";
        return false;
    }
    content.assign(reinterpret_cast<const char*>(ASN1_STRING_get0_data(*pos)),
                   static_cast<size_t>(ASN1_STRING_length(*pos)));
    return true;
}

// MARK: - Zip

bool ExtractZip(const std::string& zipPath, const std::string& folder, std::string& error) {
    if (!ZFile::CreateFolder(folder.c_str()) || !Zip::Extract(zipPath.c_str(), folder.c_str())) {
        error = "Failed to unzip " + zipPath;
        return false;
    }
    return true;
}

bool ArchiveFolder(const std::string& folder, const std::string& zipPath, int level, std::string& error) {
    if (!Zip::Archive(folder, zipPath, level)) {
        error = "Failed to create " + zipPath;
        return false;
    }
    return true;
}

bool ListZipEntries(const std::string& zipPath, std::vector<std::string>& entries, std::string& error) {
    unzFile zf = unzOpen64(zipPath.c_str());
    if (!zf) {
        error = "Not a valid zip/ipa file";
        return false;
    }
    int rc = unzGoToFirstFile(zf);
    while (rc == UNZ_OK) {
        char name[4096];
        unz_file_info64 info;
        if (unzGetCurrentFileInfo64(zf, &info, name, sizeof(name), nullptr, 0, nullptr, 0) == UNZ_OK) {
            entries.emplace_back(name);
        }
        rc = unzGoToNextFile(zf);
    }
    unzClose(zf);
    return true;
}

bool ReadZipEntry(const std::string& zipPath, const std::string& entry, std::string& data,
                  size_t maxSize, std::string& error) {
    unzFile zf = unzOpen64(zipPath.c_str());
    if (!zf) {
        error = "Not a valid zip/ipa file";
        return false;
    }
    bool ok = false;
    unz_file_info64 info;
    if (unzLocateFile(zf, entry.c_str(), 1) != UNZ_OK) {
        error = "Entry not found: " + entry;
    } else if (unzGetCurrentFileInfo64(zf, &info, nullptr, 0, nullptr, 0, nullptr, 0) != UNZ_OK) {
        error = "Failed to read entry info";
    } else if (maxSize > 0 && info.uncompressed_size > maxSize) {
        error = "Entry too large: " + entry;
    } else if (unzOpenCurrentFile(zf) != UNZ_OK) {
        error = "Failed to open entry";
    } else {
        data.clear();
        data.reserve(static_cast<size_t>(info.uncompressed_size));
        char buf[64 * 1024];
        int n;
        while ((n = unzReadCurrentFile(zf, buf, sizeof(buf))) > 0) {
            data.append(buf, static_cast<size_t>(n));
            if (maxSize > 0 && data.size() > maxSize) break;
        }
        ok = (n == 0);
        if (!ok) error = "Failed to decompress entry";
        unzCloseCurrentFile(zf);
    }
    unzClose(zf);
    return ok;
}

// MARK: - Signing

bool SignFolder(const std::string& folder, const SignOptions& o, const LogCallback& log,
                std::string& appFolderOut, std::string& error) {
    std::lock_guard<std::mutex> lock(g_signMutex);
    LogContext context{&log, {}};
    ZLog::SetLogHook(ZLogHook, &context);
    ZLog::SetLogLever(ZLog::E_INFO);
    struct HookReset { ~HookReset() { ZLog::SetLogHook(nullptr, nullptr); } } reset;

    if (o.profilePaths.empty()) {
        error = "A provisioning profile is required";
        return false;
    }

    std::list<ZSignAsset> assets;
    for (const std::string& profile : o.profilePaths) {
        assets.emplace_back();
        if (!assets.back().Init(o.certificatePath, o.privateKeyPath, profile, o.entitlementsPath,
                                o.privateKeyPassword, false, o.sha256Only, false)) {
            error = JoinErrors(context.errors, "Failed to load certificate / profile: " + profile);
            return false;
        }
    }

    ZBundle bundle;
    bundle.m_bEnableDocuments = o.enableFileSharing;
    bundle.m_strMinVersion = o.minimumOSVersion;
    bundle.m_bRemoveExtensions = o.removeExtensions;
    bundle.m_bRemoveWatchApp = o.removeWatchApp;
    bundle.m_bRemoveUISupportedDevices = o.removeUISupportedDevices;

    std::vector<std::string> removeDylibs;
    bool ok;
    if (assets.size() > 1) {
        ok = bundle.SignFolder(&assets, folder, o.bundleID, o.bundleVersion, o.displayName,
                               o.injectDylibs, removeDylibs, true, o.weakInject, false, false);
    } else {
        ok = bundle.SignFolder(&assets.front(), folder, o.bundleID, o.bundleVersion, o.displayName,
                               o.injectDylibs, removeDylibs, true, o.weakInject, false, false);
    }
    if (!ok) {
        error = JoinErrors(context.errors, "Signing failed");
        return false;
    }
    appFolderOut = bundle.m_strAppFolder;
    return true;
}

}  // namespace kiln
