// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
// Relay's rendering of upstream's version.h.in (CMake configure_file output);
// values from CMakeLists.txt at the vendored commit (RELAY_VENDOR.json).
#ifndef VERSION_H
#define VERSION_H

#define MELONDS_URL            "https://melonds.kuribo64.net/"

#define MELONDS_VERSION_BASE   "1.1"
#define MELONDS_VERSION_SUFFIX ""
#define MELONDS_VERSION        MELONDS_VERSION_BASE MELONDS_VERSION_SUFFIX

#endif // VERSION_H
