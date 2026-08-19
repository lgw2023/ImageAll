#!/bin/zsh
emulate -L zsh
set -euo pipefail

bridge_dir=${0:A:h}
output_dir=${1:-"${bridge_dir}/build"}
mkdir -p "${output_dir}"

app_bundle="${output_dir}/Photos Exit Exporter.app"
contents_dir="${app_bundle}/Contents"
macos_dir="${contents_dir}/MacOS"
mkdir -p "${macos_dir}"
cp "${bridge_dir}/PhotoKitExporter-Info.plist" "${contents_dir}/Info.plist"

output_binary="${macos_dir}/photos-exit-exporter"
xcrun swiftc \
    -parse-as-library \
    -framework AppKit \
    -framework Photos \
    -framework CryptoKit \
    "${bridge_dir}/PhotoKitExporter.swift" \
    -o "${output_binary}"

codesign --force --deep --sign - "${app_bundle}" >/dev/null
print -r -- "${output_binary}"
