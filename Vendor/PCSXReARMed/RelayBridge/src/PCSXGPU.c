// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
// Match upstream's per-object flags without modifying the pinned source.
#define NEON_BUILD
#define TEXTURE_CACHE_4BPP
#define TEXTURE_CACHE_8BPP
#include "../../plugins/gpu_neon/psx_gpu_if.c"
