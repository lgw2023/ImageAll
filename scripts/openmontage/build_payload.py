"""Build from pinned source into a private cache; never patch the shared dependency seed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from integration_contract import CONTRACT, HERE, ROOT, validate
from payload_version import payload_version
import sys


def build(cache):
    seed = ROOT/'Vendor/OpenMontage/Runtime'
    archive = ROOT/'Vendor/OpenMontage/source.tar.gz'
    if hashlib.sha256(archive.read_bytes()).hexdigest() != CONTRACT['sourceArchiveSHA256']:
        raise RuntimeError('Unreviewed source archive')
    # Only dependencies come from the prepared seed. Engine source always comes from the archive.
    dependencies = [seed/'python', seed/'bin', seed/'dylibs', seed/'engine/remotion-composer/node_modules']
    identity = hashlib.sha256()
    for directory in dependencies:
        identity.update(payload_version(directory).encode())
    identity.update(archive.read_bytes())
    sources = {}
    for file in sorted(HERE.rglob('*')):
        if file.is_file() and file.suffix in ('.py','.json') and '__pycache__' not in file.parts:
            relative = file.relative_to(HERE).as_posix()
            sources[relative] = file.read_bytes()
            identity.update(relative.encode()+b'\0'+sources[relative])
    cache.mkdir(parents=True, exist_ok=True)
    target = cache/identity.hexdigest()
    marker = target/'build.json'
    if marker.exists():
        validate(target/'payload/engine')
        if json.loads(marker.read_text())['payloadVersion'] != payload_version(target/'payload'):
            raise RuntimeError('Cached runtime changed; remove this build cache and rebuild')
        return target
    stage = Path(tempfile.mkdtemp(prefix='.building-', dir=cache))
    try:
        payload = stage/'payload';payload.mkdir()
        engine = payload/'engine';engine.mkdir()
        with tarfile.open(archive) as source: source.extractall(engine, filter='data')
        for source, destination in [(seed/'python',payload/'python'),(seed/'bin',payload/'bin'),(seed/'dylibs',payload/'dylibs'),(dependencies[-1],engine/'remotion-composer/node_modules')]:
            subprocess.run(['/bin/cp','-cR',str(source),str(destination)],check=True)
        # Freeze patch inputs too: another workspace session may edit scripts while dependencies copy.
        snapshot = stage/'integration-sources'
        for relative, data in sources.items():
            file = snapshot/relative; file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(data)
        if json.loads(sources['integration-contract.json']) != CONTRACT:
            raise RuntimeError('Contract changed during build; retry with the new contract')
        subprocess.run([sys.executable,'-B','-c','import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); import config_patch; config_patch.apply(Path(sys.argv[2]))',str(snapshot),str(engine)],check=True)
        validate(engine)
        (payload/'integration-contract.json').write_text(json.dumps(CONTRACT,sort_keys=True,indent=2)+'\n')
        critical = {}
        for folder in ('lib', 'scripts', 'schemas', 'remotion-composer/src'):
            for file in sorted((engine/folder).rglob('*')):
                if file.is_file() and not file.is_symlink() and '__pycache__' not in file.parts:
                    critical[file.relative_to(payload).as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
        critical['integration-contract.json'] = hashlib.sha256((payload/'integration-contract.json').read_bytes()).hexdigest()
        (stage/'runtime-integrity.json').write_text(json.dumps(critical,sort_keys=True)+'\n')
        version=payload_version(payload)
        (stage/'payload-version').write_text(version+'\n')
        (stage/'build.json').write_text(json.dumps({'inputIdentity':target.name,'payloadVersion':version},sort_keys=True)+'\n')
        try: stage.rename(target)
        except OSError:
            if not marker.exists(): raise
            if json.loads(marker.read_text())['payloadVersion'] != version: raise RuntimeError('Nonreproducible concurrent build')
        return target
    finally:
        if stage.exists(): shutil.rmtree(stage)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,required=True)
    print(build(p.parse_args().cache))
