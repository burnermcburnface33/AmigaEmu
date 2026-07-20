#import <Foundation/Foundation.h>

@class UIImage;

NS_ASSUME_NONNULL_BEGIN

/// vAmiga framebuffer geometry. The core renders into a fixed-size CPU
/// texture (HPIXELS×VPIXELS) of 32-bit RGBA8888 texels regardless of the
/// Amiga display mode; the visible picture is a crop within it.
extern const NSInteger AmigaFrameWidth;        // 912  (HPIXELS)
extern const NSInteger AmigaFrameHeight;       // 313  (VPIXELS)
extern const NSInteger AmigaFrameBytesPerRow;  // 3648 (HPIXELS * 4)

@protocol EmulatorBridgeDelegate <NSObject>
@optional
/// Floppy drive motor turned on/off (DRIVE_MOTOR) — the drive activity LED.
/// `nr` is the drive index (0 = DF0). Delivered on the main thread.
- (void)emulatorDriveLED:(BOOL)on drive:(NSInteger)nr;
/// A write to the drive occurred (DRIVE_WRITE) — lets the UI flag write vs read.
- (void)emulatorDriveDidWrite:(NSInteger)nr;
- (void)emulatorPowerDidChange:(BOOL)on;
/// A queued disk insert failed on the emulation thread (unreadable /
/// unsupported image). `reason` is the core's error text. Main thread.
- (void)emulatorDiskInsertFailed:(NSString *)reason;
@end

/// Obj-C++ façade over the vAmiga core. Owns the emulator object and a
/// single background pthread that pumps frames (the core's own thread is
/// compiled out — host-driven model, like the dospad/KEGS bridges).
@interface EmulatorBridge : NSObject

@property (nonatomic, weak, nullable) id<EmulatorBridgeDelegate> delegate;

+ (instancetype)shared;

// MARK: Lifecycle
/// Constructs the machine, loads the bundled Kickstart ROM, powers on, and
/// starts the emulation thread. Safe to call once.
- (void)start;
- (void)pause;
- (void)resume;
- (void)hardReset;
- (void)softReset;
- (void)shutdown;

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) BOOL romLoaded;
/// YES when -start restored a saved snapshot instead of booting fresh (so the
/// app should skip re-inserting the bundled disk over the restored state).
@property (nonatomic, readonly) BOOL restoredFromSnapshot;

// MARK: Audio — AVAudioEngine source node pulling the core's Paula output.
/// Builds + starts the audio engine (configures the AVAudioSession). Idempotent.
- (void)startAudio;
- (void)stopAudio;
/// Mutes the render block (used on background) without tearing the engine down.
- (void)pauseAudio:(BOOL)paused;
/// Master volume 0–100 (Opt::AUD_VOLL/R, safe to set while running).
/// Persisted by the caller in UserDefaults("AudioVolume"); -start applies it.
- (void)setVolume:(NSInteger)volume;

// MARK: Save state — complete machine snapshot (RAM + CPU + chipset + drives).
/// Serializes the live machine to the quick-save file. Safe to call while
/// running (serialized onto the emulation thread). Returns NO on failure.
- (BOOL)saveQuickState;
/// Restores the quick-save file into the running machine. Returns NO if absent
/// or incompatible.
- (BOOL)loadQuickState;
/// YES if a quick-save file currently exists on disk.
- (BOOL)hasQuickState;
/// Delete the instant-restart quick-save so the next launch boots clean.
- (void)deleteQuickState;

/// Save/restore to an arbitrary file path (named multi-slot saves). The path
/// MUST end in `.vasnap` (the core's loader checks the suffix + magic).
- (BOOL)saveStateToPath:(NSString *)path;
- (BOOL)loadStateFromPath:(NSString *)path;
/// A small screenshot of the current visible framebuffer, for save-state list
/// thumbnails. Reads the CPU-side RGBA texture; nil if no frame yet.
- (nullable UIImage *)framebufferThumbnail;

// MARK: Framebuffer (call from the render thread)
/// Locks the core texture and returns a pointer to the latest stable frame
/// (RGBA8888, AmigaFrameWidth×AmigaFrameHeight, stride AmigaFrameBytesPerRow).
/// `outFrameNr` receives the monotonic frame counter (compare to skip
/// re-uploads). MUST be balanced with `-unlockFrame`.
- (nullable const uint32_t *)lockFrame:(nullable int64_t *)outFrameNr;
- (void)unlockFrame;

/// Border-trimmed visible window inside the texture, as normalized UV
/// (0..1): left/top/right/bottom. Wraps the core's findInnerAreaNormalized,
/// which shrinks an overscan box to the active picture. Returns NO when the
/// detected box is degenerate (e.g. an all-border frame), leaving the
/// out-params untouched so callers can keep their last good crop.
- (BOOL)visibleCropLeft:(nullable double *)left
                    top:(nullable double *)top
                  right:(nullable double *)right
                 bottom:(nullable double *)bottom;

// MARK: Keyboard — `code` is a RAW AMIGA keycode (0x00–0x67), not ASCII.
- (void)keyDown:(uint8_t)code;
- (void)keyUp:(uint8_t)code;
- (void)keyReleaseAll;

// MARK: Mouse — port 0 (rear/mouse) or 1 (joystick port); relative pixels.
- (void)mousePort:(int)port moveDX:(double)dx dy:(double)dy;
- (void)mousePort:(int)port button:(int)button pressed:(BOOL)pressed; // 1=L 2=M 3=R

// MARK: Joystick — port 0 or 1.
- (void)joyPort:(int)port direction:(int)dir pressed:(BOOL)pressed;   // 0=up 1=down 2=left 3=right
- (void)joyPort:(int)port fire:(BOOL)pressed;

// MARK: Disk — insert/eject a floppy image (.adf/.adz/.dms/…) into df0..df3.
- (BOOL)insertDiskAtPath:(NSString *)path drive:(int)driveNr;
- (void)ejectDisk:(int)driveNr;

@end

NS_ASSUME_NONNULL_END
