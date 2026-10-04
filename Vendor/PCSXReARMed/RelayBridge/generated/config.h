// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "../../include/config.h"
// Apple's container paths, especially CoreSimulator paths, routinely exceed
// upstream's 256-byte default. All core translation units use this same ABI.
#undef MAXPATHLEN
#define MAXPATHLEN 1024
