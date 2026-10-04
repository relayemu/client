// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct RelayCHD RelayCHD;
typedef struct RelayCHDTrack {
    uint32_t frames, pregap, postgap;
    // 1 MODE1/2352, 2 MODE2/2352, 3 AUDIO.
    uint32_t mode;
    int storedPregap;
} RelayCHDTrack;
// Bounded read-only CHD v5 CD reader, independent of emulation state.
RelayCHD* relay_chd_open(const char* path);
void relay_chd_close(RelayCHD* reader);
uint32_t relay_chd_track_count(const RelayCHD* reader);
int relay_chd_track(const RelayCHD* reader, uint32_t index, RelayCHDTrack* out);
// Exactly 2352 bytes, with audio samples converted to BIN little endian.
int relay_chd_read_sector(RelayCHD* reader, uint32_t track, uint32_t sector, uint8_t* out);
#ifdef __cplusplus
}
#endif
