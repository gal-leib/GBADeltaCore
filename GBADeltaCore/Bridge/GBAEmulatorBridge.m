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
#include <mgba/internal/gba/sio.h>
#include <mgba/internal/gba/sio/rfu-network.h>
#include <mgba/internal/gba/sio/rfu-wan-session.h>
#include <mgba/internal/gba/sio/wireless.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/audio-resampler.h>
#include <mgba-util/interpolator.h>
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
{
    struct GBASIOWireless _wirelessAdapter;
    struct GBARfuWanSession _wanSession;
    BOOL _wirelessRunning;
    BOOL _wirelessIsHost;
    uint64_t _wirelessSessionId;
    NSLock *_inboundLock;
    NSMutableArray<NSData *> *_inboundDatagrams;
    
    struct mAudioResampler _audioResampler;
    struct mAudioBuffer _resampledAudioBuffer;
    unsigned _lastAudioSampleRate;
    BOOL _audioResamplerInitialized;
}
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;

- (void)setVideoRenderer:(id<DLTAVideoRendering>)videoRenderer
{
    _videoRenderer = videoRenderer;
    if (self.core && _videoRenderer.videoBuffer != NULL)
    {
        self.core->setVideoBuffer(self.core, (mColor *)_videoRenderer.videoBuffer, GBA_SCREEN_WIDTH);
        if (self.rawVideoBuffer != NULL)
        {
            free(self.rawVideoBuffer);
            self.rawVideoBuffer = NULL;
        }
    }
}

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
        _inboundLock = [[NSLock alloc] init];
        _inboundDatagrams = [[NSMutableArray alloc] init];
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
    
    // Performance: Tune mGBA options for Delta's frame loop
    core->opts.videoSync = false;
    core->opts.audioSync = false;
    core->opts.fpsTarget = 60.0f;
    core->opts.sampleRate = 32768;
    core->opts.audioBuffers = 1024;
    core->opts.skipBios = true;
    core->opts.useBios = false;
    core->opts.rewindEnable = false;
    core->opts.rewindBufferCapacity = 0;
    
    core->init(core);
    
    if (self.videoRenderer != nil && self.videoRenderer.videoBuffer != NULL)
    {
        core->setVideoBuffer(core, (mColor *)self.videoRenderer.videoBuffer, GBA_SCREEN_WIDTH);
    }
    else
    {
        if (!self.rawVideoBuffer)
        {
            self.rawVideoBuffer = (uint32_t *)malloc(GBA_SCREEN_WIDTH * GBA_SCREEN_HEIGHT * sizeof(uint32_t));
        }
        core->setVideoBuffer(core, (mColor *)self.rawVideoBuffer, GBA_SCREEN_WIDTH);
    }
    
    core->setAudioBufferSize(core, 8192);
    self.audioBuffer = core->getAudioBuffer(core);
    
    if (!_audioResamplerInitialized)
    {
        mAudioBufferInit(&_resampledAudioBuffer, 8192, 2);
        mAudioResamplerInit(&_audioResampler, mINTERPOLATOR_COSINE);
        mAudioResamplerSetDestination(&_audioResampler, &_resampledAudioBuffer, 32768);
        _audioResamplerInitialized = YES;
    }
    else
    {
        mAudioBufferClear(&_resampledAudioBuffer);
    }
    
    _lastAudioSampleRate = core->audioSampleRate(core);
    if (_lastAudioSampleRate == 0)
    {
        _lastAudioSampleRate = 32768;
    }
    mAudioResamplerSetSource(&_audioResampler, self.audioBuffer, _lastAudioSampleRate, true);
    
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
        return;
    }
    
    core->reset(core);
    
    if (_wirelessRunning)
    {
        uint16_t localId = _wirelessIsHost ? 0x62 : 0x61;
        GBASIOWirelessCreate(&_wirelessAdapter);
        GBARfuWanSessionInit(&_wanSession, &_wirelessAdapter, _wirelessIsHost, _wirelessSessionId, localId);
        core->setPeripheral(core, mPERIPH_GBA_LINK_PORT, &_wirelessAdapter.d);
    }
    
    self.core = core;
    self.isEmulating = YES;
}

- (void)stop
{
    [self stopWireless];
    
    if (_audioResamplerInitialized)
    {
        mAudioResamplerDeinit(&_audioResampler);
        mAudioBufferDeinit(&_resampledAudioBuffer);
        _audioResamplerInitialized = NO;
    }
    
    if (self.core != NULL)
    {
        self.core->deinit(self.core);
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
    
    if (_wirelessRunning)
    {
        // 1. Drain inbound queue into GBARfuWanSession
        NSArray<NSData *> *pendingInbound = nil;
        [_inboundLock lock];
        if (_inboundDatagrams.count > 0)
        {
            pendingInbound = [_inboundDatagrams copy];
            [_inboundDatagrams removeAllObjects];
        }
        [_inboundLock unlock];
        
        for (NSData *data in pendingInbound)
        {
            GBARfuWanSessionPushDatagram(&_wanSession, data.bytes, data.length);
        }
        
        // 2. Advance WAN session clock (~16,743 us per frame)
        GBARfuWanSessionAdvance(&_wanSession, 16743);
        
        // 3. Drain outbound datagrams from session
        uint8_t outBuffer[GBA_RFU_WAN_DATAGRAM_SIZE];
        size_t outSize;
        while ((outSize = GBARfuWanSessionTakeDatagram(&_wanSession, outBuffer, sizeof(outBuffer))) > 0)
        {
            if (self.wirelessSendDatagramHandler != nil)
            {
                NSData *outData = [NSData dataWithBytes:outBuffer length:outSize];
                self.wirelessSendDatagramHandler(outData);
            }
        }
        
        // 4. Poll wireless transport
        GBASIOWirelessPollTransport(&_wirelessAdapter);
    }
    
    self.core->runFrame(self.core);
    
    if (processVideo && self.videoRenderer != nil)
    {
        // Zero-copy: ensure mGBA renders directly into Delta's display texture buffer
        if (self.rawVideoBuffer != NULL && self.videoRenderer.videoBuffer != NULL)
        {
            self.core->setVideoBuffer(self.core, (mColor *)self.videoRenderer.videoBuffer, GBA_SCREEN_WIDTH);
            free(self.rawVideoBuffer);
            self.rawVideoBuffer = NULL;
        }
        [self.videoRenderer processFrame];
    }
    
    if (self.audioRenderer != nil && self.audioBuffer != NULL && _audioResamplerInitialized)
    {
        unsigned currentRate = self.core->audioSampleRate(self.core);
        if (currentRate > 0 && currentRate != _lastAudioSampleRate)
        {
            _lastAudioSampleRate = currentRate;
            mAudioResamplerSetSource(&_audioResampler, self.audioBuffer, currentRate, true);
        }
        
        mAudioResamplerProcess(&_audioResampler);
        
        int16_t samples[2048 * 2];
        size_t available;
        while ((available = mAudioBufferAvailable(&_resampledAudioBuffer)) > 0)
        {
            size_t toRead = MIN(available, 2048);
            size_t readCount = mAudioBufferRead(&_resampledAudioBuffer, samples, toRead);
            if (readCount > 0)
            {
                [self.audioRenderer.audioBuffer writeBuffer:(uint8_t *)samples size:(readCount * sizeof(int16_t) * 2)];
            }
            if (readCount < toRead)
            {
                break;
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

#pragma mark - Wireless Adapter (RFU) -

- (BOOL)isWirelessActive
{
    return _wirelessRunning;
}

- (BOOL)isWirelessAdapterConnected
{
    return _wirelessRunning && _wirelessAdapter.connected;
}

- (BOOL)startWirelessWithHost:(BOOL)isHost sessionId:(uint64_t)sessionId
{
    _wirelessIsHost = isHost;
    _wirelessSessionId = sessionId;
    if (isHost && _wirelessSessionId == 0)
    {
        arc4random_buf(&_wirelessSessionId, sizeof(_wirelessSessionId));
        if (_wirelessSessionId == 0)
        {
            _wirelessSessionId = 1;
        }
    }
    
    if (!self.core)
    {
        _wirelessRunning = YES;
        return YES;
    }
    
    [self stopWireless];
    _wirelessRunning = YES;
    
    uint16_t localId = isHost ? 0x62 : 0x61;
    
    GBASIOWirelessCreate(&_wirelessAdapter);
    GBARfuWanSessionInit(&_wanSession, &_wirelessAdapter, isHost, _wirelessSessionId, localId);
    
    self.core->setPeripheral(self.core, mPERIPH_GBA_LINK_PORT, &_wirelessAdapter.d);
    
    return YES;
}

- (void)stopWireless
{
    if (!_wirelessRunning)
    {
        return;
    }
    
    _wirelessRunning = NO;
    
    if (self.core)
    {
        self.core->setPeripheral(self.core, mPERIPH_GBA_LINK_PORT, NULL);
    }
    
    GBASIOWirelessDestroy(&_wirelessAdapter);
    
    [_inboundLock lock];
    [_inboundDatagrams removeAllObjects];
    [_inboundLock unlock];
}

- (void)receiveWirelessDatagram:(NSData *)datagram
{
    if (!_wirelessRunning || datagram.length < GBA_RFU_NET_HEADER_SIZE)
    {
        return;
    }
    
    if (memcmp(datagram.bytes, "MRFU", 4) != 0)
    {
        return;
    }
    
    [_inboundLock lock];
    [_inboundDatagrams addObject:datagram];
    [_inboundLock unlock];
}

- (nullable NSData *)generateWirelessDiscoveryProbe
{
    if (!_wirelessRunning)
    {
        return nil;
    }
    
    struct GBARfuNetMessage msg = {};
    msg.type = GBA_RFU_NET_HELLO;
    msg.sessionId = 0;
    msg.senderId = _wanSession.localId ? _wanSession.localId : 0x61;
    msg.targetMask = 0;
    msg.sequence = 0;
    msg.payloadSize = 0;
    
    uint8_t buffer[GBA_RFU_NET_HEADER_SIZE];
    size_t len = GBARfuNetEncode(&msg, buffer, sizeof(buffer));
    if (len > 0)
    {
        return [NSData dataWithBytes:buffer length:len];
    }
    return nil;
}

- (void)getWirelessStatsWithSessionId:(nullable uint64_t *)sessionId
                        sessionActive:(nullable BOOL *)sessionActive
                     adapterConnected:(nullable BOOL *)adapterConnected
                      retransmissions:(nullable uint64_t *)retransmissions
                        parseFailures:(nullable uint64_t *)parseFailures
                          overflowed:(nullable uint64_t *)overflowed
{
    if (!_wirelessRunning)
    {
        if (sessionId) *sessionId = 0;
        if (sessionActive) *sessionActive = NO;
        if (adapterConnected) *adapterConnected = NO;
        if (retransmissions) *retransmissions = 0;
        if (parseFailures) *parseFailures = 0;
        if (overflowed) *overflowed = 0;
        return;
    }
    
    if (sessionId) *sessionId = _wanSession.sessionId;
    if (sessionActive) *sessionActive = _wanSession.sessionActive;
    if (adapterConnected) *adapterConnected = _wirelessAdapter.connected;
    if (retransmissions) *retransmissions = _wanSession.retransmissions;
    if (parseFailures) *parseFailures = _wanSession.parseFailures;
    if (overflowed) *overflowed = _wanSession.overflowed;
}

@end
