//
//  GBAEmulatorBridge.m
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Updated for mGBA integration.
//

#import <GBADeltaCore/GBADeltaCore.h>

#import <CoreMotion/CoreMotion.h>

// mGBA Core Includes
#include <mgba/core/core.h>
#include <mgba/core/cheats.h>
#include <mgba/core/config.h>
#include <mgba/core/interface.h>
#include <mgba/core/serialize.h>
#include <mgba/core/version.h>
#include <mgba/gba/core.h>
#include <mgba/gba/interface.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/cheats.h>
#include <mgba/internal/gba/input.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/memory.h>
#include <mgba-util/vfs.h>

// DeltaCore Includes
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>

static const int GBA_SCREEN_WIDTH = 240;
static const int GBA_SCREEN_HEIGHT = 160;
static const size_t AUDIO_BUFFER_CAPACITY = 2048;

@interface GBAEmulatorBridge ()

@property (nonatomic, copy, nullable, readwrite) NSURL *gameURL;
@property (nonatomic, strong, readonly) CMMotionManager *motionManager;
@property (nonatomic, assign) struct mCore *core;
@property (nonatomic, assign) struct mAudioBuffer *audioBuffer;
@property (nonatomic, assign) uint32_t *rawVideoBuffer;
@property (nonatomic, assign) struct mRotationSource rotationSource;
@property (nonatomic, assign) struct GBALuminanceSource luxSource;
@property (nonatomic, assign) struct mCoreCallbacks coreCallbacks;
@property (nonatomic, assign) BOOL isEmulating;
@property (nonatomic, assign) BOOL isGyroActive;

- (void)activateGyroscope;
- (void)deactivateGyroscope;

@end

#pragma mark - Callbacks -

static void _savedataUpdatedCallback(void *context)
{
    GBAEmulatorBridge *bridge = (__bridge GBAEmulatorBridge *)context;
    if (bridge.saveUpdateHandler != nil)
    {
        bridge.saveUpdateHandler();
    }
}

static void _sampleRotation(struct mRotationSource *source)
{
}

static int32_t _readTiltX(struct mRotationSource *source)
{
    GBAEmulatorBridge *bridge = [GBAEmulatorBridge sharedBridge];
    if (bridge.motionManager.isAccelerometerActive)
    {
        CMAcceleration accel = bridge.motionManager.accelerometerData.acceleration;
        return (int32_t)(accel.x * 0x7000);
    }
    return 0;
}

static int32_t _readTiltY(struct mRotationSource *source)
{
    GBAEmulatorBridge *bridge = [GBAEmulatorBridge sharedBridge];
    if (bridge.motionManager.isAccelerometerActive)
    {
        CMAcceleration accel = bridge.motionManager.accelerometerData.acceleration;
        return (int32_t)(accel.y * 0x7000);
    }
    return 0;
}

static int32_t _readGyroZ(struct mRotationSource *source)
{
    GBAEmulatorBridge *bridge = [GBAEmulatorBridge sharedBridge];
    if (!bridge.isGyroActive)
    {
        [bridge activateGyroscope];
    }
    
    if (bridge.motionManager.isGyroActive)
    {
        CMGyroData *gyroData = bridge.motionManager.gyroData;
        int32_t sensorZ = (int32_t)(-gyroData.rotationRate.z * 25.0 * 256.0);
        return sensorZ;
    }
    return 0;
}

static void _sampleLux(struct GBALuminanceSource *source)
{
}

static uint8_t _readLux(struct GBALuminanceSource *source)
{
    return 0x00;
}

#pragma mark - Implementation -

@implementation GBAEmulatorBridge
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;

+ (instancetype)sharedBridge
{
    static GBAEmulatorBridge *_emulatorBridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _emulatorBridge = [[self alloc] init];
    });
    
    return _emulatorBridge;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _motionManager = [[CMMotionManager alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

#pragma mark - Emulation -

- (void)startWithGameURL:(NSURL *)URL
{
    [self stop];
    
    self.gameURL = URL;
    
    struct mCore *core = mCoreCreate(mPLATFORM_GBA);
    if (!core)
    {
        NSLog(@"[GBADeltaCore/mGBA] Failed to create mGBA core instance.");
        return;
    }
    
    mCoreInitConfig(core, NULL);
    
    if (!self.rawVideoBuffer)
    {
        self.rawVideoBuffer = (uint32_t *)malloc(GBA_SCREEN_WIDTH * GBA_SCREEN_HEIGHT * sizeof(uint32_t));
    }
    core->setVideoBuffer(core, (mColor *)self.rawVideoBuffer, GBA_SCREEN_WIDTH);
    
    core->setAudioBufferSize(core, AUDIO_BUFFER_CAPACITY);
    self.audioBuffer = core->getAudioBuffer(core);
    
    // Peripherals
    memset(&_rotationSource, 0, sizeof(_rotationSource));
    _rotationSource.sample = _sampleRotation;
    _rotationSource.readTiltX = _readTiltX;
    _rotationSource.readTiltY = _readTiltY;
    _rotationSource.readGyroZ = _readGyroZ;
    core->setPeripheral(core, mPERIPH_ROTATION, &_rotationSource);
    
    memset(&_luxSource, 0, sizeof(_luxSource));
    _luxSource.sample = _sampleLux;
    _luxSource.readLuminance = _readLux;
    core->setPeripheral(core, mPERIPH_GBA_LUMINANCE, &_luxSource);
    
    // Core callbacks
    memset(&_coreCallbacks, 0, sizeof(_coreCallbacks));
    _coreCallbacks.context = (__bridge void *)self;
    _coreCallbacks.savedataUpdated = _savedataUpdatedCallback;
    core->addCoreCallbacks(core, &_coreCallbacks);
    
    // Load ROM
    if (!mCoreLoadFile(core, URL.fileSystemRepresentation))
    {
        NSLog(@"[GBADeltaCore/mGBA] Failed to load ROM at URL: %@", URL);
        core->deinit(core);
        free(core);
        return;
    }
    
    core->init(core);
    core->reset(core);
    
    self.core = core;
    self.isEmulating = YES;
}

- (void)stop
{
    if (self.core != NULL)
    {
        self.core->deinit(self.core);
        free(self.core);
        self.core = NULL;
    }
    
    if (self.rawVideoBuffer != NULL)
    {
        free(self.rawVideoBuffer);
        self.rawVideoBuffer = NULL;
    }
    
    self.audioBuffer = NULL;
    self.isEmulating = NO;
    [self deactivateGyroscope];
}

- (void)pause
{
    self.isEmulating = NO;
    [self deactivateGyroscope];
}

- (void)resume
{
    self.isEmulating = YES;
    [self activateGyroscope];
}

- (void)runFrameAndProcessVideo:(BOOL)processVideo
{
    if (!self.core || !self.isEmulating)
    {
        return;
    }
    
    self.core->runFrame(self.core);
    
    if (processVideo && self.videoRenderer != nil)
    {
        if (self.videoRenderer.videoBuffer != NULL && self.rawVideoBuffer != NULL)
        {
            memcpy(self.videoRenderer.videoBuffer, self.rawVideoBuffer, GBA_SCREEN_WIDTH * GBA_SCREEN_HEIGHT * sizeof(uint32_t));
        }
        [self.videoRenderer processFrame];
    }
    
    if (self.audioRenderer != nil && self.audioBuffer != NULL)
    {
        size_t available = mAudioBufferAvailable(self.audioBuffer);
        if (available > 0)
        {
            int16_t samples[2048 * 2];
            size_t toRead = MIN(available, 2048);
            size_t readCount = mAudioBufferRead(self.audioBuffer, samples, toRead);
            if (readCount > 0)
            {
                [self.audioRenderer.audioBuffer writeBuffer:(uint8_t *)samples size:(readCount * sizeof(int16_t) * 2)];
            }
        }
    }
}

#pragma mark - Memory Inspection -

- (nullable NSData *)readMemoryAtAddress:(NSInteger)address size:(NSInteger)size
{
    if (!self.core)
    {
        return nil;
    }
    
    struct GBA *gba = (struct GBA *)self.core->board;
    if (!gba)
    {
        return nil;
    }
    
    if (address >= 0x02000000 && address < 0x02000000 + GBA_SIZE_EWRAM)
    {
        uint32_t offset = (uint32_t)(address - 0x02000000);
        if (offset + size <= GBA_SIZE_EWRAM)
        {
            return [NSData dataWithBytes:(gba->memory.wram + offset) length:size];
        }
    }
    else if (address >= 0x03000000 && address < 0x03000000 + GBA_SIZE_IWRAM)
    {
        uint32_t offset = (uint32_t)(address - 0x03000000);
        if (offset + size <= GBA_SIZE_IWRAM)
        {
            return [NSData dataWithBytes:(gba->memory.iwram + offset) length:size];
        }
    }
    else if (address >= 0x8000 && address < 0x8000 + GBA_SIZE_EWRAM)
    {
        uint32_t offset = (uint32_t)(address - 0x8000);
        if (offset + size <= GBA_SIZE_EWRAM)
        {
            return [NSData dataWithBytes:(gba->memory.wram + offset) length:size];
        }
    }
    else if (address < GBA_SIZE_IWRAM)
    {
        if (address + size <= GBA_SIZE_IWRAM)
        {
            return [NSData dataWithBytes:(gba->memory.iwram + address) length:size];
        }
    }
    
    NSMutableData *data = [NSMutableData dataWithLength:size];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    for (NSInteger i = 0; i < size; i++)
    {
        bytes[i] = (uint8_t)self.core->rawRead8(self.core, (uint32_t)(address + i), 0);
    }
    return data;
}

#pragma mark - Inputs -

- (void)activateInput:(NSInteger)gameInput value:(double)value playerIndex:(NSInteger)playerIndex
{
    if (!self.core) return;
    self.core->addKeys(self.core, (uint32_t)gameInput);
}

- (void)deactivateInput:(NSInteger)gameInput playerIndex:(NSInteger)playerIndex
{
    if (!self.core) return;
    self.core->clearKeys(self.core, (uint32_t)gameInput);
}

- (void)resetInputs
{
    if (!self.core) return;
    self.core->setKeys(self.core, 0);
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)URL
{
    if (!self.core) return;
    
    void *sram = NULL;
    size_t size = self.core->savedataClone(self.core, &sram);
    if (sram != NULL && size > 0)
    {
        NSData *data = [NSData dataWithBytes:sram length:size];
        NSError *error = nil;
        if (![data writeToURL:URL options:NSDataWritingAtomic error:&error])
        {
            NSLog(@"[GBADeltaCore/mGBA] Error saving game save to %@: %@", URL, error);
        }
        free(sram);
    }
}

- (void)loadGameSaveFromURL:(NSURL *)URL
{
    if (!self.core) return;
    
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:&error];
    if (data && data.length > 0)
    {
        self.core->savedataRestore(self.core, data.bytes, data.length, true);
    }
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    if (!self.core) return;
    
    struct VFile *vf = VFileOpen(URL.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY);
    if (vf)
    {
        mCoreSaveStateNamed(self.core, vf, SAVESTATE_SAVEDATA);
        vf->close(vf);
    }
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    if (!self.core) return;
    
    struct VFile *vf = VFileOpen(URL.fileSystemRepresentation, O_RDONLY);
    if (vf)
    {
        mCoreLoadStateNamed(self.core, vf, SAVESTATE_SAVEDATA);
        vf->close(vf);
    }
}

#pragma mark - Cheats -

- (BOOL)addCheatCode:(NSString *)cheatCode type:(NSString *)type
{
    if (!self.core) return NO;
    
    struct mCheatDevice *device = self.core->cheatDevice(self.core);
    if (!device) return NO;
    
    struct mCheatSet *set = device->createSet(device, "DeltaCheats");
    if (!set) return NO;
    
    int cheatType = GBA_CHEAT_AUTODETECT;
    if ([type isEqualToString:CheatTypeGameShark])
    {
        cheatType = GBA_CHEAT_GAMESHARK;
    }
    else if ([type isEqualToString:CheatTypeActionReplay])
    {
        cheatType = GBA_CHEAT_PRO_ACTION_REPLAY;
    }
    else if ([type isEqualToString:CheatTypeCodeBreaker])
    {
        cheatType = GBA_CHEAT_CODEBREAKER;
    }
    
    NSArray<NSString *> *lines = [cheatCode componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *rawLine in lines)
    {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        
        if (!mCheatAddLine(set, [line UTF8String], cheatType))
        {
            NSLog(@"[GBADeltaCore/mGBA] Failed to add cheat line: %@", line);
        }
    }
    
    mCheatAddSet(device, set);
    mCheatRefresh(device, set);
    return YES;
}

- (void)resetCheats
{
    if (!self.core) return;
    
    struct mCheatDevice *device = self.core->cheatDevice(self.core);
    if (device)
    {
        mCheatDeviceClear(device);
    }
}

- (void)updateCheats
{
}

#pragma mark - Gyroscope -

- (void)activateGyroscope
{
    if (self.isGyroActive || !self.motionManager.isGyroAvailable)
    {
        return;
    }
    
    [self.motionManager startGyroUpdates];
    [self.motionManager startAccelerometerUpdates];
    self.isGyroActive = YES;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:GBADidActivateGyroNotification object:self];
}

- (void)deactivateGyroscope
{
    if (!self.isGyroActive)
    {
        return;
    }
    
    [self.motionManager stopGyroUpdates];
    [self.motionManager stopAccelerometerUpdates];
    self.isGyroActive = NO;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:GBADidDeactivateGyroNotification object:self];
}

#pragma mark - Timing -

- (NSTimeInterval)frameDuration
{
    return (1.0 / 59.727500569606);
}

@end
