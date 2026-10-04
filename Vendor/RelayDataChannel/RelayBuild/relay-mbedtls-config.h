// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

// libdatachannel references DTLS SRTP profile APIs even in its NO_MEDIA build.
// Mbed TLS loads this through MBEDTLS_USER_CONFIG_FILE; upstream stays unchanged.
#define MBEDTLS_SSL_DTLS_SRTP
