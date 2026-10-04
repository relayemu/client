// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
// Shared between Platform.cpp and MelonRelay.cpp; not part of the public API.
#pragma once
#include <string>
#include <cstdint>

std::string melonRelayLocalFolder();
bool melonRelayLoggingEnabled();
void melonRelayOnBatteryWrite(void* userdata, const uint8_t* bytes, uint32_t length);
void melonRelayOnSignalStop(void* userdata, int reason);
