// nxcontrol.m - see nxcontrol.h.

#import "nxcontrol.h"
#import <unistd.h>
#import <errno.h>

NSString *const NXReqOp    = @"op";
NSString *const NXReqArgs  = @"args";
NSString *const NXReqFlags = @"flags";

NSString *const NXRepOK    = @"ok";
NSString *const NXRepText  = @"text";
NSString *const NXRepCode  = @"code";

NSString *const NXOpLoad      = @"load";
NSString *const NXOpUnload    = @"unload";
NSString *const NXOpStart     = @"start";
NSString *const NXOpStop      = @"stop";
NSString *const NXOpKickstart = @"kickstart";
NSString *const NXOpList      = @"list";
NSString *const NXOpPrint     = @"print";
NSString *const NXOpEnable    = @"enable";
NSString *const NXOpDisable   = @"disable";
NSString *const NXOpBootstrap = @"bootstrap";
NSString *const NXOpBootout   = @"bootout";

static BOOL writeAll(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;
        p += n; len -= (size_t)n;
    }
    return YES;
}

static BOOL readAll(int fd, void *buf, size_t len)
{
    uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;  // EOF
        p += n; len -= (size_t)n;
    }
    return YES;
}

BOOL NXWriteMessage(int fd, NSDictionary *message)
{
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:message
                        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
    if (!data) return NO;
    if (data.length > (1u << 24)) return NO;  // 16 MiB sanity cap
    uint32_t len = (uint32_t)data.length;
    uint8_t hdr[4] = { len >> 24, len >> 16, len >> 8, len };
    if (!writeAll(fd, hdr, 4)) return NO;
    return writeAll(fd, data.bytes, data.length);
}

NSDictionary *NXReadMessage(int fd)
{
    uint8_t hdr[4];
    if (!readAll(fd, hdr, 4)) return nil;
    uint32_t len = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                   ((uint32_t)hdr[2] << 8)  |  (uint32_t)hdr[3];
    if (len == 0 || len > (1u << 24)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:len];
    if (!readAll(fd, data.mutableBytes, len)) return nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                        options:NSPropertyListImmutable format:NULL error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}
