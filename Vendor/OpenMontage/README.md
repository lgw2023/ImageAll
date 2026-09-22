# OpenMontage local engine

Vendored source snapshot: `e47d9ccc4b0deaa7b792986770cfa5a6c84e2dd0`.
Archive SHA-256: `59438ce446c2916cf31a0952dddec1870cfd5b5fa9971bfb534031720aed097a`.
Contains the local executor, renderer, schemas, templates, and their source dependencies;
excludes user projects, credentials, task queues and outputs. AGPL-3.0 license is in the archive.

`python3 scripts/openmontage/prepare.py` prepares the ignored runtime payload before an Xcode build.
The build embeds and signs a separate local helper application. Runtime dependencies are
prepared at development time; the App never downloads or installs packages on launch.

On this arm64 development machine, prepare with:

```sh
python3 scripts/openmontage/prepare.py \
  --python-home "$HOME/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none" \
  --node-modules /Volumes/SSD1/OpenMontage/remotion-composer/node_modules
```

Python packages are pinned in `python-requirements.lock`; Remotion's source archive includes
its package lock, checked against the supplied dependency tree's parent. Node/FFmpeg and
recursive dylibs are copied from the build machine and relocated. The generated full payload
hash inventory is in `runtime-manifest.json`. This packaging currently targets this Mac's
architecture; cross-platform/universal release packaging is outside this local integration.
