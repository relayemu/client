/*
 Copyright (c) 2016, Jeffrey Pfau

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS''
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 */

#import "mGBAGameCoreBridge.h"
#import "mGBAGameCoreBridge+Achievements.h"

@import libmGBA;
@import PVCoreBridge;
@import PVCoreObjCBridge;
@import PVEmulatorCore;
@import PVAudio;

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
#import <OpenGL/OpenGL.h>
#import <GLUT/glut.h>
#endif

#include <mgba-util/common.h>

//#include <mgba/core/blip_buf.h>
#include <mgba/core/core.h>
#include <mgba/core/cheats.h>
#include <mgba/core/serialize.h>
#include <mgba/gba/core.h>
#include <mgba/gb/core.h>
#include <mgba/internal/gba/cheats.h>
#include <mgba/internal/gba/input.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/circle-buffer.h>
#include <mgba-util/memory.h>
#include <mgba-util/vfs.h>
#include <mgba-util/audio-resampler.h>

static const unsigned RelayAudioOutputRate = 32768;
static void _audioLowPassFilter(int16_t* buffer, int count);

static int32_t audioLowPassRange = (60 * 0x10000) / 100;
static int32_t audioLowPassLeftPrev = 0;
static int32_t audioLowPassRightPrev = 0;

const int GBAMap[] = {
    GBA_KEY_UP,
    GBA_KEY_DOWN,
    GBA_KEY_LEFT,
    GBA_KEY_RIGHT,
    GBA_KEY_A,
    GBA_KEY_B,
    GBA_KEY_L,
    GBA_KEY_R,
    GBA_KEY_START,
    GBA_KEY_SELECT
};

const char* const binaryName = "mGBA";
const char* const projectName = "Provenance EMU";
const char* const projectVersion = "3.0.0";

@interface PVmGBAGameCoreBridge () <PVGBASystemResponderClient> {
    struct mCore* core;
    void* outputBuffer;
    NSMutableDictionary *cheatSets;
    struct mAudioResampler resampler;
    struct mAudioBuffer intermediateAudio;
    size_t audioBufferSize;
    int16_t *audioBuffer;
    unsigned width, height;
    struct mAVStream stream;
    BOOL audioLowPassEnabled;
}
@end

static void _log(struct mLogger* log,
                 int category,
                 enum mLogLevel level,
                 const char* format,
                 va_list args)
{}

static struct mLogger logger = { .log = _log };

@implementation PVmGBAGameCoreBridge

// Expose the mCore pointer to achievement categories without making it public API.
- (struct mCore *)_mCore {
    return core;
}

- (instancetype)init {
    if ((self = [super init])) {

    }

    return self;
}

- (void)dealloc {
    mCoreConfigDeinit(&core->config);
    if (audioBuffer) {
        free(audioBuffer);
        audioBuffer = NULL;
    }
    audioBufferSize = 0;
    core->deinit(core);
    free(outputBuffer);
    mAudioResamplerDeinit(&resampler);
    mAudioBufferDeinit(&intermediateAudio);
}

#pragma mark - Execution


/// Relay: libmGBA is built with both M_CORE_GBA and M_CORE_GB, so the same
/// core package runs the Game Boy and Game Boy Color as well as the Game Boy
/// Advance. The frontend says which system it asked for; upstream only ever
/// created the Advance core. Key codes are shared: GB_KEY_* and GBA_KEY_* have
/// the same values for the eight buttons a Game Boy has, so GBAMap is correct
/// for both and the Advance-only L/R bits are simply never sent.
- (struct mCore *)relay_createCoreForCurrentSystem {
    NSString *system = self.systemIdentifier ?: @"";
    if ([system isEqualToString:@"com.provenance.gb"] || [system isEqualToString:@"com.provenance.gbc"]) {
        return GBCoreCreate();
    }
    return GBACoreCreate();
}

-(void)initialize {
    [super initialize];
    core = [self relay_createCoreForCurrentSystem];
    mCoreInitConfig(core, nil);

    struct mCoreOptions opts = {
        .useBios = true,
    };

    // Set up a logger. The default logger prints everything to STDOUT, which is not usually desirable.
    mLogSetDefaultLogger(&logger);
    mCoreConfigSetDefaultIntValue(&core->config, "logToStdout", true);
    mCoreConfigLoadDefaults(&core->config, &opts);
    core->init(core);
    outputBuffer = nil;

    // Video setup using currentVideoSize
    core->currentVideoSize(core, &width, &height);
    outputBuffer = malloc(width * height * BYTES_PER_PIXEL);
    core->setVideoBuffer(core, outputBuffer, width);

    // Relay: SOUNDBIAS lets a GBA game change its native rate from 32768
    // through 262144 Hz; GB uses 131072 Hz. Convert native samples to the
    // stable rate advertised to the frontend, as mGBA's SDL frontend does.
    // The source capacity covers a full frame at the highest hardware rate.
    core->setAudioBufferSize(core, 0x4000);
    mAudioBufferInit(&intermediateAudio, 2048, 2);
    mAudioResamplerInit(&resampler, mINTERPOLATOR_SINC);
    mAudioResamplerSetDestination(&resampler, &intermediateAudio, RelayAudioOutputRate);
    audioBufferSize = 2048 * sizeof(int16_t) * 2;
    audioBuffer = malloc(audioBufferSize);

    audioLowPassEnabled = YES;
    cheatSets = [[NSMutableDictionary alloc] init];
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    NSString *batterySavesDirectory = [self batterySavesPath];
    [[NSFileManager defaultManager] createDirectoryAtURL:[NSURL fileURLWithPath:batterySavesDirectory]
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    if (core->dirs.save) {
        core->dirs.save->close(core->dirs.save);
    }
    core->dirs.save = VDirOpen([batterySavesDirectory fileSystemRepresentation]);

    if (!mCoreLoadFile(core, [path fileSystemRepresentation])) {
        if (error) {
            *error = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:nil];
        }
        return NO;
    }
    mCoreAutoloadSave(core);

    core->reset(core);
    return YES;
}

// Relay native memory reads. No RA address or service concept crosses this bridge.
- (NSUInteger)relayReadMemoryRegion:(uint32_t)region offset:(uint32_t)offset
                             buffer:(void *)buffer count:(NSUInteger)count {
    if (!core || !buffer || count == 0) { return 0; }
    BOOL gb = core->platform(core) == mPLATFORM_GB;
    if (region == 0 && gb) {
        if (offset >= 0x10000 || count > 0x10000 - offset) { return 0; }
        uint8_t *out = buffer;
        for (NSUInteger i = 0; i < count; ++i) { out[i] = core->rawRead8(core, offset + (uint32_t)i, -1); }
        return count;
    }
    size_t blockID;
    if (region == 1) { blockID = gb ? 0x0C : 0x02; }
    else if (region == 2 && !gb) { blockID = 0x03; }
    // GBA 0x0F exposes physical savedata, including the first flash bank,
    // independently of the bank currently mapped into the bus at 0x0E.
    else if (region == 3) { blockID = gb ? 0x0A : 0x0F; }
    else { return 0; }
    size_t size = 0;
    const uint8_t *bytes = core->getMemoryBlock(core, blockID, &size);
    if (!bytes || offset >= size) { return 0; }
    size_t length = MIN(count, size - offset);
    memcpy(buffer, bytes + offset, length);
    return length;
}

- (void)executeFrame {
    core->runFrame(core);
    if (_relayFrameHandler) { _relayFrameHandler(); }

    struct mAudioBuffer *buffer = core->getAudioBuffer(core);
    unsigned sourceRate = core->audioSampleRate(core);
    if (sourceRate == 0) { return; }
    #if DEBUG
    if (resampler.sourceRate != sourceRate &&
        [[NSProcessInfo processInfo].arguments containsObject:@"--relay-skins-share-qualification"]) {
        NSLog(@"RELAY-AUDIO nativeRate=%u outputRate=%u", sourceRate, RelayAudioOutputRate);
    }
    #endif
    mAudioResamplerSetSource(&resampler, buffer, sourceRate, true);
    mAudioResamplerProcess(&resampler);
    size_t produced = mAudioBufferRead(&intermediateAudio, audioBuffer,
                                      audioBufferSize / (sizeof(int16_t) * 2));
    if (produced > 0) {
        if (audioLowPassEnabled) {
            _audioLowPassFilter(audioBuffer, (int)produced);
        }
        [[self ringBufferAtIndex:0] write:audioBuffer size:produced * sizeof(int16_t) * 2];
    }
}

- (void)resetEmulation {
    core->reset(core);
    mAudioBufferClear(&intermediateAudio);
    resampler.timestamp = 0;
    if (_relayResetHandler) { _relayResetHandler(); }
}

- (void)setupEmulation {

}

#pragma mark - Video

- (CGSize)aspectSize {
    // Relay: the Game Boy draws 160x144 and the Advance 240x160. Both have
    // square pixels, so the buffer's own ratio is the display ratio; upstream
    // returned the Advance's 3:2 for every game.
    core->currentVideoSize(core, &width, &height);
    if (width == 0 || height == 0) {
        return CGSizeMake(3, 2);
    }
    return CGSizeMake(width, height);
}

- (CGRect)screenRect {
    core->currentVideoSize(core, &width, &height);
    return CGRectMake(0, 0, width, height);
}

- (CGSize)bufferSize {
    core->currentVideoSize(core, &width, &height);
    return CGSizeMake(width, height);
}

- (void *)videoBuffer { return [self getVideoBufferWithHint:nil]; }

- (const void *)getVideoBufferWithHint:(void *)hint {
    CGSize bufferSize = [self bufferSize];

    if (!hint) {
        hint = outputBuffer;
    }

    outputBuffer = hint;
    core->setVideoBuffer(core, hint, bufferSize.width);

    return hint;
}

- (GLenum)pixelFormat { return GL_RGBA; }
- (GLenum)internalPixelFormat { return GL_RGBA; }

- (GLenum)pixelType {
#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
    return GL_UNSIGNED_INT_8_8_8_8_REV;
#else
    return GL_UNSIGNED_BYTE;
#endif
}

- (NSTimeInterval)frameInterval {
    return core->frequency(core) / (double) core->frameCycles(core);
}

#pragma mark - Audio

- (NSUInteger)channelCount {
    return 2;
}

- (double)audioSampleRate {
    return RelayAudioOutputRate;
}

- (NSUInteger)audioBitDepth {
    return 16; // Int16 samples
}

#pragma mark - Save State

- (NSData *)serializeStateWithError:(NSError **)outError
{
    struct VFile* vf = VFileMemChunk(nil, 0);
    if (!mCoreSaveStateNamed(core, vf, SAVESTATE_SAVEDATA)) {
        if (outError) {
            *outError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain code:PVEmulatorCoreErrorCodeCouldNotSaveState userInfo:nil];
        }
        vf->close(vf);
        return nil;
    }
    size_t size = vf->size(vf);
    void* data = vf->map(vf, size, MAP_READ);
    NSData *nsdata = [NSData dataWithBytes:data length:size];
    vf->unmap(vf, data, size);
    vf->close(vf);
    return nsdata;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    // Hardcore mode: save-state loads are disallowed while achievements are active.
    if (self.hardcoreMode && self.achievementsActive) {
        if (outError) {
            *outError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                           code:PVEmulatorCoreErrorCodeCouldNotLoadState
                                       userInfo:@{NSLocalizedDescriptionKey: @"Save state loading is disabled in RetroAchievements Hardcore Mode."}];
        }
        return NO;
    }

    struct VFile* vf = VFileFromConstMemory(state.bytes, state.length);
    if (!mCoreLoadStateNamed(core, vf, SAVESTATE_SAVEDATA)) {
        if (outError) {
            *outError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain code:PVEmulatorCoreErrorCodeCouldNotLoadState userInfo:nil];
        }
        vf->close(vf);
        return NO;
    }
    vf->close(vf);
    mAudioBufferClear(&intermediateAudio);
    resampler.timestamp = 0;
    return YES;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(NSError *))block {
    struct VFile* vf = VFileOpen([fileName fileSystemRepresentation], O_CREAT | O_TRUNC | O_RDWR);
    BOOL success = mCoreSaveStateNamed(core, vf, SAVESTATE_SAVEDATA | SAVESTATE_RTC);
    if(!success) {
        NSError *error = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotSaveState
                                         userInfo:@{
            NSLocalizedDescriptionKey : @"mGBA could not save the current state.",
            NSFilePathErrorKey : fileName
        }];
        block(error);
    } else {
        block(nil);
    }
    vf->close(vf);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(NSError *))block {
    // Hardcore mode: save-state loads are disallowed while achievements are active.
    if (self.hardcoreMode && self.achievementsActive) {
        NSError *error = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                            code:PVEmulatorCoreErrorCodeCouldNotLoadState
                                        userInfo:@{
            NSLocalizedDescriptionKey : @"Save state loading is disabled in RetroAchievements Hardcore Mode.",
            NSFilePathErrorKey : fileName
        }];
        block(error);
        return;
    }

    struct VFile* vf = VFileOpen([fileName fileSystemRepresentation], O_RDONLY);
    BOOL success = mCoreLoadStateNamed(core, vf, SAVESTATE_RTC);
    if(!success) {
        NSError *error = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadState
                                         userInfo:@{
            NSLocalizedDescriptionKey : @"mGBA could not load the current state.",
            NSFilePathErrorKey : fileName
        }];
        block(error);
    } else {
        block(nil);
    }
    vf->close(vf);
}

- (NSData *)relay_cloneBatterySave {
    void* sram = NULL;
    size_t size = core->savedataClone(core, &sram);
    if (!size || !sram) {
        if (sram) {
            free(sram);
        }
        return nil;
    }
    return [NSData dataWithBytesNoCopy:sram length:size freeWhenDone:YES];
}

#pragma mark - Input

- (oneway void)didPushGBAButton:(PVGBAButton)button forPlayer:(NSUInteger)player {
    UNUSED(player);
    core->addKeys(core, 1 << GBAMap[button]);
}

- (oneway void)didReleaseGBAButton:(PVGBAButton)button forPlayer:(NSUInteger)player {
    UNUSED(player);
    core->clearKeys(core, 1 << GBAMap[button]);
}

#pragma mark - Cheats

- (BOOL)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    NSString *codeId = [code stringByAppendingFormat:@"/%@", type];
    struct mCheatSet* cheatSet = [[cheatSets objectForKey:codeId] pointerValue];
    if (cheatSet) {
        cheatSet->enabled = enabled;
        return YES;
    }
    struct mCheatDevice* cheats = core->cheatDevice(core);
    if (!cheats) {
        return NO;
    }
    cheatSet = cheats->createSet(cheats, [codeId UTF8String]);
    if (!cheatSet) {
        return NO;
    }
    size_t size = mCheatSetsSize(&cheats->cheats);
    if (size) {
        cheatSet->copyProperties(cheatSet, *mCheatSetsGetPointer(&cheats->cheats, size - 1));
    }
    int codeType = GBA_CHEAT_AUTODETECT;
    NSArray *codeSet = [code componentsSeparatedByString:@"+"];
    for (id c in codeSet) {
        if (!mCheatAddLine(cheatSet, [c UTF8String], codeType)) {
            mCheatSetDeinit(cheatSet);
            return NO;
        }
    }
    cheatSet->enabled = enabled;
    [cheatSets setObject:[NSValue valueWithPointer:cheatSet] forKey:codeId];
    mCheatAddSet(cheats, cheatSet);
    return YES;
}

- (void)resetCheatCodes
{
    struct mCheatDevice* cheats = core->cheatDevice(core);
    if (cheats) {
        mCheatDeviceClear(cheats);
    }
    [cheatSets removeAllObjects];
}

@end

static void _audioLowPassFilter(int16_t* buffer, int count) {
    int16_t* out = buffer;

    /* Restore previous samples */
    int32_t audioLowPassLeft = audioLowPassLeftPrev;
    int32_t audioLowPassRight = audioLowPassRightPrev;

    /* Single-pole low-pass filter (6 dB/octave) */
    int32_t factorA = audioLowPassRange;
    int32_t factorB = 0x10000 - factorA;

    int samples;
    for (samples = 0; samples < count; ++samples) {
        /* Apply low-pass filter */
        audioLowPassLeft = (audioLowPassLeft * factorA) + (out[0] * factorB);
        audioLowPassRight = (audioLowPassRight * factorA) + (out[1] * factorB);

        /* 16.16 fixed point */
        audioLowPassLeft  >>= 16;
        audioLowPassRight >>= 16;

        /* Update outputs */
        out[0] = (int16_t) audioLowPassLeft;
        out[1] = (int16_t) audioLowPassRight;

        out += 2;
    }

    /* Store last samples for next frame */
    audioLowPassLeftPrev = audioLowPassLeft;
    audioLowPassRightPrev = audioLowPassRight;
}
