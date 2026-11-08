// Exercise the plug-in's public driver interface without installing it.
// The host clock is replaced so tests can advance time deterministically.
#define mach_absolute_time testHostTime
#include "SeirenFX.c"
#include <assert.h>
#include <stdio.h>

static UInt64 fakeHostTime = 1000000000000ull;
uint64_t testHostTime(void) { return fakeHostTime; }

static AudioServerPlugInDriverRef driver;
static AudioObjectID changedObjects[4];
static UInt32 changedCount;

static OSStatus propertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object,
    UInt32 count, const AudioObjectPropertyAddress* addresses)
{
    assert(changedCount < 4);
    changedObjects[changedCount++] = object;
    return noErr;
}

static AudioServerPlugInHostInterface host = { .PropertiesChanged = propertiesChanged };

static AudioObjectID deviceForUID(CFStringRef uid)
{
    AudioObjectPropertyAddress address = { kAudioPlugInPropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    assert((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0,
        &address, sizeof(uid), &uid, size, &size, &device) == noErr);
    assert(device != kAudioObjectUnknown);
    return device;
}

static UInt32 integerProperty(AudioObjectID object, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 value = 0, size = sizeof(value);
    assert((*driver)->GetPropertyData(driver, object, 0, &address,
        0, NULL, size, &size, &value) == noErr);
    assert(size == sizeof(value));
    return value;
}

static AudioObjectID checkStreams(AudioObjectID device, AudioObjectPropertyScope scope,
    UInt32 expectedChannels)
{
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, scope,
        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, device, 0, &address,
        0, NULL, &size) == noErr);
    assert(size == (expectedChannels ? sizeof(AudioObjectID) : 0));
    AudioObjectID stream = kAudioObjectUnknown;
    assert((*driver)->GetPropertyData(driver, device, 0, &address,
        0, NULL, sizeof(stream), &size, &stream) == noErr);
    assert(size == (expectedChannels ? sizeof(stream) : 0));
    UInt32 channels = 0;
    if (size) {
        assert(integerProperty(stream, kAudioObjectPropertyOwner,
            kAudioObjectPropertyScopeGlobal) == device);
        assert(integerProperty(stream, kAudioStreamPropertyDirection,
            kAudioObjectPropertyScopeGlobal) == (scope == kAudioObjectPropertyScopeInput));
        address.mSelector = kAudioStreamPropertyVirtualFormat;
        address.mScope = kAudioObjectPropertyScopeGlobal;
        AudioStreamBasicDescription format;
        size = sizeof(format);
        assert((*driver)->GetPropertyData(driver, stream, 0, &address,
            0, NULL, size, &size, &format) == noErr);
        channels += format.mChannelsPerFrame;
    }
    assert(channels == expectedChannels);
    return stream;
}

// Move the fake clock just past the next zero timestamp and check that the
// device's timeline advances by exactly one period at the given rate.
static void advanceOnePeriod(AudioObjectID device, UInt32 client, Float64 rate,
    Float64* sampleTime, UInt64* hostTime)
{
    UInt32 period = integerProperty(device, kAudioDevicePropertyZeroTimeStampPeriod,
        kAudioObjectPropertyScopeGlobal);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticks = (Float64)period / rate * 1.0e9 * timebase.denom / timebase.numer;
    fakeHostTime = *hostTime + (UInt64)ticks + 3;
    Float64 nextSampleTime;
    UInt64 nextHostTime, seed;
    assert((*driver)->GetZeroTimeStamp(driver, device, client,
        &nextSampleTime, &nextHostTime, &seed) == noErr);
    assert(nextSampleTime == *sampleTime + period);
    Float64 drift = (Float64)nextHostTime - ((Float64)*hostTime + ticks);
    assert(drift >= -2 && drift <= 2);
    *sampleTime = nextSampleTime;
    *hostTime = nextHostTime;
}

// HAL quiesces only the endpoint that requests a rate change; ten minutes into
// a call, the running peer must keep its current period and advance at the new rate.
static void checkRateChangeKeepsPeerTimeline(AudioObjectID input, AudioObjectID feeder)
{
    Float64 sampleTime;
    UInt64 hostTime, seed;
    assert((*driver)->GetZeroTimeStamp(driver, input, 2, &sampleTime, &hostTime, &seed) == noErr);
    for (int i = 0; i < 439; i++)
        advanceOnePeriod(i % 2 ? feeder : input, i % 2 ? 1 : 2, 48000, &sampleTime, &hostTime);

    const Float64 rates[] = {44100, 96000, 88200, 48000};
    for (UInt32 i = 0; i < 4; i++) {
        AudioObjectID changing = i % 2 ? input : feeder, peer = i % 2 ? feeder : input;
        UInt32 changingClient = changing == input ? 2 : 1, peerClient = peer == input ? 2 : 1;
        assert((*driver)->StopIO(driver, changing, changingClient) == noErr);
        changedCount = 0;
        assert((*driver)->PerformDeviceConfigurationChange(driver, changing,
            (UInt64)rates[i], NULL) == noErr);
        Float64 changedSampleTime, rejoinedSampleTime;
        UInt64 changedHostTime, rejoinedHostTime;
        assert((*driver)->GetZeroTimeStamp(driver, peer, peerClient,
            &changedSampleTime, &changedHostTime, &seed) == noErr);
        assert(changedSampleTime == sampleTime && changedHostTime == hostTime);
        advanceOnePeriod(peer, peerClient, rates[i], &sampleTime, &hostTime);
        assert((*driver)->StartIO(driver, changing, changingClient) == noErr);
        assert((*driver)->GetZeroTimeStamp(driver, changing, changingClient,
            &rejoinedSampleTime, &rejoinedHostTime, &seed) == noErr);
        assert(rejoinedSampleTime == sampleTime && rejoinedHostTime == hostTime);
    }
}

static void checkPair(CFStringRef inputUID, CFStringRef feederUID, Boolean inputFirst)
{
    AudioObjectID input = deviceForUID(inputUID);
    // Check the user-visible device first so the old driver fails on its output streams.
    AudioObjectID inputStream = checkStreams(input, kAudioObjectPropertyScopeInput, 2);
    checkStreams(input, kAudioObjectPropertyScopeOutput, 0);
    assert(integerProperty(input, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0);
    AudioObjectID feeder = deviceForUID(feederUID);
    assert(feeder != input);
    checkStreams(feeder, kAudioObjectPropertyScopeInput, 0);
    AudioObjectID outputStream = checkStreams(feeder, kAudioObjectPropertyScopeOutput, 2);
    assert(integerProperty(feeder, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 1);
    assert(integerProperty(feeder, kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioObjectPropertyScopeOutput) == 0);
    UInt32 clock = integerProperty(input, kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal);
    assert(clock != 0);
    assert(integerProperty(feeder, kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal) == clock);

    const Float64 rates[] = {44100, 88200, 96000, 48000};
    for (UInt32 i = 0; i < 4; i++) {
        changedCount = 0;
        assert((*driver)->PerformDeviceConfigurationChange(driver, i % 2 ? input : feeder,
            (UInt64)rates[i], NULL) == noErr);
        assert(changedCount == 4);
        AudioObjectID objects[] = { input, feeder, inputStream, outputStream };
        for (UInt32 j = 0; j < 4; j++) {
            Boolean notified = false;
            for (UInt32 n = 0; n < changedCount; n++) notified |= changedObjects[n] == objects[j];
            assert(notified);
            AudioObjectPropertyAddress address = {
                j < 2 ? kAudioDevicePropertyNominalSampleRate : kAudioStreamPropertyVirtualFormat,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioStreamBasicDescription format;
            Float64 rate = 0;
            UInt32 size = j < 2 ? sizeof(rate) : sizeof(format);
            assert((*driver)->GetPropertyData(driver, objects[j], 0, &address, 0, NULL,
                size, &size, j < 2 ? (void*)&rate : (void*)&format) == noErr);
            assert((j < 2 ? rate : format.mSampleRate) == rates[i]);
        }
    }

    AudioObjectID first = inputFirst ? input : feeder;
    AudioObjectID second = inputFirst ? feeder : input;
    assert((*driver)->StartIO(driver, first, inputFirst ? 2 : 1) == noErr);
    Float64 sampleTime, inputSampleTime;
    UInt64 hostTime, inputHostTime, seed;
    assert((*driver)->GetZeroTimeStamp(driver, first, inputFirst ? 2 : 1,
        &sampleTime, &hostTime, &seed) == noErr);
    if (inputFirst) assert((*driver)->StartIO(driver, second, 1) == noErr);
    Float32 sent[] = { 0.25f, -0.5f, 0.75f, -1.0f }, received[4] = {0};
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mOutputTime.mSampleTime = 128;
    cycle.mInputTime.mSampleTime = 128;
    assert((*driver)->DoIOOperation(driver, feeder, outputStream, 1,
        kAudioServerPlugInIOOperationWriteMix, 2, &cycle, sent, NULL) == noErr);
    // Joining a call must neither reset the running feeder's clock nor clear its audio.
    if (!inputFirst) assert((*driver)->StartIO(driver, second, 2) == noErr);
    assert((*driver)->GetZeroTimeStamp(driver, input, 2,
        &inputSampleTime, &inputHostTime, &seed) == noErr);
    assert(inputSampleTime == sampleTime && inputHostTime == hostTime);
    checkRateChangeKeepsPeerTimeline(input, feeder);
    for (int call = 0; call < 2; call++) {
        assert((*driver)->DoIOOperation(driver, input, inputStream, 2,
            kAudioServerPlugInIOOperationReadInput, 2, &cycle, received, NULL) == noErr);
        assert(memcmp(sent, received, sizeof(sent)) == 0);
        assert((*driver)->StopIO(driver, input, 2) == noErr);
        if (call == 0) assert((*driver)->StartIO(driver, input, 2) == noErr);
    }
    assert((*driver)->StopIO(driver, feeder, 1) == noErr);
}

int main(void)
{
    driver = SeirenFX_Create(kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    assert(driver != NULL);
    assert((*driver)->Initialize(driver, &host) == noErr);
    for (int inputFirst = 0; inputFirst < 2; inputFirst++) {
        checkPair(CFSTR("SeirenFX:Device:0"), CFSTR("SeirenFX:Feeder:0"), inputFirst);
        checkPair(CFSTR("SeirenFX:StreamMix"), CFSTR("SeirenFX:StreamMix:Feeder"), inputFirst);
    }
    puts("PASS: visible inputs have zero output streams/channels; hidden feeders share audio and clocks across calls and rate changes");
    return 0;
}
