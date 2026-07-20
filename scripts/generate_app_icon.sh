#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
  print -u2 "usage: $0 SOURCE_ICON APPICONSET_DIRECTORY"
  exit 64
fi

source_icon=$1
appiconset=$2

if [[ ! -f "$source_icon" ]]; then
  print -u2 "app icon source does not exist: $source_icon"
  exit 66
fi

width=$(/usr/bin/sips -g pixelWidth "$source_icon" 2>/dev/null | /usr/bin/awk '/pixelWidth/ { print $2 }')
height=$(/usr/bin/sips -g pixelHeight "$source_icon" 2>/dev/null | /usr/bin/awk '/pixelHeight/ { print $2 }')

if [[ ! "$width" =~ ^[0-9]+$ || ! "$height" =~ ^[0-9]+$ ]]; then
  print -u2 "unable to read app icon dimensions: $source_icon"
  exit 65
fi

if [[ "$width" -ne "$height" ]]; then
  print -u2 "app icon source must be square; got ${width}x${height}: $source_icon"
  exit 65
fi

if [[ "$width" -lt 1024 ]]; then
  print -u2 "app icon source must be at least 1024x1024; got ${width}x${height}: $source_icon"
  exit 65
fi

/bin/mkdir -p "$appiconset"

generate_icon() {
  local pixels=$1
  local filename=$2
  /usr/bin/sips -z "$pixels" "$pixels" "$source_icon" --out "$appiconset/$filename" >/dev/null
}

generate_icon 16 AppIcon-16.png
generate_icon 32 AppIcon-16@2x.png
generate_icon 32 AppIcon-32.png
generate_icon 64 AppIcon-32@2x.png
generate_icon 128 AppIcon-128.png
generate_icon 256 AppIcon-128@2x.png
generate_icon 256 AppIcon-256.png
generate_icon 512 AppIcon-256@2x.png
generate_icon 512 AppIcon-512.png
generate_icon 1024 AppIcon-512@2x.png

print "Generated macOS app icon from $source_icon"
