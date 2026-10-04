#!/bin/zsh
# Rasterise Brand/*.svg into the app asset catalogs.
# Requires rsvg-convert (brew install librsvg). Run from anywhere:
#   Brand/generate-icons.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/Brand"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing (brew install librsvg)" >&2; exit 1; }
png() { rsvg-convert -w "$2" -h "$3" "$1" -o "$4"; }

# ---------- iOS / iPadOS: one 1024 image per appearance (iOS 18 single-size format)
IOS="$ROOT/Apps/RelayiOS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$IOS"
png "$B/relay-app-icon.svg"        1024 1024 "$IOS/icon-1024.png"
png "$B/relay-app-icon-dark.svg"   1024 1024 "$IOS/icon-1024-dark.png"
png "$B/relay-app-icon-tinted.svg" 1024 1024 "$IOS/icon-1024-tinted.png"
cat > "$IOS/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "icon-1024-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "icon-1024-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
printf '{"info":{"author":"xcode","version":1}}\n' > "$ROOT/Apps/RelayiOS/Assets.xcassets/Contents.json"

# ---------- macOS: the classic icon grid, 16…512 at 1x and 2x
MAC="$ROOT/Apps/RelayMac/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$MAC"
for s in 16 32 64 128 256 512 1024; do png "$B/relay-app-icon-macos.svg" $s $s "$MAC/icon-$s.png"; done
cat > "$MAC/Contents.json" <<'JSON'
{
  "images": [
    {
      "filename": "icon-16.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "16x16"
    },
    {
      "filename": "icon-32.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "16x16"
    },
    {
      "filename": "icon-32.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "32x32"
    },
    {
      "filename": "icon-64.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "32x32"
    },
    {
      "filename": "icon-128.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "128x128"
    },
    {
      "filename": "icon-256.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "128x128"
    },
    {
      "filename": "icon-256.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "256x256"
    },
    {
      "filename": "icon-512.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "256x256"
    },
    {
      "filename": "icon-512.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "512x512"
    },
    {
      "filename": "icon-1024.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "512x512"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSON
printf '{"info":{"author":"xcode","version":1}}\n' > "$ROOT/Apps/RelayMac/Assets.xcassets/Contents.json"

# ---------- tvOS: layered icon (parallax passes the baton) + Top Shelf
# XcodeGen (and Xcode) name the tvOS icon group "App Icon & Top Shelf Image";
# a group called AppIcon compiles to nothing at all, silently.
TV="$ROOT/Apps/RelayTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
layer() {  # layer <stack dir> <name> <order> <svg> <w1x> <h1x>
  local d="$1/$2.imagestacklayer/Content.imageset"
  mkdir -p "$d"
  png "$4" "$5" "$6" "$d/layer-$3.png"
  png "$4" "$(( $5 * 2 ))" "$(( $6 * 2 ))" "$d/layer-$3@2x.png"
  cat > "$d/Contents.json" <<JSON
{"images":[{"idiom":"tv","filename":"layer-$3.png","scale":"1x"},{"idiom":"tv","filename":"layer-$3@2x.png","scale":"2x"}],"info":{"author":"xcode","version":1}}
JSON
  printf '{"info":{"author":"xcode","version":1}}\n' > "$1/$2.imagestacklayer/Contents.json"
}
stack() {  # stack <dir> <w1x> <h1x>
  mkdir -p "$1"
  layer "$1" "back"  "back"  "$B/relay-tv-icon-back.svg"  "$2" "$3"
  layer "$1" "lead"  "lead"  "$B/relay-tv-icon-lead.svg"  "$2" "$3"
  layer "$1" "trail" "trail" "$B/relay-tv-icon-trail.svg" "$2" "$3"
  cat > "$1/Contents.json" <<JSON
{"layers":[{"filename":"trail.imagestacklayer"},{"filename":"lead.imagestacklayer"},{"filename":"back.imagestacklayer"}],"info":{"author":"xcode","version":1}}
JSON
}
rm -rf "$TV"; mkdir -p "$TV"
stack "$TV/App Icon.imagestack"           400 240
stack "$TV/App Icon - App Store.imagestack" 1280 768
shelf() {  # shelf <name> <svg> <w> <h> — each plate is its own composition; nothing is stretched
  local d="$TV/$1.imageset"; mkdir -p "$d"
  png "$2" "$3" "$4" "$d/shelf.png"
  png "$2" "$(( $3 * 2 ))" "$(( $4 * 2 ))" "$d/shelf@2x.png"
  cat > "$d/Contents.json" <<JSON
{"images":[{"idiom":"tv","filename":"shelf.png","scale":"1x"},{"idiom":"tv","filename":"shelf@2x.png","scale":"2x"}],"info":{"author":"xcode","version":1}}
JSON
}
shelf "Top Shelf Image"      "$B/relay-top-shelf.svg"      1920 720
shelf "Top Shelf Image Wide" "$B/relay-top-shelf-wide.svg" 2320 720
# A tvOS brand-asset group must name its members and their roles, or actool
# compiles the catalog without an app icon at all and says nothing.
cat > "$TV/Contents.json" <<'JSON'
{
  "assets" : [
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" },
    { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
printf '{"info":{"author":"xcode","version":1}}\n' > "$ROOT/Apps/RelayTV/Assets.xcassets/Contents.json"

# ---------- the app's accent: Ember, so system-drawn selection, tints and
# highlights are Relay's colour and not whatever the Mac's owner picked.
accent() {
  local d="$1/AccentColor.colorset"; mkdir -p "$d"
  cat > "$d/Contents.json" <<'JSON'
{
  "colors" : [
    { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0x25", "green" : "0x3D", "red" : "0xC9" } }, "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0x45", "green" : "0x6A", "red" : "0xFF" } }, "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
}
accent "$ROOT/Apps/RelayiOS/Assets.xcassets"
accent "$ROOT/Apps/RelayTV/Assets.xcassets"
accent "$ROOT/Apps/RelayMac/Assets.xcassets"

echo "brand assets generated"
