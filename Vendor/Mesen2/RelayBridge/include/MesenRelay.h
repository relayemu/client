// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MesenRelay — Relay's C interface to the Mesen 2 emulator.
//
// One MesenRelayEmulator is one Mesen `Emulator` with Relay's rendering, audio
// and input providers attached. The C++ world stays behind this header; the
// Swift driver (RelayMesenAdapter) sees only these functions. Thread contract:
// Mesen runs the machine on its own thread from `mesen_relay_load_rom` until
// `mesen_relay_stop`; every function here may be called from any thread and
// synchronises against that thread itself.
#ifndef MESEN_RELAY_H
#define MESEN_RELAY_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MesenRelayEmulator MesenRelayEmulator;

/// Callback event: 0 = completed emulated frame, 1 = machine reset.
/// Invoked synchronously on the machine thread; observer must not reenter the
/// Swift CoreHandle or retain a memory pointer after returning.
typedef void (*MesenRelayObserver)(void* context, int event);
void mesen_relay_set_observer(MesenRelayEmulator* emu, MesenRelayObserver observer, void* context);
/// Region IDs follow Relay's AchievementMemoryRegion, never service addresses.
/// Call only inside the observer or with_machine callback.
size_t mesen_relay_read_memory(MesenRelayEmulator* emu, uint32_t region, uint32_t offset, uint8_t* out, size_t size);
void mesen_relay_with_machine(MesenRelayEmulator* emu, void (*operation)(void*), void* context);

/// Mirrors Mesen's `ConsoleType`; the raw values are Mesen's own.
typedef enum MesenRelayConsole {
    MesenRelayConsoleSnes = 0,
    MesenRelayConsoleGameboy = 1,
    MesenRelayConsoleNes = 2,
    MesenRelayConsolePcEngine = 3,
    MesenRelayConsoleSms = 4,
    MesenRelayConsoleGba = 5,
    MesenRelayConsoleWs = 6,
    MesenRelayConsoleNone = -1,
} MesenRelayConsole;

typedef struct MesenRelayFrameInfo {
    uint32_t width;
    uint32_t height;
    uint32_t frameNumber;
} MesenRelayFrameInfo;

/// Creates an emulator whose files live under the given folders (created if
/// missing). `saveFolder` receives battery saves, `firmwareFolder` is where
/// Mesen looks for system files it does not ship.
MesenRelayEmulator* mesen_relay_create(const char* homeFolder,
                                       const char* saveFolder,
                                       const char* saveStateFolder,
                                       const char* firmwareFolder);
void mesen_relay_destroy(MesenRelayEmulator* emu);

/// Loads and powers on the game, then holds it paused. Returns 1 on success.
int mesen_relay_load_rom(MesenRelayEmulator* emu, const char* romPath);
MesenRelayConsole mesen_relay_console(MesenRelayEmulator* emu);
/// Powers off, writes the battery save, joins the emulation thread.
void mesen_relay_stop(MesenRelayEmulator* emu);
void mesen_relay_set_paused(MesenRelayEmulator* emu, int paused);
int mesen_relay_is_paused(MesenRelayEmulator* emu);
/// Percent of real time; 0 means as fast as possible.
void mesen_relay_set_speed_percent(MesenRelayEmulator* emu, uint32_t percent);
/// Frames delivered per second, measured (not the console's nominal rate).
double mesen_relay_fps(MesenRelayEmulator* emu);
uint32_t mesen_relay_frame_count(MesenRelayEmulator* emu);

// Video. The bridge keeps a copy of the last completed frame as RGBX8
// (bytes R, G, B, X in memory). `lock` returns 1 and the frame when one exists;
// `unlock` must follow every successful lock, on the same thread.
int mesen_relay_lock_frame(MesenRelayEmulator* emu, const uint8_t** pixels, MesenRelayFrameInfo* info);
void mesen_relay_unlock_frame(MesenRelayEmulator* emu);

// Audio: interleaved stereo int16 at `mesen_relay_audio_sample_rate` Hz.
uint32_t mesen_relay_audio_sample_rate(MesenRelayEmulator* emu);
/// Copies up to `frames` stereo frames into `out`, zero-filling the rest;
/// returns the number of frames that came from the core.
size_t mesen_relay_read_audio(MesenRelayEmulator* emu, int16_t* out, size_t frames);
size_t mesen_relay_audio_buffered_frames(MesenRelayEmulator* emu);
void mesen_relay_flush_audio(MesenRelayEmulator* emu);

// Input: `bit` is the console's own button index (Mesen's `Buttons` enum of
// the standard controller for that console); the driver owns the mapping.
void mesen_relay_set_button(MesenRelayEmulator* emu, uint8_t port, uint8_t bit, int pressed);

// Battery save: forces the core to write its persistent memory now and returns
// a malloc'd copy of the bytes (free with `mesen_relay_free`), or NULL when the
// game has none. The file name the core uses is available for storage code.
uint8_t* mesen_relay_copy_battery(MesenRelayEmulator* emu, size_t* size);
/// Base name of the battery file(s) Mesen writes in `saveFolder`, without extension.
const char* mesen_relay_rom_name(MesenRelayEmulator* emu);

// Save states: the whole machine, in Mesen's own serialised form behind a
// small Relay header (console type and Mesen's state format version).
uint8_t* mesen_relay_serialize_state(MesenRelayEmulator* emu, size_t* size);
/// Returns 1 on success. The machine must be paused or stopped between frames;
/// the bridge takes Mesen's emulator lock itself.
int mesen_relay_deserialize_state(MesenRelayEmulator* emu, const uint8_t* bytes, size_t size);
/// Runs exactly one frame while paused (refreshes the picture after a restore).
void mesen_relay_run_single_frame(MesenRelayEmulator* emu);

/// WonderSwan only: 1 while the running game asks to be held upright (the
/// picture is then delivered rotated and the two button clusters swap roles).
int mesen_relay_ws_vertical(MesenRelayEmulator* emu);

void mesen_relay_free(void* pointer);

/// Routes Mesen's own log lines to stdout (diagnostics; off by default).
void mesen_relay_set_logging(int enabled);
/// Lua os.execute stand-in (see Package.swift); always fails.
int mesen_relay_lua_system(const char* command);

#ifdef __cplusplus
}
#endif

#endif
