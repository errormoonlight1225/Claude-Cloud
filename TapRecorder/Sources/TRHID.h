// Minimal private IOKit HID declarations.
// Symbols are resolved at runtime with dlsym so the tweak does not need
// IOKit headers or a .tbd at link time.
#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDService *IOHIDServiceRef;
typedef double IOHIDFloat;            // 64-bit
typedef uint32_t TRHIDEventField;

typedef void (*TRHIDEventCallback)(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event);

#define kTRHIDEventTypeDigitizer 11
#define TR_DIG_FIELD(n) ((TRHIDEventField)((kTRHIDEventTypeDigitizer << 16) | (n)))

enum {
    kTRDigX                 = TR_DIG_FIELD(0),
    kTRDigY                 = TR_DIG_FIELD(1),
    kTRDigZ                 = TR_DIG_FIELD(2),
    kTRDigButtonMask        = TR_DIG_FIELD(3),
    kTRDigType              = TR_DIG_FIELD(4),
    kTRDigIndex             = TR_DIG_FIELD(5),
    kTRDigIdentity          = TR_DIG_FIELD(6),
    kTRDigEventMask         = TR_DIG_FIELD(7),
    kTRDigRange             = TR_DIG_FIELD(8),
    kTRDigTouch             = TR_DIG_FIELD(9),
    kTRDigPressure          = TR_DIG_FIELD(10),
    kTRDigMajorRadius       = TR_DIG_FIELD(20),
    kTRDigMinorRadius       = TR_DIG_FIELD(21),
    kTRDigIsDisplayIntegrated = TR_DIG_FIELD(25),
};

// Transducer types
enum {
    kTRTransducerFinger = 2,
    kTRTransducerHand   = 3,
};

// Digitizer event mask bits
enum {
    kTRDigMaskRange    = 1 << 0,
    kTRDigMaskTouch    = 1 << 1,
    kTRDigMaskPosition = 1 << 2,
};

typedef struct {
    IOHIDEventSystemClientRef (*ClientCreate)(CFAllocatorRef);
    IOHIDEventSystemClientRef (*ClientCreateWithType)(CFAllocatorRef, int32_t, CFDictionaryRef);
    void (*ClientSchedule)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    void (*ClientRegisterCallback)(IOHIDEventSystemClientRef, TRHIDEventCallback, void *, void *);
    void (*ClientDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
    // Optional (iOS 13+): dispatch-queue based scheduling.
    void (*ClientSetDispatchQueue)(IOHIDEventSystemClientRef, dispatch_queue_t);
    void (*ClientActivate)(IOHIDEventSystemClientRef);
    void (*ClientCancel)(IOHIDEventSystemClientRef);
    void (*ClientUnschedule)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);

    uint32_t (*GetType)(IOHIDEventRef);
    CFArrayRef (*GetChildren)(IOHIDEventRef);
    CFIndex (*GetInteger)(IOHIDEventRef, TRHIDEventField);
    IOHIDFloat (*GetFloat)(IOHIDEventRef, TRHIDEventField);
    void (*SetInteger)(IOHIDEventRef, TRHIDEventField, CFIndex);
    void (*SetFloat)(IOHIDEventRef, TRHIDEventField, IOHIDFloat);
    uint64_t (*GetTimeStamp)(IOHIDEventRef);
    uint64_t (*GetSenderID)(IOHIDEventRef);
    void (*SetSenderID)(IOHIDEventRef, uint64_t);

    IOHIDEventRef (*CreateDigitizer)(CFAllocatorRef, uint64_t timeStamp, uint32_t transducerType,
                                     uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
                                     IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
                                     IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
                                     Boolean range, Boolean touch, uint32_t options);
    IOHIDEventRef (*CreateFinger)(CFAllocatorRef, uint64_t timeStamp, uint32_t index, uint32_t identity,
                                  uint32_t eventMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
                                  IOHIDFloat tipPressure, IOHIDFloat twist,
                                  Boolean range, Boolean touch, uint32_t options);
    void (*AppendEvent)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
} TRHIDFuncs;

extern TRHIDFuncs TRHID;

/// Loads all symbols. Returns NO if any is missing.
BOOL TRHIDLoad(void);
