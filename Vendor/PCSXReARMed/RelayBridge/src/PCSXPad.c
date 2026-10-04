// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
// Access the physical controller mode without duplicating its state machine.
#include "../../libpcsxcore/pad.c"
int relay_pcsx_pad_mode(void) { return g.pads[0].ds.padMode; }
int relay_pcsx_set_pad_mode(int enabled) {
    if (g.pads[0].ds.padMode != !!enabled) padToggleAnalog(0);
    return g.pads[0].ds.padMode == !!enabled;
}

// Upstream freezes pads[] but omits the in-flight request and replug timer.
// Store those in Relay's envelope so a fresh instance resumes the same wire.
void relay_pcsx_pad_wire_state(unsigned *request, unsigned *replug) {
    *request = (unsigned)g.reqPos; *replug = g.replug_frame;
}
void relay_pcsx_restore_pad_wire(unsigned request, unsigned replug) {
    g.reqPos = (int)request; g.replug_frame = replug;
}
