// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#include "../../plugins/dfsound/freeze.c"

// Relay accepts only this pinned core's own portable format, not historical
// plugin variants. Check lengths and sample geometry before upstream restore
// can use a sample count for division or read past the XA/CDDA array.
int relay_pcsx_validate_spu_state(const unsigned char *bytes, size_t length) {
    SPUFreeze_t header;
    SPUOSSFreeze_t state;
    const size_t offset = sizeof(header) + 512 * 1024;
    if (length != offset + sizeof(state)) return 0;
    memcpy(&header, bytes, sizeof(header));
    memcpy(&state, bytes + offset, sizeof(state));
    if (header.Size != length || memcmp(header.PluginName, "PBOSS\0", 6) || header.PluginVersion != 5) return 0;
    if (state.cdda_left > sizeof(state.xa.pcm) / 4 || state.rvb_cur >= 0x40000) return 0;
    if (state.xa_left && state.xa.nsamples) {
        if (state.xa.nsamples < 0 || (state.xa.stereo != 0 && state.xa.stereo != 1) ||
            (state.xa.freq != 18900 && state.xa.freq != 37800) ||
            (size_t)state.xa.nsamples > sizeof(state.xa.pcm) / (state.xa.stereo ? 4 : 2)) return 0;
    }
    for (unsigned i = 0; i < MAXCHAN; i++) {
        const ADSRInfoEx_orig *adsr = &state.s_chan[i].ADSRX;
        if (adsr->State < ADSR_ATTACK || adsr->State > ADSR_RELEASE ||
            (unsigned)adsr->AttackRate > 127 || (unsigned)adsr->DecayRate > 15 ||
            (unsigned)adsr->SustainRate > 127 || (unsigned)adsr->ReleaseRate > 31) return 0;
    }
    return 1;
}
