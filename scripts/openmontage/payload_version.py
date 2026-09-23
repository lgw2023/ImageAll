"""Content identity for an embedded runtime, independent of prepare.py's stale stamp."""
import hashlib
import os
from pathlib import Path
import sys


def payload_version(root: Path) -> str:
    digest = hashlib.sha256()
    for directory, folders, files in os.walk(root, followlinks=False):
        folders[:] = sorted(name for name in folders if name != '__pycache__')
        for name in sorted(files + [name for name in folders if (Path(directory) / name).is_symlink()]):
            path = Path(directory) / name
            if path.suffix == '.pyc':
                continue
            relative = path.relative_to(root).as_posix()
            digest.update(relative.encode() + b'\0')
            if path.is_symlink():
                digest.update(b'link\0' + os.readlink(path).encode() + b'\0')
            else:
                digest.update(b'file\0')
                content = hashlib.sha256()
                with path.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        content.update(chunk)
                digest.update(content.digest())
    return digest.hexdigest()


if __name__ == '__main__':
    print(payload_version(Path(sys.argv[1])))
