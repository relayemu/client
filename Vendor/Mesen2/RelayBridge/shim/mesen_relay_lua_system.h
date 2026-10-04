/* SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Prefix header for the C sources of the Mesen 2 package (Package.swift
 * passes it with -include). Lua's os.execute calls system(), which Apple's
 * mobile platforms mark unavailable; stdlib.h is pulled in first so the real
 * declaration stays untouched, then every later call goes to the bridge's
 * stand-in, which always fails. Relay runs no Lua scripts.
 */
#ifndef MESEN_RELAY_LUA_SYSTEM_H
#define MESEN_RELAY_LUA_SYSTEM_H
#include <stdlib.h>
#ifdef __cplusplus
extern "C"
#endif
int mesen_relay_lua_system(const char* command);
#define system(command) mesen_relay_lua_system(command)
#endif
