#import <Foundation/Foundation.h>
#import <PVCoreObjCBridge/PVCoreObjCBridge.h>

@protocol ObjCBridgedCoreBridge;
@protocol PVGBASystemResponderClient;
typedef enum PVGBAButton: NSInteger PVGBAButton;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface PVmGBAGameCoreBridge: PVCoreObjCBridge <ObjCBridgedCoreBridge>
#pragma clang diagnostic pop

// Init
+ (instancetype)sharedInstance;
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Relay-owned observation boundary. Set/clear under the bridge monitor;
/// callbacks run on the emulation thread under that same monitor.
@property (nonatomic, copy, nullable) void (^relayFrameHandler)(void);
@property (nonatomic, copy, nullable) void (^relayResetHandler)(void);
/// Native regions: 0 bus peek, 1 work RAM, 2 internal RAM, 3 cartridge RAM.
/// Valid only under the bridge monitor. Short reads represent unavailable RAM.
- (NSUInteger)relayReadMemoryRegion:(uint32_t)region offset:(uint32_t)offset
                             buffer:(void * _Nonnull)buffer count:(NSUInteger)count;

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface PVmGBAGameCoreBridge (Controls) <PVGBASystemResponderClient>
#pragma clang diagnostic pop

- (oneway void)didPushGBAButton:(PVGBAButton)button forPlayer:(NSUInteger)player;
- (oneway void)didReleaseGBAButton:(PVGBAButton)button forPlayer:(NSUInteger)player;

@end

@interface PVmGBAGameCoreBridge (Cheats)

- (BOOL)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled;
- (void)resetCheatCodes;

@end

/// In-memory save-state serialization. Implemented in mGBAGameCoreBridge.m since
/// upstream; declared here so Swift callers (the Relay emulation adapter) can use it
/// without the file-based path. Callers must hold `@synchronized(bridge)` (the monitor
/// the emulation loop takes around `executeFrame`) when the core may be running.
@interface PVmGBAGameCoreBridge (StateSerialization)

- (NSData * _Nullable)serializeStateWithError:(NSError * _Nullable * _Nullable)outError;
- (BOOL)deserializeState:(NSData * _Nonnull)state withError:(NSError * _Nullable * _Nullable)outError;

/// A copy of the game's current battery save (SRAM/flash/EEPROM) straight from the
/// core's memory (`mCore.savedataClone`), independent of when the core flushes its
/// save file. Nil when the game has no save data. Added for Relay: the on-disk save
/// file lags the emulated memory by the core's clean-up interval, so Relay snapshots
/// the bytes themselves at safe points. Hold `@synchronized(bridge)` while calling.
- (NSData * _Nullable)relay_cloneBatterySave;

@end
