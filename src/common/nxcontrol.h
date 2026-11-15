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

// Where NX_PREFIX really is. On a jailbroken device that is NX_PREFIX itself (or
// what it links to). Inside Nyxian there is no real /var/jb: the path layer
// (src/rtpatch) answers realpath() with the directory in the app container.
NSString *NXPrefix(void);

// `path` with a leading NX_PREFIX replaced by NXPrefix(). Use it for every path
// handed to Foundation, which may not go through the path layer.
NSString *NXRealPath(NSString *path);

// A listening / connected AF_UNIX stream socket at `path`, or -1 with errno
// set. Works for paths longer than sockaddr_un allows (an app container path
// is) by binding from inside the socket's directory.
int NXSocketListen(NSString *path);
int NXSocketConnect(NSString *path);

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
