// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MelonRelay — Relay's C interface to the melonDS core.
//
// One MelonRelayEmulator is one melonDS `NDS` run on a thread the bridge
// owns, with Relay's Platform implementation underneath. Every function may
// be called from any thread; the bridge synchronises against its own thread.
#ifndef MELON_RELAY_H
#define MELON_RELAY_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MelonRelayEmulator MelonRelayEmulator;

typedef void (*MelonRelayObserver)(void* context, int event);
/// Event 0 after every emulated frame, synchronously under the machine lock.
void melon_relay_set_observer(MelonRelayEmulator* emu, MelonRelayObserver observer, void* context);
/// Region IDs follow Relay's AchievementMemoryRegion. Only callable while the
/// machine is locked by the observer or with_machine callback.
size_t melon_relay_read_memory(MelonRelayEmulator* emu, uint32_t region, uint32_t offset, uint8_t* out, size_t size);
void melon_relay_with_machine(MelonRelayEmulator* emu, void (*operation)(void*), void* context);

/// Bits of the pressed-button mask, melonDS's own KEYINPUT order.
typedef enum MelonRelayButton {
    MelonRelayButtonA = 0,
    MelonRelayButtonB = 1,
    MelonRelayButtonSelect = 2,
    MelonRelayButtonStart = 3,
    MelonRelayButtonRight = 4,
    MelonRelayButtonLeft = 5,
    MelonRelayButtonUp = 6,
    MelonRelayButtonDown = 7,
    MelonRelayButtonR = 8,
    MelonRelayButtonL = 9,
    MelonRelayButtonX = 10,
    MelonRelayButtonY = 11,
} MelonRelayButton;

typedef struct MelonRelayFrameInfo {
    uint32_t width;
    uint32_t height;
    uint32_t frameNumber;
} MelonRelayFrameInfo;

/// `saveFolder` receives the battery save as `<rom>.sav`; `localFolder` is
/// where melonDS keeps its own files (created if missing).
MelonRelayEmulator* melon_relay_create(const char* localFolder, const char* saveFolder);
void melon_relay_destroy(MelonRelayEmulator* emu);

/// Loads the game with the built-in free BIOS and generated firmware (no
/// Nintendo files) and holds it paused. Returns 1 on success.
int melon_relay_load_rom(MelonRelayEmulator* emu, const char* romPath);
void melon_relay_stop(MelonRelayEmulator* emu);
void melon_relay_set_paused(MelonRelayEmulator* emu, int paused);
int melon_relay_is_paused(MelonRelayEmulator* emu);
/// Percent of real time; 0 means as fast as possible.
void melon_relay_set_speed_percent(MelonRelayEmulator* emu, uint32_t percent);
/// Frames completed per second, measured (not the DS's nominal 59.8261).
double melon_relay_fps(MelonRelayEmulator* emu);
uint32_t melon_relay_frame_count(MelonRelayEmulator* emu);

// Video: two 256×192 screens (0 = top, 1 = bottom), RGBX8. `lock` returns 1
// with the last completed frame; `unlock` must follow every successful lock.
int melon_relay_lock_frame(MelonRelayEmulator* emu, int screen, const uint8_t** pixels, MelonRelayFrameInfo* info);
void melon_relay_unlock_frame(MelonRelayEmulator* emu);

// Audio: interleaved stereo int16 at `melon_relay_audio_sample_rate` Hz.
uint32_t melon_relay_audio_sample_rate(MelonRelayEmulator* emu);
size_t melon_relay_read_audio(MelonRelayEmulator* emu, int16_t* out, size_t frames);
size_t melon_relay_audio_buffered_frames(MelonRelayEmulator* emu);
void melon_relay_flush_audio(MelonRelayEmulator* emu);

// Input
void melon_relay_set_button(MelonRelayEmulator* emu, MelonRelayButton button, int pressed);
/// Bottom-screen pixel coordinates (0–255, 0–191).
void melon_relay_touch(MelonRelayEmulator* emu, uint16_t x, uint16_t y);
void melon_relay_release_touch(MelonRelayEmulator* emu);

// Battery save: the cartridge's save memory as the core holds it now
// (malloc'd, free with `melon_relay_free`), or NULL when the game has none.
uint8_t* melon_relay_copy_battery(MelonRelayEmulator* emu, size_t* size);

// Save states: melonDS's own format behind a small Relay header.
uint8_t* melon_relay_serialize_state(MelonRelayEmulator* emu, size_t* size);
int melon_relay_deserialize_state(MelonRelayEmulator* emu, const uint8_t* bytes, size_t size);
/// Runs exactly one frame while paused.
void melon_relay_run_single_frame(MelonRelayEmulator* emu);

void melon_relay_free(void* pointer);
/// Routes melonDS's log lines to stdout (diagnostics; off by default).
void melon_relay_set_logging(int enabled);

#ifdef __cplusplus
}
#endif

#endif
