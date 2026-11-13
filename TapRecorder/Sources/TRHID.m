#import "TRHID.h"
#include <dlfcn.h>

TRHIDFuncs TRHID;

#define TR_LOAD(field, sym) do { \
    *(void **)(&TRHID.field) = dlsym(h, sym); \
    if (!TRHID.field) { NSLog(@"[TapRecorder] missing symbol %s", sym); ok = NO; } \
} while (0)

BOOL TRHIDLoad(void) {
    static BOOL loaded = NO, result = NO;
    if (loaded) return result;
    loaded = YES;

    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) {
        NSLog(@"[TapRecorder] dlopen IOKit failed: %s", dlerror());
        return NO;
    }
    BOOL ok = YES;
    TR_LOAD(ClientCreate,           "IOHIDEventSystemClientCreate");
    TR_LOAD(ClientSchedule,         "IOHIDEventSystemClientScheduleWithRunLoop");
    TR_LOAD(ClientRegisterCallback, "IOHIDEventSystemClientRegisterEventCallback");
    TR_LOAD(ClientDispatch,         "IOHIDEventSystemClientDispatchEvent");
    TR_LOAD(GetType,                "IOHIDEventGetType");
    TR_LOAD(GetChildren,            "IOHIDEventGetChildren");
    TR_LOAD(GetInteger,             "IOHIDEventGetIntegerValue");
    TR_LOAD(GetFloat,               "IOHIDEventGetFloatValue");
    TR_LOAD(SetInteger,             "IOHIDEventSetIntegerValue");
    TR_LOAD(SetFloat,               "IOHIDEventSetFloatValue");
    TR_LOAD(GetTimeStamp,           "IOHIDEventGetTimeStamp");
    TR_LOAD(GetSenderID,            "IOHIDEventGetSenderID");
    TR_LOAD(SetSenderID,            "IOHIDEventSetSenderID");
    TR_LOAD(CreateDigitizer,        "IOHIDEventCreateDigitizerEvent");
    TR_LOAD(CreateFinger,           "IOHIDEventCreateDigitizerFingerEvent");
    TR_LOAD(AppendEvent,            "IOHIDEventAppendEvent");
    // Optional: monitor-type client.
    *(void **)(&TRHID.ClientCreateWithType) = dlsym(h, "IOHIDEventSystemClientCreateWithType");

    *(void **)(&TRHID.ClientSetDispatchQueue) = dlsym(h, "IOHIDEventSystemClientSetDispatchQueue");
    *(void **)(&TRHID.ClientActivate) = dlsym(h, "IOHIDEventSystemClientActivate");
    *(void **)(&TRHID.ClientCancel) = dlsym(h, "IOHIDEventSystemClientCancel");
    *(void **)(&TRHID.ClientUnschedule) = dlsym(h, "IOHIDEventSystemClientUnscheduleWithRunLoop");

    result = ok;
    return ok;
}
