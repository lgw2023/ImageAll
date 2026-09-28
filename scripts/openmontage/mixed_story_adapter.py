"""Private frozen input and lossless render props for story package 0.2.

The context must stay alive until the renderer finishes. No production capability
is advertised here; activation belongs to the versioned executor integration.
"""
from contextlib import contextmanager
import copy
import hashlib
import os
from pathlib import Path
import tempfile

from mixed_story_assets import identity, open_asset, validate_assets
from mixed_story_contract import validate_document

EXTENSIONS = {'image/jpeg': '.jpg', 'image/png': '.png', 'video/mp4': '.mp4',
              'video/quicktime': '.mov', 'audio/wav': '.wav', 'audio/mpeg': '.mp3', 'audio/mp4': '.m4a'}


def copy_frozen(fd, destination, expected_hash):
    before = identity(fd)
    digest = hashlib.sha256()
    offset = 0
    with destination.open('xb') as output:
        os.chmod(destination, 0o600)
        while block := os.pread(fd, 256 * 1024, offset):
            output.write(block)
            digest.update(block)
            offset += len(block)
        output.flush()
        os.fsync(output.fileno())
    if identity(fd) != before or digest.hexdigest() != expected_hash:
        raise ValueError('Source changed or checksum mismatch during freezing')
    return before


def render_props(document, root):
    paths = {a['assetID']: str(root / a['relativePath']) for a in document['assets']}
    story = copy.deepcopy(document['export'])
    story['schemaVersion'] = document['schemaVersion']
    story['chapters'] = []
    story['shots'] = []
    for chapter in document['chapters']:
        summary = {k: copy.deepcopy(v) for k, v in chapter.items() if k != 'shots'}
        summary['shotIDs'] = [s['shotID'] for s in chapter['shots']]
        story['chapters'].append(summary)
        for shot in chapter['shots']:
            rendered = copy.deepcopy(shot)
            rendered['id'] = rendered.pop('shotID')
            rendered['chapterSequenceIndex'] = rendered.pop('sequenceIndex')
            rendered.update(chapterID=chapter['chapterID'], chapterTitle=chapter['title'],
                            globalSequenceIndex=len(story['shots']))
            if shot['kind'] in ('photo', 'video'):
                rendered['src'] = paths[shot['assetID']]
                crop_safe = bool(shot['fit'].get('allowCrop') and shot['fit'].get('safeArea'))
                if shot['fit']['mode'] == 'cover' and not crop_safe:
                    rendered['fit'] = {'mode': 'contain', 'allowCrop': False}
                if shot['kind'] == 'photo' and shot['motion']['type'] in ('pan-left', 'pan-right') and not crop_safe:
                    rendered['motion'] = {'type': 'static'}
            story['shots'].append(rendered)
    if 'audio' in document:
        story['audio'] = dict(copy.deepcopy(document['audio']), src=paths[document['audio']['assetID']])
    return {'story_render': story}


@contextmanager
def prepared_story(document, package_root, *, work_parent=None, ffprobe='ffprobe', ffmpeg='ffmpeg'):
    """Yield (private root, props, verification facts), then remove only our directory."""
    document = copy.deepcopy(document)
    validate_document(document)
    root_fd = os.open(package_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with tempfile.TemporaryDirectory(prefix='mixed-story-', dir=work_parent) as task:
            private_root = Path(task)
            (private_root / 'assets').mkdir(mode=0o700)
            for index, asset in enumerate(document['assets']):
                relative = f"assets/{index:06d}{EXTENSIONS[asset['mediaType']]}"
                with open_asset(root_fd, asset['relativePath']) as fd:
                    before = copy_frozen(fd, private_root / relative, asset['renderFileSHA256'])
                    with open_asset(root_fd, asset['relativePath']) as current:
                        if identity(current) != before:
                            raise ValueError('Source path changed during freezing')
                asset['relativePath'] = relative
            facts = validate_assets(document, private_root, ffprobe=ffprobe, ffmpeg=ffmpeg)
            yield private_root, render_props(document, private_root), facts
    finally:
        os.close(root_fd)
