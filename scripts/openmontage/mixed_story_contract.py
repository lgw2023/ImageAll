"""Reviewable v0.2 document contract, before executor capability activation.

This validates document semantics only. Runtime asset hash, path, decoding, and
permission checks remain mandatory when integrating it with the adapter.
"""
import json
from pathlib import Path
from jsonschema import Draft202012Validator

SCHEMA_PATH = Path(__file__).parent / 'schemas/story_render_package_v0_2.schema.json'
SCHEMA = json.loads(SCHEMA_PATH.read_text())
VALIDATOR = Draft202012Validator(SCHEMA)


def validate_document(document):
    # JSON Schema implementations may otherwise accept NaN as a number.
    json.dumps(document, allow_nan=False)
    VALIDATOR.validate(document)
    assets = {a['assetID']: a for a in document['assets']}
    if len(assets) != len(document['assets']):
        raise ValueError('Duplicate asset identity')
    chapters = document['chapters']
    if len({c['chapterID'] for c in chapters}) != len(chapters):
        raise ValueError('Duplicate chapter identity')
    shots = [s for c in chapters for s in c['shots']]
    if len({s['shotID'] for s in shots}) != len(shots):
        raise ValueError('Duplicate shot identity')
    cursor = 0
    previous_duration = 0
    for chapter_index, chapter in enumerate(chapters):
        if chapter['sequenceIndex'] != chapter_index:
            raise ValueError('Non-contiguous chapter order')
        for index, shot in enumerate(chapter['shots']):
            if shot['sequenceIndex'] != index:
                raise ValueError('Non-contiguous shot order')
            overlap = shot['transitionIn']['durationFrames']
            if shot['transitionIn']['type'] == 'cut' and overlap != 0:
                raise ValueError('Cut has an overlap')
            if overlap > min(previous_duration, shot['durationFrames']) or shot['startFrame'] != cursor - overlap:
                raise ValueError('Inconsistent timeline or transition')
            cursor = shot['startFrame'] + shot['durationFrames']
            previous_duration = shot['durationFrames']
            kind = shot['kind']
            if kind in ('photo', 'video'):
                asset = assets.get(shot.get('assetID'))
                if asset is None:
                    raise ValueError('Unknown shot asset')
                if kind == 'photo' and asset['mediaType'] not in ('image/jpeg', 'image/png'):
                    raise ValueError('Photo references non-image asset')
                if kind == 'video':
                    if asset['mediaType'] not in ('video/mp4', 'video/quicktime'):
                        raise ValueError('Video references non-video asset')
                    clip = shot['videoClip']
                    start, end = clip['inFrame'], clip['outFrame']
                    if end <= start or end - start != shot['durationFrames']:
                        raise ValueError('Video range does not match shot duration')
                    if end * 1000 > asset['video']['durationMs'] * document['export']['fps']:
                        raise ValueError('Video range exceeds source duration')
            elif 'assetID' in shot:
                raise ValueError('Title references a media asset')
    if cursor != document['export']['totalFrames']:
        raise ValueError('Total duration does not match timeline')
    if 'audio' in document:
        asset = assets.get(document['audio']['assetID'])
        if asset is None or not asset['mediaType'].startswith('audio/'):
            raise ValueError('Music references non-audio asset')
    return document
