#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const KCErrorDomain;

NS_SWIFT_NAME(CoreCSR)
@interface KCCSR : NSObject
@property (nonatomic, readonly, copy) NSString *privateKeyPEM;
@property (nonatomic, readonly, copy) NSString *csrPEM;
@end

NS_SWIFT_NAME(CoreIdentity)
@interface KCIdentity : NSObject
@property (nonatomic, readonly, copy) NSData *certificateDER;
@property (nonatomic, readonly, copy) NSArray<NSData *> *chainDER;
@property (nonatomic, readonly, copy) NSString *privateKeyPEM;
@end

NS_SWIFT_NAME(CoreCertificateInfo)
@interface KCCertificateInfo : NSObject
@property (nonatomic, readonly, copy) NSString *commonName;
@property (nonatomic, readonly, copy) NSString *organization;
@property (nonatomic, readonly, copy) NSString *organizationalUnit;
@property (nonatomic, readonly, copy) NSString *serialNumber;
@property (nonatomic, readonly, copy) NSString *sha1;
@property (nonatomic, readonly, copy) NSDate *notBefore;
@property (nonatomic, readonly, copy) NSDate *notAfter;
@end

NS_SWIFT_NAME(CoreSignOptions)
@interface KCSignOptions : NSObject
@property (nonatomic, copy) NSString *certificatePath;
@property (nonatomic, copy) NSString *privateKeyPath;
@property (nonatomic, copy) NSArray<NSString *> *profilePaths;
@property (nonatomic, copy, nullable) NSString *entitlementsPath;
@property (nonatomic, copy, nullable) NSString *bundleID;
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *bundleVersion;
@property (nonatomic, copy, nullable) NSString *minimumOSVersion;
@property (nonatomic, copy) NSArray<NSString *> *injectDylibPaths;
@property (nonatomic) BOOL weakInject;
@property (nonatomic) BOOL removeExtensions;
@property (nonatomic) BOOL removeWatchApp;
@property (nonatomic) BOOL removeUISupportedDevices;
@property (nonatomic) BOOL enableFileSharing;
@end

NS_SWIFT_NAME(Core)
@interface KCCore : NSObject

+ (nullable KCCSR *)generateCSRWithCommonName:(NSString *)commonName
                                        error:(NSError **)error
    NS_SWIFT_NAME(generateCSR(commonName:));

+ (nullable NSData *)pkcs12WithCertificate:(NSData *)certificate
                                     chain:(NSArray<NSData *> *)chain
                             privateKeyPEM:(NSString *)privateKeyPEM
                                  password:(NSString *)password
                              friendlyName:(NSString *)friendlyName
                                     error:(NSError **)error
    NS_SWIFT_NAME(makePKCS12(certificate:chain:privateKeyPEM:password:friendlyName:));

+ (nullable KCIdentity *)identityFromPKCS12:(NSData *)p12
                                   password:(NSString *)password
                                      error:(NSError **)error
    NS_SWIFT_NAME(identity(pkcs12:password:));

+ (nullable KCIdentity *)identityFromCertificate:(NSData *)certificate
                                      privateKey:(NSData *)privateKey
                                        password:(NSString *)password
                                           error:(NSError **)error
    NS_SWIFT_NAME(identity(certificate:privateKey:password:));

+ (nullable KCCertificateInfo *)certificateInfo:(NSData *)certificate
                                          error:(NSError **)error
    NS_SWIFT_NAME(certificateInfo(_:));

+ (nullable NSData *)decodeCMS:(NSData *)cms error:(NSError **)error
    NS_SWIFT_NAME(decodeCMS(_:));

+ (BOOL)extractZipAtPath:(NSString *)zipPath toFolder:(NSString *)folder error:(NSError **)error
    NS_SWIFT_NAME(extractZip(at:to:));

+ (BOOL)archiveFolder:(NSString *)folder toZipAtPath:(NSString *)zipPath
     compressionLevel:(NSInteger)level error:(NSError **)error
    NS_SWIFT_NAME(archive(folder:to:level:));

+ (nullable NSArray<NSString *> *)entriesInZipAtPath:(NSString *)zipPath error:(NSError **)error
    NS_SWIFT_NAME(zipEntries(at:));

+ (nullable NSData *)readEntry:(NSString *)entry inZipAtPath:(NSString *)zipPath
                       maxSize:(NSUInteger)maxSize error:(NSError **)error
    NS_SWIFT_NAME(readZipEntry(_:at:maxSize:));

/// Signs the .app inside `folder` in place. Returns the signed .app path.
+ (nullable NSString *)signFolder:(NSString *)folder
                          options:(KCSignOptions *)options
                              log:(nullable void (^)(NSInteger level, NSString *line))log
                            error:(NSError **)error
    NS_SWIFT_NAME(sign(folder:options:log:));

@end

NS_ASSUME_NONNULL_END
