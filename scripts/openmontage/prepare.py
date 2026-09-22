#!/usr/bin/env python3
"""Prepare a relocatable local engine payload; run explicitly before building ImageAll."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile
P = pathlib.Path
root = P(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--python-home', type=P, required=True, help='python-build-standalone 3.12 distribution')
p.add_argument('--node-modules', type=P, required=True, help='Installed, lockfile-matching Remotion dependencies including headless Chrome')
a = p.parse_args()
out = root/'Vendor/OpenMontage/Runtime'
if out.exists(): raise SystemExit('Runtime already exists; move it aside before preparing a new payload')
out.mkdir()
engine = out/'engine'; engine.mkdir()
archive = root/'Vendor/OpenMontage/source.tar.gz'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == '59438ce446c2916cf31a0952dddec1870cfd5b5fa9971bfb534031720aed097a'
with tarfile.open(archive) as t: t.extractall(engine, filter='data')
shutil.copytree(a.python_home, out/'python', symlinks=True)
subprocess.run(['uv','pip','install','--break-system-packages','--python',str(out/'python/bin/python3.12'),'-r',str(root/'Vendor/OpenMontage/python-requirements.lock')],check=True)
assert hashlib.sha256((a.node_modules.parent/'package-lock.json').read_bytes()).digest() == hashlib.sha256((engine/'remotion-composer/package-lock.json').read_bytes()).digest(), 'Remotion lockfile mismatch'
shutil.copytree(a.node_modules, engine/'remotion-composer/node_modules', symlinks=True, ignore=shutil.ignore_patterns('.cache'))
# Copy binaries and recursively relocate their non-system dylibs.
bin_dir = out/'bin'; bin_dir.mkdir(); libs = out/'dylibs'; libs.mkdir()
seen = {}
def native(source, target):
    source = source.resolve()
    if source in seen: return seen[source]
    seen[source] = target
    shutil.copy2(source,target); target.chmod(0o755)
    lines = subprocess.check_output(['otool','-L',str(source)], text=True).splitlines()[1:]
    for line in lines:
        dep = line.strip().split(' (')[0]
        resolved = dep
        if dep.startswith('@rpath/'):
            candidates = [source.parent/dep[7:], source.parent.parent/'lib'/dep[7:]]
            resolved = str(next((x for x in candidates if x.exists()), P(dep)))
            if resolved.startswith('@'): raise RuntimeError('Unresolved dependency '+dep+' in '+str(source))
        elif dep.startswith('@loader_path/'):
            resolved = str(source.parent/dep[len('@loader_path/'):])
        if resolved.startswith('/opt/') or resolved.startswith('/usr/local/'):
            dest = native(P(resolved), libs/P(resolved).name)
            relative = os.path.relpath(dest, target.parent)
            subprocess.run(['install_name_tool','-change',dep,'@loader_path/'+relative,str(target)],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(['codesign','--force','--sign','-',str(target)],check=True,stderr=subprocess.DEVNULL)
    return target
for name in ['node','ffmpeg','ffprobe']: native(P(shutil.which(name)),bin_dir/name)
# Deliberately local-only npx shim: no npm downloads or execution of arbitrary packages.
(bin_dir/'npx').write_text('#!/bin/sh\n[ "$1" = "remotion" ] || exit 64\nshift\nbase="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"\nexec "$base/bin/node" "$base/engine/remotion-composer/node_modules/@remotion/cli/remotion-cli.js" "$@"\n')
(bin_dir/'npx').chmod(0o755)
# Include dependency license files already present in distributions. Inventory all payload bytes.
entries={}
for f in sorted(out.rglob('*')):
    if f.is_file() and not f.is_symlink(): entries[str(f.relative_to(out))]=hashlib.sha256(f.read_bytes()).hexdigest()
manifest=root/'Vendor/OpenMontage/runtime-manifest.json'
manifest.write_text(json.dumps(entries,sort_keys=True,separators=(',',':')))
(root/'Vendor/OpenMontage/runtime-version').write_text(hashlib.sha256(manifest.read_bytes()).hexdigest())
print('Prepared',out)
