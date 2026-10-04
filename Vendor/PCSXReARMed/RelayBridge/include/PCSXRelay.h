// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef PCSX_RELAY_H
#define PCSX_RELAY_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct PCSXRelayEmulator PCSXRelayEmulator;
typedef struct PCSXRelayFrameInfo { uint32_t width, height; uint64_t frameNumber; } PCSXRelayFrameInfo;
typedef struct PCSXRelayDiagnostics {
    double framesPerSecond, targetFramesPerSecond, longestFrameMilliseconds;
    uint64_t frames, audioFramesProduced, audioFramesRequested, audioFramesMissing, audioFramesDiscarded;
    uint32_t audioBufferedFrames;
} PCSXRelayDiagnostics;

// Process-global upstream state: a second simultaneous instance is refused.
// All calls synchronize with the owned emulation thread. The caller must keep
// the instance alive until all frame/audio clients have detached.
PCSXRelayEmulator* pcsx_relay_create(const char* firmwareDirectory, const char* saveDirectory);
void pcsx_relay_destroy(PCSXRelayEmulator* emu);
// Loads content held in Relay-managed storage; leaves the CPU paused.
int pcsx_relay_load(PCSXRelayEmulator* emu, const char* contentPath);
void pcsx_relay_set_paused(PCSXRelayEmulator* emu, int paused);
void pcsx_relay_set_speed(PCSXRelayEmulator* emu, unsigned percent);
void pcsx_relay_run_frame(PCSXRelayEmulator* emu);
void pcsx_relay_diagnostics(PCSXRelayEmulator* emu, PCSXRelayDiagnostics* out);

int pcsx_relay_lock_frame(PCSXRelayEmulator* emu, const uint8_t** pixels, PCSXRelayFrameInfo* info);
void pcsx_relay_unlock_frame(PCSXRelayEmulator* emu);
size_t pcsx_relay_read_audio(PCSXRelayEmulator* emu, int16_t* out, size_t frames);
void pcsx_relay_flush_audio(PCSXRelayEmulator* emu);
// Libretro's 16 button bits stay private to the Swift adapter.
void pcsx_relay_set_button(PCSXRelayEmulator* emu, unsigned bit, int pressed);
// Axes: left X/Y, right X/Y. Values are native signed 16-bit analog values.
void pcsx_relay_set_axis(PCSXRelayEmulator* emu, unsigned axis, int16_t value);
// 0 standard digital pad; 1 DualShock (game may enable analog mode).
int pcsx_relay_set_controller(PCSXRelayEmulator* emu, int analog);
int pcsx_relay_controller(PCSXRelayEmulator* emu);
// Emulates the controller's Analog button, without a magic button combination.
int pcsx_relay_set_analog_mode(PCSXRelayEmulator* emu, int enabled);
int pcsx_relay_analog_mode(PCSXRelayEmulator* emu);

// Two native 128 KiB cards concatenated, slot 1 then slot 2. The core never
// writes a card file: Relay's BatterySaveManager owns all persistence.
size_t pcsx_relay_card_size(void);
int pcsx_relay_copy_cards(PCSXRelayEmulator* emu, uint8_t* out, size_t size);
int pcsx_relay_load_cards(PCSXRelayEmulator* emu, const uint8_t* bytes, size_t size);

unsigned pcsx_relay_disc_count(PCSXRelayEmulator* emu);
unsigned pcsx_relay_disc_index(PCSXRelayEmulator* emu);
int pcsx_relay_switch_disc(PCSXRelayEmulator* emu, unsigned index);
// 1 when using the upstream GPL HLE implementation, not a proprietary BIOS.
int pcsx_relay_uses_hle(PCSXRelayEmulator* emu);

uint8_t* pcsx_relay_save_state(PCSXRelayEmulator* emu, size_t* size);
// Returns 1 on success, 0 for invalid data, -2 for a different BIOS.
int pcsx_relay_load_state(PCSXRelayEmulator* emu, const uint8_t* bytes, size_t size);
void pcsx_relay_free(void* bytes);
#ifdef __cplusplus
}
#endif
#endif
