# Relay brand assets

The client source for Relay's mark, wordmark and app icons. The geometry and generator are described below.

## The Baton

Two equal capsules on a −45° diagonal: one hand finishing, one hand starting. Read
literally it is a baton being passed; read abstractly it is one line continuing
through a break — play that continues on the next screen.

Construction, in the canonical 100 × 100 box:

| | |
|---|---|
| Group transform | `translate(50 52) rotate(-45)` |
| Lead capsule | x −46 → −2, y −18 → −4, corner radius 7 (44 × 14) |
| Trail capsule | x 2 → 46, y 4 → 18, corner radius 7 (44 × 14) |
| Gap along the bar | 4 units |
| Perpendicular offset | 22 units |
| Rotated bounding box | 90.51 × 90.51, centred at (50, 52) |

The 2-unit downward shift of the group is the optical centre; the mark is not
centred geometrically because it does not look centred when it is.

Colour rule: **the lead capsule takes the surface's contrast colour, the trail
capsule is always Ember.** On Ink the lead is Off-White `#F5F2EE`; on paper it is
Ink `#1A1816`. Ember is `#FF6A45` on dark grounds and `#C93D25` on light ones; the
website's pen red `#D9432A` is the same colour in the site's own palette.

Rules: minimum size 16 pt; below that use one capsule (the "dash") as a bullet.
Clear space equals the mark's height on all sides. Never rotate it to another
angle, never add a third capsule, never outline it, never place it over game
artwork.

## Two renderings, one geometry

| Rendering | File | Where |
|---|---|---|
| Geometric | `relay-mark.svg` | app icons, favicon, touch icon, the app's `RelayMark` |
| Drawn (pen) | `relay-mark-drawn.svg` | the website's paper surfaces, the social image, the app's illustrations |

The drawn rendering is the same boxes traced with a pen. It is a voice, not a
second identity: anywhere an *icon* appears — a browser tab, a Home Screen, a Dock
— the geometric rendering is used, because a wobbling outline is illegible at
16 pt and reads as unfinished at 40 pt.

## Files

| File | Purpose |
|---|---|
| `relay-mark.svg` | the mark, geometric, `--relay-lead` / `--relay-trail` overridable |
| `relay-mark-drawn.svg` | the mark, pen |
| `relay-wordmark.svg` | horizontal lockup; the wordmark is SF Pro Display Semibold, tracking −2 % |
| `relay-app-icon.svg` | iOS/iPadOS "Any Appearance" and the source for macOS |
| `relay-app-icon-dark.svg` | iOS/iPadOS dark appearance — no ground, the system draws it |
| `relay-app-icon-tinted.svg` | iOS/iPadOS tinted appearance — greyscale, no ground |
| `relay-app-icon-macos.svg` | the macOS icon grid: 824 pt shape in a 1024 pt canvas, radius 185.4 |
| `relay-tv-icon-{back,lead,trail}.svg` | the tvOS layered icon; parallax separates the two capsules, so the pass moves |
| `relay-top-shelf.svg` | the default tvOS Top Shelf plate |
| `relay-favicon.svg` | browser tab and touch icon: the app icon, squared for small sizes |

## Regenerating

```
Brand/generate-icons.sh
```

Requires `rsvg-convert` (`brew install librsvg`). It writes:

- `Apps/RelayiOS/Assets.xcassets` — `AppIcon` (default, dark, tinted) and `AccentColor`
- `Apps/RelayMac/Assets.xcassets` — `AppIcon` (16…1024) and `AccentColor`
- `Apps/RelayTV/Assets.xcassets` — `AppIcon.brandassets` (layered icon, App Store icon, both Top Shelf images) and `AccentColor`
`Brand/generate-icons.sh` writes only inside this repository.

## Trademark

The Relay name and mark are covered by `LICENSE.md` and the root `TRADEMARKS.md`.
Nothing here uses a console
manufacturer's colours, logotypes or hardware shapes.
