// nxcontrol.h - the wire protocol between nxlaunchctl and nxlaunchd.
//
// A request and a reply are each one property-list dictionary, serialized as a
// binary plist and framed with a 4-byte big-endian length prefix, over an
// AF_UNIX stream socket. Keep it boring and synchronous: one request, one reply.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Default control socket. Overridable with the LAUNCHD_SOCKET environment
// variable so a user session can run its own instance.
#ifndef NX_PREFIX
#define NX_PREFIX "/var/jb"
#endif
#define NX_DEFAULT_SOCKET  NX_PREFIX "/var/run/nxlaunchd.sock"

// Request keys
extern NSString *const NXReqOp;     // NSString, one of the ops below
extern NSString *const NXReqArgs;   // NSArray<NSString*>, positional arguments
extern NSString *const NXReqFlags;  // NSDictionary, option -> value

// Reply keys
extern NSString *const NXRepOK;     // NSNumber(bool)
extern NSString *const NXRepText;   // NSString, printed to stdout
extern NSString *const NXRepCode;   // NSNumber(int), process exit code for launchctl

// Operations (mirror the launchctl verbs)
extern NSString *const NXOpLoad;      // args: plist paths (or dirs)
extern NSString *const NXOpUnload;    // args: plist paths or labels
extern NSString *const NXOpStart;     // args: labels
extern NSString *const NXOpStop;      // args: labels
extern NSString *const NXOpKickstart; // args: labels; flags: {"kill": bool}
extern NSString *const NXOpList;      // args: optional label filter
extern NSString *const NXOpPrint;     // args: label
extern NSString *const NXOpEnable;    // args: labels
extern NSString *const NXOpDisable;   // args: labels
extern NSString *const NXOpBootstrap; // args: plist paths (alias of load)
extern NSString *const NXOpBootout;   // args: plist paths or labels (alias of unload)

// Framed read/write. Return NO on EOF or error. Thread-agnostic, blocking.
BOOL NXWriteMessage(int fd, NSDictionary *message);
NSDictionary * _Nullable NXReadMessage(int fd);

NS_ASSUME_NONNULL_END
