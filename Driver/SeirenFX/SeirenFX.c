//
//  SeirenFX.c
//  SeirenFX — a minimal loopback CoreAudio virtual audio device (AudioServerPlugIn).
//
//  Part of Seiren for macOS (https://github.com/yterry/razer-seiren-macos), MIT-licensed.
//
//  WHAT THIS IS
//  ------------
//  A HAL "AudioServerPlugIn" that publishes one virtual device, "Seiren FX",
//  with a stereo input stream and a stereo output stream wired together as a
//  loopback: whatever an app *plays* to the output appears on the input for
//  other apps to *record*. The seiren-mac menu-bar app reads the real Razer
//  Seiren microphone, applies DSP (EQ, noise suppression), and plays the
//  processed audio into this device's output; OBS / Zoom / Discord select
//  "Seiren FX" as their input and therefore record the processed voice.
//
//  This is the only way to make our software DSP reach *other apps* on macOS
//  (CoreAudio gives apps the raw hardware mic directly; there is no system
//  insert point). It is an entitlement-free userspace driver, but it must be
//  installed to /Library/Audio/Plug-Ins/HAL and loaded by coreaudiod.
//
//  PROVENANCE
//  ----------
//  This file is original code written against Apple's *public* AudioServerPlugIn
//  API (the same API documented in Apple's "NullAudio" sample). It deliberately
//  does NOT derive from BlackHole or any GPL source — seiren-mac is MIT and must
//  stay MIT. The loopback ring-buffer technique is the obvious implementation of
//  the public DoIOOperation contract.
//
//  OBJECT MODEL (no Box — the device is always published)
//  ------------------------------------------------------
//    kObjectID_PlugIn (1)
//      └─ kObjectID_Device (2)            "Seiren FX"
//           ├─ kObjectID_Stream_Input (3)   (what other apps record)
//           └─ kObjectID_Stream_Output (4)  (what our app plays into)
//
//  Audio format: interleaved stereo Float32, default 48 kHz.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#pragma mark - Constants & identifiers

// These strings are part of the device's stable identity. Do not change them
// casually: the app finds the device by kDevice_UID, and macOS remembers a
// device's per-app volume/default selection by UID.
#define kPlugIn_BundleID        "com.yterry.seiren-mac.SeirenFX"
#define kDevice_Name            "Seiren FX"
#define kDevice_Manufacturer    "seiren-mac"
#define kDevice_UID             "SeirenFX:Device:0"
#define kDevice_ModelUID        "SeirenFX:Model"

#define kChannelsPerFrame       2u
#define kBitsPerChannel         32u
#define kBytesPerFrame          (kChannelsPerFrame * (kBitsPerChannel / 8u))   // 8

// Loopback ring length, in frames. Also used as the device's zero-timestamp
// period so that (sampleTime % kRingFrames) indexes the ring coherently.
#define kRingFrames             65536u

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4
};

// The set of sample rates we advertise. Default is 48 kHz (the Seiren's rate).
static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kNumSupportedSampleRates (sizeof(kSupportedSampleRates) / sizeof(Float64))

#pragma mark - Globals

static AudioServerPlugInHostRef gPlugIn_Host = NULL;
static pthread_mutex_t          gStateMutex  = PTHREAD_MUTEX_INITIALIZER;

static UInt32   gPlugIn_RefCount  = 0;

static Float64  gSampleRate       = 48000.0;
static UInt32   gIO_RunningCount  = 0;   // how many clients have StartIO'd
static Boolean  gStream_Input_IsActive  = true;
static Boolean  gStream_Output_IsActive = true;

// Zero-timestamp bookkeeping.
static Float64  gHostTicksPerFrame = 0.0;
static UInt64   gAnchorHostTime    = 0;
static volatile UInt64 gNumberTimeStamps = 0;

// The loopback ring. Interleaved Float32, kRingFrames * kChannelsPerFrame.
static Float32* gRing = NULL;

#pragma mark - Forward declarations (interface methods)

static HRESULT      SeirenFX_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        SeirenFX_AddRef(void* inDriver);
static ULONG        SeirenFX_Release(void* inDriver);
static OSStatus     SeirenFX_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus     SeirenFX_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus     SeirenFX_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus     SeirenFX_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     SeirenFX_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     SeirenFX_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus     SeirenFX_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean      SeirenFX_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress);
static OSStatus     SeirenFX_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus     SeirenFX_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus     SeirenFX_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus     SeirenFX_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus     SeirenFX_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     SeirenFX_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     SeirenFX_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus     SeirenFX_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus     SeirenFX_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus     SeirenFX_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus     SeirenFX_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - The driver interface (COM-style vtable)

static AudioServerPlugInDriverInterface gInterface = {
    NULL,                                       // _reserved
    SeirenFX_QueryInterface,
    SeirenFX_AddRef,
    SeirenFX_Release,
    SeirenFX_Initialize,
    SeirenFX_CreateDevice,
    SeirenFX_DestroyDevice,
    SeirenFX_AddDeviceClient,
    SeirenFX_RemoveDeviceClient,
    SeirenFX_PerformDeviceConfigurationChange,
    SeirenFX_AbortDeviceConfigurationChange,
    SeirenFX_HasProperty,
    SeirenFX_IsPropertySettable,
    SeirenFX_GetPropertyDataSize,
    SeirenFX_GetPropertyData,
    SeirenFX_SetPropertyData,
    SeirenFX_StartIO,
    SeirenFX_StopIO,
    SeirenFX_GetZeroTimeStamp,
    SeirenFX_WillDoIOOperation,
    SeirenFX_BeginIOOperation,
    SeirenFX_DoIOOperation,
    SeirenFX_EndIOOperation
};

static AudioServerPlugInDriverInterface*    gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef           gDriverRef    = &gInterfacePtr;

#pragma mark - Factory (the single exported symbol; named in Info.plist)

void* SeirenFX_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* SeirenFX_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

#pragma mark - IUnknown

static HRESULT SeirenFX_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) return E_INVALIDARG;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gPlugIn_RefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    if (requested) CFRelease(requested);
    return result;
}

static ULONG SeirenFX_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gPlugIn_RefCount < UINT32_MAX) gPlugIn_RefCount++;
    ULONG r = gPlugIn_RefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG SeirenFX_Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gPlugIn_RefCount > 0) gPlugIn_RefCount--;
    ULONG r = gPlugIn_RefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

#pragma mark - Lifecycle

static OSStatus SeirenFX_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gPlugIn_Host = inHost;

    // Host clock → frames conversion for GetZeroTimeStamp.
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostTicksPerSecond = ((Float64)tb.denom / (Float64)tb.numer) * 1.0e9;
    gHostTicksPerFrame = hostTicksPerSecond / gSampleRate;

    // Allocate (and clear) the loopback ring once.
    if (gRing == NULL) {
        gRing = (Float32*)calloc((size_t)kRingFrames * kChannelsPerFrame, sizeof(Float32));
        if (gRing == NULL) return kAudioHardwareUnspecifiedError;
    }
    return noErr;
}

// We publish a fixed device, so dynamic device creation/destruction is N/A.
static OSStatus SeirenFX_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SeirenFX_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SeirenFX_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus SeirenFX_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus SeirenFX_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    // We encode the requested sample rate as the change action.
    Float64 newRate = (Float64)inChangeAction;
    Boolean supported = false;
    for (UInt32 i = 0; i < kNumSupportedSampleRates; i++) {
        if (kSupportedSampleRates[i] == newRate) { supported = true; break; }
    }
    if (!supported) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gStateMutex);
    gSampleRate = newRate;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostTicksPerSecond = ((Float64)tb.denom / (Float64)tb.numer) * 1.0e9;
    gHostTicksPerFrame = hostTicksPerSecond / gSampleRate;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus SeirenFX_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

#pragma mark - Property helpers

// Builds the interleaved stereo Float32 ASBD for the current sample rate.
static AudioStreamBasicDescription SeirenFX_MakeFormat(Float64 inSampleRate)
{
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate       = inSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket   = kBytesPerFrame;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = kBytesPerFrame;
    f.mChannelsPerFrame = kChannelsPerFrame;
    f.mBitsPerChannel   = kBitsPerChannel;
    return f;
}

#pragma mark - HasProperty

static Boolean SeirenFX_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientPID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyBoxList:
                case kAudioPlugInPropertyTranslateUIDToBox:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                    return true;
            }
            return false;

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredChannelLayout:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    return true;
            }
            return false;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
            }
            return false;
    }
    return false;
}

#pragma mark - IsPropertySettable

static OSStatus SeirenFX_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inClientPID;
    if (inDriver != gDriverRef || inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    *outIsSettable = false;
    switch (inObjectID) {
        case kObjectID_Device:
            if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) *outIsSettable = true;
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outIsSettable = true;
                    break;
            }
            break;
    }
    return noErr;
}

#pragma mark - GetPropertyDataSize

static OSStatus SeirenFX_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:               *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:                   *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:                   *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyManufacturer:            *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:            *outDataSize = sizeof(AudioObjectID); return noErr; // [device]
                case kAudioPlugInPropertyBoxList:                 *outDataSize = 0; return noErr;                      // no boxes
                case kAudioPlugInPropertyTranslateUIDToBox:       *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyDeviceList:              *outDataSize = sizeof(AudioObjectID); return noErr; // [device]
                case kAudioPlugInPropertyTranslateUIDToDevice:    *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyResourceBundle:          *outDataSize = sizeof(CFStringRef); return noErr;
            }
            return kAudioHardwareUnknownPropertyError;

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:               *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:                   *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:                   *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:                    *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer:            *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                    // Streams owned by the device, filtered by scope.
                    switch (inAddress->mScope) {
                        case kAudioObjectPropertyScopeInput:  *outDataSize = 1 * sizeof(AudioObjectID); return noErr;
                        case kAudioObjectPropertyScopeOutput: *outDataSize = 1 * sizeof(AudioObjectID); return noErr;
                        default:                              *outDataSize = 2 * sizeof(AudioObjectID); return noErr;
                    }
                case kAudioDevicePropertyDeviceUID:               *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyModelUID:                *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyTransportType:           *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyRelatedDevices:          *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioDevicePropertyClockDomain:             *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsAlive:           *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsRunning:         *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:        *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:  *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyLatency:                 *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyStreams:
                    switch (inAddress->mScope) {
                        case kAudioObjectPropertyScopeInput:  *outDataSize = 1 * sizeof(AudioObjectID); return noErr;
                        case kAudioObjectPropertyScopeOutput: *outDataSize = 1 * sizeof(AudioObjectID); return noErr;
                        default:                              *outDataSize = 2 * sizeof(AudioObjectID); return noErr;
                    }
                case kAudioObjectPropertyControlList:             *outDataSize = 0; return noErr; // no controls
                case kAudioDevicePropertySafetyOffset:           *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyNominalSampleRate:       *outDataSize = sizeof(Float64); return noErr;
                case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = (UInt32)(kNumSupportedSampleRates * sizeof(AudioValueRange)); return noErr;
                case kAudioDevicePropertyIsHidden:                *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); return noErr;
                case kAudioDevicePropertyPreferredChannelLayout:  *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelsPerFrame * sizeof(AudioChannelDescription))); return noErr;
                case kAudioDevicePropertyZeroTimeStampPeriod:     *outDataSize = sizeof(UInt32); return noErr;
            }
            return kAudioHardwareUnknownPropertyError;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:               *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:                   *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:                   *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioStreamPropertyIsActive:                *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyDirection:               *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyTerminalType:            *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyStartingChannel:         *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyLatency:                 *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:          *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: *outDataSize = (UInt32)(kNumSupportedSampleRates * sizeof(AudioStreamRangedDescription)); return noErr;
            }
            return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

#pragma mark - GetPropertyData

static OSStatus SeirenFX_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inClientPID;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer); *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                    if (inDataSize >= sizeof(AudioObjectID)) {
                        ((AudioObjectID*)outData)[0] = kObjectID_Device; *outDataSize = sizeof(AudioObjectID);
                    } else { *outDataSize = 0; }
                    return noErr;
                case kAudioPlugInPropertyBoxList:
                    *outDataSize = 0; return noErr;
                case kAudioPlugInPropertyTranslateUIDToBox:
                    *((AudioObjectID*)outData) = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyDeviceList:
                    if (inDataSize >= sizeof(AudioObjectID)) {
                        ((AudioObjectID*)outData)[0] = kObjectID_Device; *outDataSize = sizeof(AudioObjectID);
                    } else { *outDataSize = 0; }
                    return noErr;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    AudioObjectID found = kAudioObjectUnknown;
                    if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                        CFStringRef uid = *((CFStringRef*)inQualifierData);
                        if (uid && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) found = kObjectID_Device;
                    }
                    *((AudioObjectID*)outData) = found; *outDataSize = sizeof(AudioObjectID); return noErr;
                }
                case kAudioPlugInPropertyResourceBundle:
                    *((CFStringRef*)outData) = CFSTR(""); *outDataSize = sizeof(CFStringRef); return noErr;
            }
            return kAudioHardwareUnknownPropertyError;

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kObjectID_PlugIn; *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:
                    *((CFStringRef*)outData) = CFSTR(kDevice_Name); *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer); *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 max = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    if ((inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeGlobal) && n < max)
                        list[n++] = kObjectID_Stream_Input;
                    if ((inAddress->mScope == kAudioObjectPropertyScopeOutput || inAddress->mScope == kAudioObjectPropertyScopeGlobal) && n < max)
                        list[n++] = kObjectID_Stream_Output;
                    *outDataSize = n * sizeof(AudioObjectID); return noErr;
                }
                case kAudioDevicePropertyDeviceUID:
                    *((CFStringRef*)outData) = CFSTR(kDevice_UID); *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyModelUID:
                    *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID); *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyTransportType:
                    *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize >= sizeof(AudioObjectID)) {
                        ((AudioObjectID*)outData)[0] = kObjectID_Device; *outDataSize = sizeof(AudioObjectID);
                    } else { *outDataSize = 0; }
                    return noErr;
                case kAudioDevicePropertyClockDomain:
                    *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsAlive:
                    *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsRunning: {
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32*)outData) = (gIO_RunningCount > 0) ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32); return noErr;
                }
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyLatency:
                    *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0; return noErr;
                case kAudioDevicePropertySafetyOffset:
                    *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyNominalSampleRate: {
                    pthread_mutex_lock(&gStateMutex);
                    *((Float64*)outData) = gSampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(Float64); return noErr;
                }
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange* ranges = (AudioValueRange*)outData;
                    UInt32 max = inDataSize / sizeof(AudioValueRange);
                    UInt32 n = 0;
                    for (UInt32 i = 0; i < kNumSupportedSampleRates && n < max; i++) {
                        ranges[n].mMinimum = kSupportedSampleRates[i];
                        ranges[n].mMaximum = kSupportedSampleRates[i];
                        n++;
                    }
                    *outDataSize = n * sizeof(AudioValueRange); return noErr;
                }
                case kAudioDevicePropertyIsHidden:
                    *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    UInt32* chans = (UInt32*)outData;
                    chans[0] = 1; chans[1] = 2; *outDataSize = 2 * sizeof(UInt32); return noErr;
                }
                case kAudioDevicePropertyPreferredChannelLayout: {
                    AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                    UInt32 sz = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelsPerFrame * sizeof(AudioChannelDescription)));
                    memset(layout, 0, sz);
                    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    layout->mNumberChannelDescriptions = kChannelsPerFrame;
                    layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                    layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                    *outDataSize = sz; return noErr;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *((UInt32*)outData) = kRingFrames; *outDataSize = sizeof(UInt32); return noErr;
            }
            return kAudioHardwareUnknownPropertyError;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: {
            Boolean isInput = (inObjectID == kObjectID_Stream_Input);
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioStreamPropertyIsActive: {
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32*)outData) = (isInput ? gStream_Input_IsActive : gStream_Output_IsActive) ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32); return noErr;
                }
                case kAudioStreamPropertyDirection:
                    *((UInt32*)outData) = isInput ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyTerminalType:
                    *((UInt32*)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyStartingChannel:
                    *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyLatency:
                    *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    pthread_mutex_lock(&gStateMutex);
                    *((AudioStreamBasicDescription*)outData) = SeirenFX_MakeFormat(gSampleRate);
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    AudioStreamRangedDescription* descs = (AudioStreamRangedDescription*)outData;
                    UInt32 max = inDataSize / sizeof(AudioStreamRangedDescription);
                    UInt32 n = 0;
                    for (UInt32 i = 0; i < kNumSupportedSampleRates && n < max; i++) {
                        descs[n].mFormat = SeirenFX_MakeFormat(kSupportedSampleRates[i]);
                        descs[n].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                        descs[n].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
                        n++;
                    }
                    *outDataSize = n * sizeof(AudioStreamRangedDescription); return noErr;
                }
            }
            return kAudioHardwareUnknownPropertyError;
        }
    }
    return kAudioHardwareBadObjectError;
}

#pragma mark - SetPropertyData

static OSStatus SeirenFX_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef || inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    switch (inObjectID) {
        case kObjectID_Device:
            if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
                if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                Float64 requested = *((const Float64*)inData);
                Boolean supported = false;
                for (UInt32 i = 0; i < kNumSupportedSampleRates; i++)
                    if (kSupportedSampleRates[i] == requested) { supported = true; break; }
                if (!supported) return kAudioHardwareIllegalOperationError;

                Boolean changed;
                pthread_mutex_lock(&gStateMutex);
                changed = (requested != gSampleRate);
                pthread_mutex_unlock(&gStateMutex);
                // Apply asynchronously through the host so the HAL can quiesce IO.
                if (changed && gPlugIn_Host != NULL)
                    gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, (UInt64)requested, NULL);
                return noErr;
            }
            return kAudioHardwareUnknownPropertyError;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: {
            Boolean isInput = (inObjectID == kObjectID_Stream_Input);
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyIsActive: {
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    Boolean active = (*((const UInt32*)inData) != 0);
                    pthread_mutex_lock(&gStateMutex);
                    if (isInput) gStream_Input_IsActive = active; else gStream_Output_IsActive = active;
                    pthread_mutex_unlock(&gStateMutex);
                    return noErr;
                }
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                    const AudioStreamBasicDescription* fmt = (const AudioStreamBasicDescription*)inData;
                    if (fmt->mFormatID != kAudioFormatLinearPCM) return kAudioHardwareIllegalOperationError;
                    Boolean supported = false;
                    for (UInt32 i = 0; i < kNumSupportedSampleRates; i++)
                        if (kSupportedSampleRates[i] == fmt->mSampleRate) { supported = true; break; }
                    if (!supported) return kAudioHardwareIllegalOperationError;
                    if (gPlugIn_Host != NULL)
                        gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, (UInt64)fmt->mSampleRate, NULL);
                    return noErr;
                }
            }
            return kAudioHardwareUnknownPropertyError;
        }
    }
    return kAudioHardwareBadObjectError;
}

#pragma mark - IO

static OSStatus SeirenFX_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIO_RunningCount == 0) {
        // First client: reset the timeline and clear stale loopback audio.
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        if (gRing != NULL)
            memset(gRing, 0, (size_t)kRingFrames * kChannelsPerFrame * sizeof(Float32));
    }
    gIO_RunningCount++;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus SeirenFX_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIO_RunningCount > 0) gIO_RunningCount--;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus SeirenFX_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    Float64 nextOffset = ((Float64)(gNumberTimeStamps + 1)) * hostTicksPerRing;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)nextOffset;
    if (currentHostTime >= nextHostTime) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * (UInt64)kRingFrames);
    *outHostTime   = gAnchorHostTime + (UInt64)(((Float64)gNumberTimeStamps) * hostTicksPerRing);
    *outSeed       = 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus SeirenFX_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    Boolean willDo = false, inPlace = true;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true; inPlace = true; break;
    }
    if (outWillDo)        *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = inPlace;
    return noErr;
}

static OSStatus SeirenFX_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

static OSStatus SeirenFX_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (gRing == NULL || ioMainBuffer == NULL) return noErr;

    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // App played audio → store it in the ring at the output sample time.
        Float64 startTime = inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 f = 0; f < inIOBufferFrameSize; f++) {
            UInt64 idx = ((UInt64)(startTime + (Float64)f)) % (UInt64)kRingFrames;
            Float32* dst = &gRing[idx * kChannelsPerFrame];
            const Float32* src = &buffer[(size_t)f * kChannelsPerFrame];
            for (UInt32 c = 0; c < kChannelsPerFrame; c++) dst[c] = src[c];
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        // Other app recording → serve it the ring at the input sample time.
        Float64 startTime = inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 f = 0; f < inIOBufferFrameSize; f++) {
            UInt64 idx = ((UInt64)(startTime + (Float64)f)) % (UInt64)kRingFrames;
            const Float32* src = &gRing[idx * kChannelsPerFrame];
            Float32* dst = &buffer[(size_t)f * kChannelsPerFrame];
            for (UInt32 c = 0; c < kChannelsPerFrame; c++) dst[c] = src[c];
        }
    }
    return noErr;
}

static OSStatus SeirenFX_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}
