#import "KilnCore.h"

#include "kiln_core.h"

NSErrorDomain const KCErrorDomain = @"KilnCore";

static std::string Str(NSString *s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }
static std::string Bytes(NSData *d) { return d ? std::string((const char *)d.bytes, d.length) : std::string(); }
static NSString *NS(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
static NSData *Data(const std::string &s) { return [NSData dataWithBytes:s.data() length:s.size()]; }

static BOOL Fail(NSError **error, const std::string &message) {
    if (error) {
        *error = [NSError errorWithDomain:KCErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: NS(message)}];
    }
    return NO;
}

@interface KCCSR ()
@property (nonatomic, readwrite, copy) NSString *privateKeyPEM;
@property (nonatomic, readwrite, copy) NSString *csrPEM;
@end
@implementation KCCSR
@end

@interface KCIdentity ()
@property (nonatomic, readwrite, copy) NSData *certificateDER;
@property (nonatomic, readwrite, copy) NSArray<NSData *> *chainDER;
@property (nonatomic, readwrite, copy) NSString *privateKeyPEM;
+ (instancetype)fromCore:(const kiln::Identity &)identity;
@end
@implementation KCIdentity
+ (instancetype)fromCore:(const kiln::Identity &)identity {
    KCIdentity *result = [KCIdentity new];
    result.certificateDER = Data(identity.certificateDER);
    NSMutableArray *chain = [NSMutableArray array];
    for (const std::string &der : identity.chainDER) [chain addObject:Data(der)];
    result.chainDER = chain;
    result.privateKeyPEM = NS(identity.privateKeyPEM);
    return result;
}
@end

@interface KCCertificateInfo ()
@property (nonatomic, readwrite, copy) NSString *commonName;
@property (nonatomic, readwrite, copy) NSString *organization;
@property (nonatomic, readwrite, copy) NSString *organizationalUnit;
@property (nonatomic, readwrite, copy) NSString *serialNumber;
@property (nonatomic, readwrite, copy) NSString *sha1;
@property (nonatomic, readwrite, copy) NSDate *notBefore;
@property (nonatomic, readwrite, copy) NSDate *notAfter;
@end
@implementation KCCertificateInfo
@end

@implementation KCSignOptions
- (instancetype)init {
    if ((self = [super init])) {
        _certificatePath = @"";
        _privateKeyPath = @"";
        _profilePaths = @[];
        _injectDylibPaths = @[];
    }
    return self;
}
@end

@implementation KCCore

+ (KCCSR *)generateCSRWithCommonName:(NSString *)commonName error:(NSError **)error {
    std::string key, csr, message;
    if (!kiln::GenerateCSR(Str(commonName), key, csr, message)) {
        Fail(error, message);
        return nil;
    }
    KCCSR *result = [KCCSR new];
    result.privateKeyPEM = NS(key);
    result.csrPEM = NS(csr);
    return result;
}

+ (NSData *)pkcs12WithCertificate:(NSData *)certificate
                            chain:(NSArray<NSData *> *)chain
                    privateKeyPEM:(NSString *)privateKeyPEM
                         password:(NSString *)password
                     friendlyName:(NSString *)friendlyName
                            error:(NSError **)error {
    std::vector<std::string> extra;
    for (NSData *d in chain) extra.push_back(Bytes(d));
    std::string p12, message;
    if (!kiln::MakePKCS12(Bytes(certificate), extra, Str(privateKeyPEM), Str(password),
                          Str(friendlyName), p12, message)) {
        Fail(error, message);
        return nil;
    }
    return Data(p12);
}

+ (KCIdentity *)identityFromPKCS12:(NSData *)p12 password:(NSString *)password error:(NSError **)error {
    kiln::Identity identity;
    std::string message;
    if (!kiln::ParsePKCS12(Bytes(p12), Str(password), identity, message)) {
        Fail(error, message);
        return nil;
    }
    return [KCIdentity fromCore:identity];
}

+ (KCIdentity *)identityFromCertificate:(NSData *)certificate
                             privateKey:(NSData *)privateKey
                               password:(NSString *)password
                                  error:(NSError **)error {
    kiln::Identity identity;
    std::string message;
    if (!kiln::ParseCertificateAndKey(Bytes(certificate), Bytes(privateKey), Str(password), identity, message)) {
        Fail(error, message);
        return nil;
    }
    return [KCIdentity fromCore:identity];
}

+ (KCCertificateInfo *)certificateInfo:(NSData *)certificate error:(NSError **)error {
    kiln::CertificateInfo info;
    std::string message;
    if (!kiln::GetCertificateInfo(Bytes(certificate), info, message)) {
        Fail(error, message);
        return nil;
    }
    KCCertificateInfo *result = [KCCertificateInfo new];
    result.commonName = NS(info.commonName);
    result.organization = NS(info.organization);
    result.organizationalUnit = NS(info.organizationalUnit);
    result.serialNumber = NS(info.serialHex);
    result.sha1 = NS(info.sha1Hex);
    result.notBefore = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.notBefore];
    result.notAfter = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.notAfter];
    return result;
}

+ (NSData *)decodeCMS:(NSData *)cms error:(NSError **)error {
    std::string content, message;
    if (!kiln::DecodeCMS(Bytes(cms), content, message)) {
        Fail(error, message);
        return nil;
    }
    return Data(content);
}

+ (BOOL)extractZipAtPath:(NSString *)zipPath toFolder:(NSString *)folder error:(NSError **)error {
    std::string message;
    return kiln::ExtractZip(Str(zipPath), Str(folder), message) ? YES : Fail(error, message);
}

+ (BOOL)archiveFolder:(NSString *)folder toZipAtPath:(NSString *)zipPath
     compressionLevel:(NSInteger)level error:(NSError **)error {
    std::string message;
    return kiln::ArchiveFolder(Str(folder), Str(zipPath), (int)level, message) ? YES : Fail(error, message);
}

+ (NSArray<NSString *> *)entriesInZipAtPath:(NSString *)zipPath error:(NSError **)error {
    std::vector<std::string> entries;
    std::string message;
    if (!kiln::ListZipEntries(Str(zipPath), entries, message)) {
        Fail(error, message);
        return nil;
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:entries.size()];
    for (const std::string &e : entries) [result addObject:NS(e)];
    return result;
}

+ (NSData *)readEntry:(NSString *)entry inZipAtPath:(NSString *)zipPath
              maxSize:(NSUInteger)maxSize error:(NSError **)error {
    std::string data, message;
    if (!kiln::ReadZipEntry(Str(zipPath), Str(entry), data, maxSize, message)) {
        Fail(error, message);
        return nil;
    }
    return Data(data);
}

+ (NSString *)signFolder:(NSString *)folder
                 options:(KCSignOptions *)options
                     log:(void (^)(NSInteger, NSString *))log
                   error:(NSError **)error {
    kiln::SignOptions o;
    o.certificatePath = Str(options.certificatePath);
    o.privateKeyPath = Str(options.privateKeyPath);
    for (NSString *p in options.profilePaths) o.profilePaths.push_back(Str(p));
    o.entitlementsPath = Str(options.entitlementsPath);
    o.bundleID = Str(options.bundleID);
    o.displayName = Str(options.displayName);
    o.bundleVersion = Str(options.bundleVersion);
    o.minimumOSVersion = Str(options.minimumOSVersion);
    for (NSString *p in options.injectDylibPaths) o.injectDylibs.push_back(Str(p));
    o.weakInject = options.weakInject;
    o.removeExtensions = options.removeExtensions;
    o.removeWatchApp = options.removeWatchApp;
    o.removeUISupportedDevices = options.removeUISupportedDevices;
    o.enableFileSharing = options.enableFileSharing;

    kiln::LogCallback callback;
    if (log) {
        callback = [log](int level, const std::string &line) { log(level, NS(line)); };
    }
    std::string appFolder, message;
    if (!kiln::SignFolder(Str(folder), o, callback, appFolder, message)) {
        Fail(error, message);
        return nil;
    }
    return NS(appFolder);
}

@end
