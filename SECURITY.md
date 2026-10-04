# Security policy

Relay treats everything a player imports as untrusted: archives are extracted
into staging with path, size, count and ratio limits; game files are
identified from their own bytes; cloud records are validated and assets are
verified by SHA-256 before installation. If you find a way past any of that,
please tell us privately first.

## Reporting a vulnerability

Write to **security@relayemu.app**. Do not open a public issue for a
vulnerability.

Please include the platform and Relay version, the steps to reproduce, and,
if the issue involves a crafted file, the file or a description of how to make
one. We do not need, and ask you not to send, any copyrighted game.

## What to expect

- An acknowledgement within a few days.
- A fix in the next release for anything that lets a file escape the app's
  container, corrupt a save, or execute code; a note in the release notes
  crediting you unless you prefer otherwise.
- No bounty programme at this time.

## Scope

In scope: the Relay client on iPhone, iPad, Apple TV and Mac; the import
pipeline; the save and save-state formats; and CloudKit record handling.
Out of scope: the emulator cores' emulation accuracy, and
behaviour that requires a jailbroken or modified device.
