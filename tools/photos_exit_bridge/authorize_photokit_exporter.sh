#!/bin/zsh
emulate -L zsh
set -euo pipefail

bridge_dir=${0:A:h}
app_bundle=${1:-"${bridge_dir}/build/Photos Exit Exporter.app"}

if [[ ! -d "${app_bundle}" ]]; then
    print -u2 -r -- "error=exporter_app_missing"
    exit 2
fi

open -W -n "${app_bundle}" --args authorize
