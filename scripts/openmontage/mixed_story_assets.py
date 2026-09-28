"""Read-only asset verification for the mixed-story 0.2 adapter.

Call immediately before copying assets into a private render directory. Returned
facts are evidence of this check, not authorization to reopen mutable paths later.
"""
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation
import hashlib
import json
import os
from pathlib import PurePosixPath
import stat
import subprocess

from PIL import Image
from mixed_story_contract import validate_document


@contextmanager
def open_asset(root_fd, relative):
    parts = PurePosixPath(relative).parts
    if not parts or relative.startswith('/') or '\\' in relative or any(p in ('.', '..', '') for p in relative.split('/')):
        raise ValueError('Unsafe asset path')
    directory = os.dup(root_fd)
    fd = None
    try:
        for part in parts[:-1]:
            next_directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = next_directory
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError('Asset is not a regular file')
        yield fd
    finally:
        if fd is not None:
            os.close(fd)
        os.close(directory)


def identity(fd):
    s = os.fstat(fd)
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def digest(fd):
    result = hashlib.sha256()
    offset = 0
    while block := os.pread(fd, 256 * 1024, offset):
        result.update(block)
        offset += len(block)
    return result.hexdigest()


def run_media(binary, arguments, fd):
    # The subprocess reads the verified inode, never a path resolved a second time.
    try:
        return subprocess.run([str(binary), *arguments], pass_fds=(fd,),
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60, check=True).stdout
    except (subprocess.SubprocessError, OSError) as error:
        raise ValueError('Media probe or decode failed') from error


def probe_media(fd, ffprobe, ffmpeg, asset):
    source = f'/dev/fd/{fd}'
    probe = json.loads(run_media(ffprobe, ['-v', 'error', '-show_streams', '-of', 'json', source], fd))
    streams = probe.get('streams', [])
    videos = [s for s in streams if s.get('codec_type') == 'video' and not s.get('disposition', {}).get('attached_pic', 0)]
    audios = [s for s in streams if s.get('codec_type') == 'audio']
    if asset['mediaType'].startswith('video/'):
        if not videos:
            raise ValueError('Video asset has no moving-video track')
        video = videos[0]
        try:
            duration = Decimal(str(video['duration']))
            if not duration.is_finite() or duration <= 0:
                raise ValueError('Invalid video duration')
            duration_ms = int(duration * 1000)
        except (KeyError, InvalidOperation, OverflowError) as error:
            raise ValueError('Video track duration unavailable') from error
        declared = asset['video']
        if declared['durationMs'] != duration_ms or declared['hasAudio'] != bool(audios):
            raise ValueError('Frozen video metadata disagrees with actual tracks')
        # Decode a real frame; an ffprobe-readable header alone is insufficient.
        # Requiring a frame is necessary: ffmpeg can exit successfully on empty input.
        pixels = run_media(ffmpeg, ['-v', 'error', '-xerror', '-i', source, '-map', f"0:{video['index']}",
                                   '-frames:v', '1', '-vf', 'scale=1:1', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], fd)
        if len(pixels) != 1:
            raise ValueError('Video has no decodable frame')
        if audios:
            verify_audio(fd, ffmpeg, audios[0]['index'])
        return {'durationMs': duration_ms, 'hasAudio': bool(audios)}
    if not audios:
        raise ValueError('Audio asset has no audio track')
    verify_audio(fd, ffmpeg, audios[0]['index'])
    return {'hasAudio': True}


def verify_audio(fd, ffmpeg, stream_index):
    source = f'/dev/fd/{fd}'
    pcm = run_media(ffmpeg, ['-v', 'error', '-xerror', '-i', source, '-map', f"0:{stream_index}",
                           '-t', '0.1', '-ac', '1', '-ar', '8000', '-f', 's16le', '-'], fd)
    if not pcm:
        raise ValueError('Audio has no decodable samples')


def validate_assets(document, package_root, *, ffprobe='ffprobe', ffmpeg='ffmpeg'):
    validate_document(document)
    result = {}
    root_fd = os.open(package_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for asset in document['assets']:
            with open_asset(root_fd, asset['relativePath']) as fd:
                before = identity(fd)
                sha = digest(fd)
                if sha != asset['renderFileSHA256']:
                    raise ValueError('Frozen asset checksum mismatch')
                media_type = asset['mediaType']
                if media_type.startswith('image/'):
                    with os.fdopen(os.dup(fd), 'rb') as image_file:
                        with Image.open(image_file) as image:
                            expected = {'image/jpeg': 'JPEG', 'image/png': 'PNG'}[media_type]
                            if image.format != expected or image.getexif().get(274, 1) != 1:
                                raise ValueError('Image format or orientation mismatch')
                            image.load()
                    facts = {}
                else:
                    facts = probe_media(fd, ffprobe, ffmpeg, asset)
                if identity(fd) != before or digest(fd) != sha:
                    raise ValueError('Asset changed during verification')
                with open_asset(root_fd, asset['relativePath']) as current:
                    if identity(current) != before:
                        raise ValueError('Asset path changed during verification')
                result[asset['assetID']] = dict(facts, sha256=sha, byteCount=before[2])
        return result
    finally:
        os.close(root_fd)
