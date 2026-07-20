#import "EmulatorBridge.h"
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#include "VAmiga.h"
#include "Emulator.h"

#include <filesystem>
#include <vector>
#include <functional>
#include <mutex>
#include <atomic>
#include <cstring>
#include <cmath>
#include <pthread.h>
#include <unistd.h>

using namespace vamiga;

// Private methods the C message listener invokes on the bridge.
@interface EmulatorBridge ()
- (void)playDriveStep;
- (void)playDiskInsert;
- (void)playDiskEject;
@end

const NSInteger AmigaFrameWidth       = 912;        // HPIXELS
const NSInteger AmigaFrameHeight      = 313;        // VPIXELS
const NSInteger AmigaFrameBytesPerRow = 912 * 4;    // 3648

// The core's MsgQueue fires this for state changes. It runs on the EMULATION
// thread (synchronously inside computeFrame), so every delegate call is
// marshalled to the main thread before touching UIKit-bound @Published state.
static void bridgeListener(const void *listener, Message msg) {
    EmulatorBridge *bridge = (__bridge EmulatorBridge *)listener;
    if (!bridge) return;

    switch (msg.type) {

        case Msg::DRIVE_MOTOR: {                 // DriveMsg{nr,value} — the drive LED
            NSInteger nr = (NSInteger)msg.drive.nr;
            BOOL on = msg.drive.value != 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                id<EmulatorBridgeDelegate> d = bridge.delegate;
                if ([d respondsToSelector:@selector(emulatorDriveLED:drive:)])
                    [d emulatorDriveLED:on drive:nr];
            });
            break;
        }
        case Msg::DRIVE_WRITE: {                 // value = drive nr — flag write mode
            NSInteger nr = (NSInteger)msg.value;
            dispatch_async(dispatch_get_main_queue(), ^{
                id<EmulatorBridgeDelegate> d = bridge.delegate;
                if ([d respondsToSelector:@selector(emulatorDriveDidWrite:)])
                    [d emulatorDriveDidWrite:nr];
            });
            break;
        }
        case Msg::POWER_LED_ON:
        case Msg::POWER_LED_DIM:
        case Msg::POWER_LED_OFF: {
            BOOL on = (msg.type != Msg::POWER_LED_OFF);
            dispatch_async(dispatch_get_main_queue(), ^{
                id<EmulatorBridgeDelegate> d = bridge.delegate;
                if ([d respondsToSelector:@selector(emulatorPowerDidChange:)])
                    [d emulatorPowerDidChange:on];
            });
            break;
        }
        // Mechanical drive sounds (DRIVE_STEP / DISK_INSERT / DISK_EJECT) are
        // intentionally NOT played — the floppy click / insert / eject SFX were
        // removed at the user's request. vAmiga's own internal drive-sound
        // synthesis is silenced via DRIVE_*_VOLUME = 0 in start(); the disk
        // activity LED is driven separately (DRIVE_MOTOR / DRIVE_WRITE).
        default: break;
    }
}

@implementation EmulatorBridge {
    VAmiga   *_emu;
    Emulator *_inner;        // cached _emu->emu — the per-frame execute target
    pthread_t _thread;
    std::atomic<bool> _running;
    std::atomic<bool> _paused;
    BOOL _romLoaded;
    BOOL _restoredFromSnapshot;

    // Control ops (disk/reset/…) are serialized onto the emulation thread so
    // they only ever run at a frame boundary, never mid-computeFrame.
    std::mutex _ctrlMutex;
    std::vector<std::function<void()>> _ctrlOps;

    // Audio: an AVAudioEngine source node pulls Paula samples on the render
    // thread via audioPort.copyStereo(); the emu thread is the producer.
    AVAudioEngine      *_audioEngine;
    AVAudioSourceNode  *_audioSource;
    std::atomic<bool>   _audioMuted;
    BOOL                _interruptionObserverInstalled;

    // Mechanical drive-sound players (preloaded mp3s; a round-robin pool for the
    // step click so rapid seeks overlap instead of cutting each other off).
    NSArray<AVAudioPlayer *> *_stepPlayers;
    NSInteger                 _stepIdx;
    double                    _lastStepTime;
    AVAudioPlayer            *_insertPlayer;
    AVAudioPlayer            *_ejectPlayer;
}

+ (instancetype)shared {
    static EmulatorBridge *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[EmulatorBridge alloc] init]; });
    return s;
}

- (BOOL)isRunning { return _running.load() && !_paused.load(); }
- (BOOL)romLoaded { return _romLoaded; }
- (BOOL)restoredFromSnapshot { return _restoredFromSnapshot; }

// MARK: - Lifecycle

- (void)start {
    if (_emu) return;

    _emu = new VAmiga();
    _inner = _emu->emu;
    _emu->launch((__bridge const void *)self, &bridgeListener);

    // Machine = a loaded Amiga 2000. vAmiga has no A2000 ConfigScheme (and no
    // AGA / 68040), so we start from the closest ECS scheme and shape it:
    // 68000 CPU, 8372A ECS Agnus + 8362 OCS Denise, A2000B banking, PAL, and
    // the maximum RAM the core accepts (1 MB chip + 1.5 MB slow + 8 MB Zorro-II
    // fast = 10.5 MB). All of this is set while powered off (memory/chipset
    // options are OPT_LOCKED once running) and drained with update().
    _emu->set(ConfigScheme::A500_ECS_1MB);
    try {
        _emu->set(Opt::CPU_REVISION,       (i64)CPURev::CPU_68000);
        _emu->set(Opt::AGNUS_REVISION,     (i64)AgnusRevision::ECS_1MB);
        _emu->set(Opt::DENISE_REVISION,    (i64)DeniseRev::OCS);
        _emu->set(Opt::MEM_BANKMAP,        (i64)BankMap::A2000B);
        _emu->set(Opt::AMIGA_VIDEO_FORMAT, (i64)TV::PAL);
        _emu->set(Opt::MEM_CHIP_RAM, 1024);   // 1 MB chip  (8372A Agnus max)
        _emu->set(Opt::MEM_SLOW_RAM, 1536);   // 1.5 MB slow
        _emu->set(Opt::MEM_FAST_RAM, 8192);   // 8 MB Zorro-II fast
    } catch (std::exception &e) {
        NSLog(@"[Amiga] A2000 config warning: %s", e.what());
    }
    // Audio: persisted master volume (default 100) + full per-channel volume
    // (isMuted() trips if either the master L+R or all four channel volumes
    // are 0), and tell the core to synthesize at the host rate we pull at.
    NSInteger volume = 100;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"AudioVolume"] != nil) {
        volume = [[NSUserDefaults standardUserDefaults] integerForKey:@"AudioVolume"];
        volume = MAX(0, MIN(100, volume));
    }
    _emu->set(Opt::AUD_VOLL, (i64)volume);
    _emu->set(Opt::AUD_VOLR, (i64)volume);
    _emu->set(Opt::AUD_VOL0, 100);
    _emu->set(Opt::AUD_VOL1, 100);
    _emu->set(Opt::AUD_VOL2, 100);
    _emu->set(Opt::AUD_VOL3, 100);
    _emu->set(Opt::HOST_SAMPLE_RATE, 44100);
    _emu->set(Opt::AUD_SAMPLING_METHOD, (i64)SamplingMethod::LINEAR);

    // Silence vAmiga's internal mechanical drive-sound synthesis (defaults are
    // STEP/INSERT/EJECT = 50%). The floppy click / insert / eject SFX were
    // removed at the user's request; combined with not playing the host mp3
    // samples, the drive is now silent (game audio via Paula is unaffected).
    try {
        _emu->set(Opt::DRIVE_STEP_VOLUME,   0);
        _emu->set(Opt::DRIVE_POLL_VOLUME,   0);
        _emu->set(Opt::DRIVE_INSERT_VOLUME, 0);
        _emu->set(Opt::DRIVE_EJECT_VOLUME,  0);
    } catch (std::exception &e) {
        NSLog(@"[Amiga] drive-sound mute failed: %s", e.what());
    }

    // Speed up disk access. A real Amiga floppy is intentionally slow (DC_SPEED
    // == 1 = authentic); 2/4/8 accelerate the disk-DMA transfer, -1 = instant
    // "turbo". Use 8x so games load in a fraction of the authentic time while
    // keeping the timing model intact (safer for copy-protected titles than the
    // timing-bypassing turbo mode).
    try { _emu->set(Opt::DC_SPEED, 8); }
    catch (std::exception &e) { NSLog(@"[Amiga] DC_SPEED set failed: %s", e.what()); }

    _inner->update();

    // Flash the bundled Kickstart ROM.
    // Resources/ROMs is a folder reference → the ROM lives under ROMs/.
    // Prefer the bundled A500/A2000 Kickstart 3.1, but fall back to ANY .rom
    // the user drops into Resources/ROMs so they can supply their own Kickstart
    // (e.g. a period-correct A2000 1.3/2.04) without code changes.
    NSString *romPath = [[NSBundle mainBundle] pathForResource:@"kickstart-3.1-a500_a600_a2000"
                                                        ofType:@"rom"
                                                  inDirectory:@"ROMs"];
    if (!romPath) {
        NSArray<NSString *> *roms = [[NSBundle mainBundle] pathsForResourcesOfType:@"rom"
                                                                      inDirectory:@"ROMs"];
        romPath = roms.firstObject;
        if (romPath) NSLog(@"[Amiga] using supplied ROM: %@", romPath.lastPathComponent);
    }
    NSData *rom = romPath ? [NSData dataWithContentsOfFile:romPath] : nil;
    if (rom) {
        try {
            _emu->mem.loadRom((const u8 *)rom.bytes, (isize)rom.length);
            _romLoaded = YES;
        } catch (std::exception &e) {
            NSLog(@"[Amiga] Kickstart load failed: %s", e.what());
        }
    } else {
        NSLog(@"[Amiga] Kickstart ROM not found in bundle");
    }

    try {
        _emu->isReady();        // throws if no ROM / no RAM
        _emu->powerOn();
        _emu->run();
    } catch (std::exception &e) {
        NSLog(@"[Amiga] machine not ready: %s", e.what());
    }
    _inner->update();

    // Default is a CLEAN boot — we no longer auto-restore the quick-save on
    // launch (it trapped the user on a restored session). The saved session is
    // still reachable on demand via the power menu's "Resume Saved Session"
    // (-loadQuickState) or the named save-state list.

    _running = true;
    _paused = false;
    pthread_create(&_thread, NULL, &EmulatorBridge_threadEntry, (__bridge void *)self);
}

static void *EmulatorBridge_threadEntry(void *arg) {
    pthread_setname_np("amiga.emu");
    [(__bridge EmulatorBridge *)arg runLoop];
    return NULL;
}

- (void)runLoop {
    const double target_fps = 50.0;     // PAL; refined on VIDEO_FORMAT later
    double startMs = CACurrentMediaTime() * 1000.0;
    int64_t total = 0;

    while (_running.load()) {

        // Drain queued control ops at the frame boundary.
        std::vector<std::function<void()>> ops;
        {
            std::lock_guard<std::mutex> lk(_ctrlMutex);
            ops.swap(_ctrlOps);
        }
        for (auto &op : ops) op();

        if (_paused.load()) {
            usleep(5000);
            startMs = CACurrentMediaTime() * 1000.0;
            total = 0;
            continue;
        }

        _inner->update();   // drain command queue (input) + apply config

        // Wall-clock frame budget: run exactly as many frames as are "due",
        // capped per tick. PAL/NTSC pace is independent of host refresh.
        double nowMs = CACurrentMediaTime() * 1000.0;
        double elapsed = (nowMs - startMs) / 1000.0;
        int64_t targetCount = (int64_t)(elapsed * target_fps);
        int64_t behind = targetCount - total;
        if (behind > 5) {                       // hopelessly behind → resync
            startMs = nowMs; total = 0; behind = 1;
        }
        int ran = 0;
        while (behind > 0 && ran < 4) {
            try { _inner->computeFrame(); }
            catch (...) { /* StateChangeException etc. — ignore */ }
            total++; behind--; ran++;
        }
        // Adaptive sleep: instead of a fixed 1ms poll, sleep until the next
        // frame is due (clamped 200µs..20ms). When we're ahead of the 20ms
        // PAL budget the thread idles for most of the frame period instead
        // of waking 20× per frame — the resync logic above is unaffected.
        double afterMs = CACurrentMediaTime() * 1000.0;
        double dueMs = startMs + (double)(total + 1) * (1000.0 / target_fps);
        double sleepMs = dueMs - afterMs;
        if (sleepMs < 0.2)  sleepMs = 0.2;
        if (sleepMs > 20.0) sleepMs = 20.0;
        usleep((useconds_t)(sleepMs * 1000.0));
    }
}

- (void)enqueueControl:(void (^)(void))op {
    std::lock_guard<std::mutex> lk(_ctrlMutex);
    _ctrlOps.emplace_back([op]() { op(); });
}

- (void)pause     { _paused = true; }
- (void)resume    { _paused = false; }
- (void)hardReset { [self enqueueControl:^{ self->_emu->hardReset(); self->_inner->update(); }]; }
- (void)softReset { [self enqueueControl:^{ self->_emu->softReset(); self->_inner->update(); }]; }

- (void)shutdown {
    [self stopAudio];        // stop the render block before _emu is freed
    _running = false;
    if (_thread) { pthread_join(_thread, NULL); _thread = 0; }
    if (_emu) { _emu->halt(); delete _emu; _emu = nullptr; _inner = nullptr; }
}

// MARK: - Framebuffer

- (const uint32_t *)lockFrame:(int64_t *)outFrameNr {
    if (!_emu) return nullptr;
    _emu->videoPort.lockTexture();
    isize nr = 0; bool lof = false, prevlof = false;
    const u32 *p = _emu->videoPort.getTexture(&nr, &lof, &prevlof);
    if (outFrameNr) *outFrameNr = (int64_t)nr;
    return (const uint32_t *)p;
}

- (void)unlockFrame {
    if (_emu) _emu->videoPort.unlockTexture();
}

- (BOOL)visibleCropLeft:(double *)left
                    top:(double *)top
                  right:(double *)right
                 bottom:(double *)bottom {
    if (!_emu) return NO;
    // findInnerAreaNormalized fills (x1=left, x2=right, y1=top, y2=bottom).
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    _emu->videoPort.findInnerAreaNormalized(x1, x2, y1, y2);
    if (x2 <= x1 || y2 <= y1) return NO;        // degenerate / all-border frame
    if (left)   *left   = x1;
    if (top)    *top    = y1;
    if (right)  *right  = x2;
    if (bottom) *bottom = y2;
    return YES;
}

// MARK: - Keyboard (raw Amiga keycodes)

- (void)keyDown:(uint8_t)code { if (_emu) _emu->put(Cmd::KEY_PRESS,   KeyCmd{(KeyCode)code, 0.0}); }
- (void)keyUp:(uint8_t)code   { if (_emu) _emu->put(Cmd::KEY_RELEASE, KeyCmd{(KeyCode)code, 0.0}); }
- (void)keyReleaseAll         { if (_emu) _emu->put(Cmd::KEY_RELEASE_ALL); }

// MARK: - Mouse

- (void)mousePort:(int)port moveDX:(double)dx dy:(double)dy {
    if (_emu) _emu->put(Cmd::MOUSE_MOVE_REL, CoordCmd{(isize)port, dx, dy});
}

- (void)mousePort:(int)port button:(int)button pressed:(BOOL)pressed {
    if (!_emu) return;
    GamePadAction a;
    switch (button) {
        case 1:  a = pressed ? GamePadAction::PRESS_LEFT   : GamePadAction::RELEASE_LEFT;   break;
        case 2:  a = pressed ? GamePadAction::PRESS_MIDDLE : GamePadAction::RELEASE_MIDDLE; break;
        default: a = pressed ? GamePadAction::PRESS_RIGHT  : GamePadAction::RELEASE_RIGHT;  break;
    }
    _emu->put(Cmd::MOUSE_BUTTON, GamePadCmd{(isize)port, a});
}

// MARK: - Joystick

- (void)joyPort:(int)port direction:(int)dir pressed:(BOOL)pressed {
    if (!_emu) return;
    GamePadAction a;
    if (pressed) {
        switch (dir) {
            case 0:  a = GamePadAction::PULL_UP;    break;
            case 1:  a = GamePadAction::PULL_DOWN;  break;
            case 2:  a = GamePadAction::PULL_LEFT;  break;
            default: a = GamePadAction::PULL_RIGHT; break;
        }
    } else {
        a = (dir <= 1) ? GamePadAction::RELEASE_Y : GamePadAction::RELEASE_X;
    }
    _emu->put(Cmd::JOY_EVENT, GamePadCmd{(isize)port, a});
}

- (void)joyPort:(int)port fire:(BOOL)pressed {
    if (_emu) _emu->put(Cmd::JOY_EVENT,
                        GamePadCmd{(isize)port,
                                   pressed ? GamePadAction::PRESS_FIRE : GamePadAction::RELEASE_FIRE});
}

// MARK: - Disk

- (FloppyDriveAPI *)driveAPI:(int)n {
    switch (n) {
        case 1:  return &_emu->df1;
        case 2:  return &_emu->df2;
        case 3:  return &_emu->df3;
        default: return &_emu->df0;
    }
}

- (BOOL)insertDiskAtPath:(NSString *)path drive:(int)driveNr {
    if (!_emu) return NO;
    std::string cpath = path.fileSystemRepresentation;
    int n = driveNr;
    [self enqueueControl:^{
        try {
            [self driveAPI:n]->insert(std::filesystem::path(cpath), false);
        } catch (std::exception &e) {
            NSLog(@"[Amiga] insert failed: %s", e.what());
            // The insert runs asynchronously on the emu thread — surface the
            // failure to the UI (the synchronous return above was already YES).
            NSString *reason = [NSString stringWithUTF8String:e.what()] ?: @"unreadable disk image";
            dispatch_async(dispatch_get_main_queue(), ^{
                id<EmulatorBridgeDelegate> d = self.delegate;
                if ([d respondsToSelector:@selector(emulatorDiskInsertFailed:)])
                    [d emulatorDiskInsertFailed:reason];
            });
        }
    }];
    return YES;
}

- (void)ejectDisk:(int)driveNr {
    if (!_emu) return;
    int n = driveNr;
    [self enqueueControl:^{
        try { [self driveAPI:n]->ejectDisk(); }
        catch (std::exception &e) { NSLog(@"[Amiga] eject failed: %s", e.what()); }
    }];
}

// MARK: - Audio

- (void)startAudio {
    if (_audioEngine) return;

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // .playback (not .ambient) so audio plays through the hardware mute switch —
    // an emulator/game should make sound regardless of the ringer position.
    // .mixWithOthers keeps it from killing background music.
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    if (err) { NSLog(@"[Amiga] audio session category: %@", err); err = nil; }
    [session setActive:YES error:&err];
    if (err) { NSLog(@"[Amiga] audio session activate: %@", err); err = nil; }

    _audioMuted = false;
    _audioEngine = [[AVAudioEngine alloc] init];
    // Standard format = deinterleaved float32; the core fills L/R via copyStereo.
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                                       channels:2];

    __weak EmulatorBridge *weakSelf = self;
    AVAudioSourceNodeRenderBlock render =
        ^OSStatus(BOOL *isSilence, const AudioTimeStamp *ts,
                  AVAudioFrameCount frameCount, AudioBufferList *abl) {
        float *outL = (float *)abl->mBuffers[0].mData;
        float *outR = (float *)abl->mBuffers[1].mData;
        EmulatorBridge *s = weakSelf;
        if (!s || !s->_emu || s->_audioMuted.load()) {
            if (outL) memset(outL, 0, frameCount * sizeof(float));
            if (outR) memset(outR, 0, frameCount * sizeof(float));
            *isSilence = YES;
            return noErr;
        }
        // Pull from Paula's ring buffer (thread-safe). copyStereo zero-pads on
        // underflow and returns the frame count actually produced.
        isize got = s->_emu->audioPort.copyStereo(outL, outR, (isize)frameCount);
        if (got < (isize)frameCount) {
            AVAudioFrameCount tail = frameCount - (AVAudioFrameCount)got;
            memset(outL + got, 0, tail * sizeof(float));
            memset(outR + got, 0, tail * sizeof(float));
        }
        if (got == 0) *isSilence = YES;
        return noErr;
    };

    _audioSource = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:render];
    [_audioEngine attachNode:_audioSource];
    [_audioEngine connect:_audioSource to:_audioEngine.mainMixerNode format:fmt];
    if (![_audioEngine startAndReturnError:&err]) {
        NSLog(@"[Amiga] audio engine start failed: %@", err);
        _audioEngine = nil;
        _audioSource = nil;
    }
    // Pause the engine on audio-session interruptions (phone call / Siri) and
    // restart it when the system says we should resume.
    if (!_interruptionObserverInstalled) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAudioInterruption:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
        _interruptionObserverInstalled = YES;
    }
    // Mechanical drive SFX removed at the user's request — don't load the
    // step/insert/eject samples. (`loadDriveSounds`/`playDrive*` remain defined
    // but are no longer called.)
}

// MARK: Mechanical drive sounds (host-played samples)

- (AVAudioPlayer *)preparedPlayer:(NSString *)name volume:(float)vol {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"mp3" inDirectory:@"Sounds"];
    if (!path) return nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    p.volume = vol;
    [p prepareToPlay];
    return p;
}

- (void)loadDriveSounds {
    if (_stepPlayers) return;
    NSMutableArray<AVAudioPlayer *> *pool = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {            // pool so fast seeks overlap
        AVAudioPlayer *p = [self preparedPlayer:@"step" volume:0.5f];
        if (p) [pool addObject:p];
    }
    _stepPlayers  = pool;
    _insertPlayer = [self preparedPlayer:@"insert" volume:0.7f];
    _ejectPlayer  = [self preparedPlayer:@"eject"  volume:0.7f];
}

- (void)playDriveStep {
    if (_stepPlayers.count == 0) return;
    // Throttle to ~80 clicks/sec so a fast multi-cylinder seek doesn't machine-gun.
    double now = CACurrentMediaTime();
    if (now - _lastStepTime < 0.012) return;
    _lastStepTime = now;
    AVAudioPlayer *p = _stepPlayers[(NSUInteger)(_stepIdx++ % (NSInteger)_stepPlayers.count)];
    p.currentTime = 0;
    [p play];
}

- (void)playDiskInsert { _insertPlayer.currentTime = 0; [_insertPlayer play]; }
- (void)playDiskEject  { _ejectPlayer.currentTime  = 0; [_ejectPlayer play];  }

- (void)stopAudio {
    if (_audioEngine) { [_audioEngine stop]; _audioEngine = nil; _audioSource = nil; }
}

- (void)pauseAudio:(BOOL)paused { _audioMuted = (paused != NO); }

/// Master volume 0–100 → Opt::AUD_VOLL/R. The audio options are not
/// OPT_LOCKED, so they can be set while powered on; serialize onto the emu
/// thread (set() is queued, drained by update()) like every other control op.
- (void)setVolume:(NSInteger)volume {
    if (!_emu) return;
    NSInteger v = MAX(0, MIN(100, volume));
    [self enqueueControl:^{
        try {
            self->_emu->set(Opt::AUD_VOLL, (i64)v);
            self->_emu->set(Opt::AUD_VOLR, (i64)v);
            self->_inner->update();
        } catch (std::exception &e) {
            NSLog(@"[Amiga] volume set failed: %s", e.what());
        }
    }];
}

// MARK: Audio session interruptions (phone call / Siri / other app)

- (void)handleAudioInterruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        [_audioEngine pause];
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSUInteger opts = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        if ((opts & AVAudioSessionInterruptionOptionShouldResume) && _audioEngine) {
            NSError *err = nil;
            [[AVAudioSession sharedInstance] setActive:YES error:&err];
            err = nil;
            if (![_audioEngine startAndReturnError:&err]) {
                NSLog(@"[Amiga] audio restart after interruption failed: %@", err);
            }
        }
    }
}

// MARK: - Save state (full machine snapshot)

- (NSString *)quickSavePath {
    // The extension MUST be .vasnap — Snapshot::isCompatible(path) checks both
    // the ".VASNAP" suffix and the VASNAP magic before loadSnapshot will accept it.
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"amiga-quicksave.vasnap"];
}

- (BOOL)hasQuickState {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self quickSavePath]];
}

- (void)deleteQuickState {
    [[NSFileManager defaultManager] removeItemAtPath:[self quickSavePath] error:nil];
}

// Serialize the snapshot op onto the emulation thread so it runs at a clean
// frame boundary (host-driven suspend() is a no-op, so we cannot rely on it).
// Blocks the caller until the op completes or a timeout elapses.
- (BOOL)runSnapshotOpAtPath:(NSString *)nspath op:(void (^)(const std::string &))op {
    if (!_emu || !_running.load()) return NO;
    std::string cpath = nspath.fileSystemRepresentation;
    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [self enqueueControl:^{
        try { op(cpath); ok = YES; }
        catch (std::exception &e) { NSLog(@"[Amiga] snapshot op failed: %s", e.what()); }
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
    return ok;
}

- (BOOL)saveStateToPath:(NSString *)path {
    return [self runSnapshotOpAtPath:path op:^(const std::string &p) {
        self->_emu->amiga.saveSnapshot(std::filesystem::path(p));
    }];
}

- (BOOL)loadStateFromPath:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    return [self runSnapshotOpAtPath:path op:^(const std::string &p) {
        self->_emu->amiga.loadSnapshot(std::filesystem::path(p));
        self->_inner->update();
    }];
}

- (BOOL)saveQuickState { return [self saveStateToPath:[self quickSavePath]]; }
- (BOOL)loadQuickState { return [self loadStateFromPath:[self quickSavePath]]; }

- (UIImage *)framebufferThumbnail {
    if (!_emu) return nil;
    _emu->videoPort.lockTexture();
    isize nr = 0; bool lof = false, prevlof = false;
    const u32 *src = _emu->videoPort.getTexture(&nr, &lof, &prevlof);
    UIImage *result = nil;
    if (src) {
        const size_t W = (size_t)AmigaFrameWidth;          // 912
        const size_t H = (size_t)AmigaFrameHeight;         // 313
        const size_t stride = (size_t)AmigaFrameBytesPerRow;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        // RGBA8888 in memory → treat the 4th byte as padding (opaque RGB).
        CGContextRef ctx = CGBitmapContextCreate((void *)src, W, H, 8, stride, cs,
            kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault);
        if (ctx) {
            CGImageRef full = CGBitmapContextCreateImage(ctx);
            if (full) {
                // Crop to roughly the visible Workbench area for a 4:3-ish thumb.
                CGRect crop = CGRectMake(W * 0.10, H * 0.06, W * 0.85, H * 0.86);
                CGImageRef cropped = CGImageCreateWithImageInRect(full, crop);
                if (cropped) {
                    result = [UIImage imageWithCGImage:cropped];
                    CGImageRelease(cropped);
                }
                CGImageRelease(full);
            }
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
    }
    _emu->videoPort.unlockTexture();
    return result;
}

@end
