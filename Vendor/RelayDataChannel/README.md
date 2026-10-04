# Relay Transfer native transport

`upstream/` contains pinned source, excluding unused streamer MOV/MP3 samples. `RELAY_VENDOR.json`
records every revision, archive URL and SHA-256, including upstream gitlinks.
Relay build configuration and the C module map live in `RelayBuild/`.
The framework's sources and tooling build independently.

Build from a standalone client checkout before resolving RelayTransfer:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Scripts/relay-build-datachannel.py --jobs 2
```

Requires CMake and Ninja. Produces the ignored
`Packages/RelayTransfer/Artifacts/RelayDataChannel.xcframework`, arm64 only,
five slices (macOS, iOS/tvOS device + simulator). Logs/intermediate files go
to ignored `test-artefacts/transfer/native-build`. No upstream config is edited.
`MBEDTLS_USER_CONFIG_FILE` enables the SRTP-profile API required by libdatachannel
even when `NO_MEDIA=ON`; libsrtp and native WebSocket/media support are excluded.
The static bundle includes libdatachannel, libjuice, usrsctp and Mbed TLS;
plog/json are header dependencies. Linked licence records belong in the generated
client dataset, not hand-written generated outputs.

The chosen libjuice backend supports UDP ICE/TURN, not native TCP/TLS fallback.
