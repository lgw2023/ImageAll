"""Create a NEW synthetic-only directory for manual Mac video acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    if root == Path('/Volumes/HDD2') or Path('/Volumes/HDD2') in root.parents:
        parser.error('Protected media volume is not an acceptance output location')
    ffmpeg, probe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not probe:
        parser.error('FFmpeg and ffprobe are required')
    root.mkdir(parents=True, exist_ok=False)  # Never overwrite any existing directory.
    common = ['-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p']
    base = root / '01-audio-time-gps.mp4'
    run(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30:duration=3',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=3',
        '-af', 'volume=0.03', *common, '-c:a', 'aac', '-shortest',
        '-movflags', 'use_metadata_tags', '-metadata', 'creation_time=2024-06-15T08:30:00Z',
        '-metadata', 'com.apple.quicktime.location.ISO6709=+35.0000+139.0000/', str(base))
    shutil.copyfile(base, root / '02-exact-copy.mp4')
    run(ffmpeg, '-v', 'error', '-i', str(base), '-map', '0', '-c', 'copy',
        str(root / '03-same-stream-different-container.mov'))
    run(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=360x640:rate=30:duration=2',
        *common, '-an', str(root / '04-portrait-silent.mp4'))
    run(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'color=c=orange:s=640x360',
        '-frames:v', '1', '-update', '1', str(root / '05-photo.jpg'))
    entries = []
    for path in sorted(root.iterdir()):
        data = path.read_bytes()
        info = json.loads(subprocess.check_output([probe, '-v', 'error', '-show_format',
            '-show_streams', '-of', 'json', str(path)]))
        run(ffmpeg, '-v', 'error', '-i', str(path), '-f', 'null', '-')
        entries.append({'file': path.name, 'bytes': len(data),
            'sha256': hashlib.sha256(data).hexdigest(), 'probe': info})
    assert entries[0]['sha256'] == entries[1]['sha256']
    assert entries[0]['sha256'] != entries[2]['sha256']
    (root / 'fixture-manifest.json').write_text(json.dumps({
        'syntheticOnly': True, 'purpose': 'Manual acceptance inputs, not recorded UI results',
        'expected': {'exactGroup': [base.name, '02-exact-copy.mp4'],
            'differentContainerIsNotByteIdentical': '03-same-stream-different-container.mov',
            'captureTimeUTC': '2024-06-15T08:30:00Z', 'latitude': 35, 'longitude': 139,
            'portraitHasNoAudio': '04-portrait-silent.mp4'}, 'files': entries}, indent=2)+'\n')
    print(root)


if __name__ == '__main__':
    main()
