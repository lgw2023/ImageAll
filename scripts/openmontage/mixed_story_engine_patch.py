"""Install mixed story support into an independently writable engine."""
import json
from pathlib import Path
import shutil
from mixed_story_renderer_patch import apply as patch_renderer

RUNTIME_HELPERS = '''

def _story_schema_path(data=None):
    if data and data.get("schemaVersion") == "0.2":
        return REPOSITORY_ROOT / "schemas/integrations/story_render_package_v0_2.schema.json"
    return STORY_PACKAGE_SCHEMA


def _story_has_original_audio(story):
    return any(s.get("kind") == "video" and s.get("sourceHasAudio") and
               s["videoClip"]["originalAudioGain"] > 0 for s in story["shots"])


def _story_has_audio(story):
    return bool(story.get("audio")) or _story_has_original_audio(story)


def _validate_mixed_package(package_file, data, verify_assets):
    from lib.mixed_story_contract import validate_document
    from lib.mixed_story_assets import validate_assets
    try:
        validate_document(data)
        if verify_assets:
            validate_assets(data, package_file.parent)
        paths = {a["assetID"]: _safe_asset_path(package_file.parent, a["relativePath"]) for a in data["assets"]}
        return ValidatedStoryPackage(package_file, package_file.parent, data, paths)
    except (ValueError, OSError, jsonschema.ValidationError) as error:
        raise StoryPackageValidationError([ValidationIssue("MIXED_PACKAGE_INVALID", str(error))]) from error


def _copy_mixed_asset(validated, asset, destination):
    from lib.mixed_story_assets import open_asset, identity
    from lib.mixed_story_adapter import copy_frozen
    root_fd = os.open(validated.package_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with open_asset(root_fd, asset["relativePath"]) as fd:
            before = copy_frozen(fd, destination, asset["renderFileSHA256"])
            with open_asset(root_fd, asset["relativePath"]) as current:
                if identity(current) != before:
                    raise ValueError("Source path changed during freezing")
    finally:
        os.close(root_fd)
'''


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f'Mixed adapter anchor drift: {old[:100]}')
    return source.replace(old, new)


def apply(engine):
    engine = Path(engine).resolve()
    own = Path(__file__).resolve().parent
    seed = own.parents[1] / 'Vendor/OpenMontage/Runtime'
    if engine == seed or seed in engine.parents:
        raise ValueError('Runtime seed is read-only')
    target = engine/'lib/story_render_adapter.py'
    source = target.read_text()
    if 'def _validate_mixed_package(' in source:
        required = [engine/'lib'/name for name in ('mixed_story_contract.py', 'mixed_story_assets.py', 'mixed_story_adapter.py')]
        required.append(engine/'schemas/integrations/story_render_package_v0_2.schema.json')
        if not all(path.is_file() for path in required) or 'const VideoPlate:' not in (engine/'remotion-composer/src/PhotoStory.tsx').read_text():
            raise ValueError('Incomplete mixed-story patch; restore the writable copy before retrying')
        return
    source = replace_once(source, '    issues.extend(_schema_issues(data))',
                          '    if data.get("schemaVersion") == "0.2":\n        return _validate_mixed_package(package_file, data, verify_assets)\n\n    issues.extend(_schema_issues(data))')
    source = replace_once(source, '                "type": "image" if media_type.startswith("image/") else "music",',
                          '                "type": "image" if media_type.startswith("image/") else "video" if media_type.startswith("video/") else "music",\n                **({"video": asset["video"]} if "video" in asset else {}),')
    source = replace_once(source, '    environment = _runtime_environment_report()',
                          '    environment = _runtime_environment_report()\n    environment["schemaSHA256"] = _sha256(_story_schema_path(data))')
    source = replace_once(source, '        normalised_shots.append(normalised)', '''        if shot["kind"] == "video":
            asset = next(a for a in data["assets"] if a["assetID"] == source)
            normalised.update(assetID=source, src=_artifact_path(copied_assets[source]),
                              fit=_normalise_photo_presentation({"fit": shot["fit"], "motion": {"type": "static"}})[0],
                              videoClip=shot["videoClip"], sourceHasAudio=asset["video"]["hasAudio"])
        normalised_shots.append(normalised)''')
    source = replace_once(source, '        "schemaVersion": "0.1",', '        "schemaVersion": data["schemaVersion"],')
    source = replace_once(source, '        shots.append(projected)', '''        if shot["kind"] == "video":
            asset = next(a for a in data["assets"] if a["assetID"] == shot["assetID"])
            projected.update(assetID=shot["assetID"], fit=shot["fit"], videoClip=shot["videoClip"],
                             sourceHasAudio=asset["video"]["hasAudio"])
        shots.append(projected)''')
    source = replace_once(source, '                "renderFileSHA256": asset["renderFileSHA256"],',
                          '                "renderFileSHA256": asset["renderFileSHA256"],\n                **({"video": asset["video"]} if "video" in asset else {}),')
    source = replace_once(source, '                "renderFileSHA256": asset.get("sha256"),',
                          '                "renderFileSHA256": asset.get("sha256"),\n                **({"video": asset["video"]} if "video" in asset else {}),')
    source = replace_once(source, '            "storyRenderSchemaSHA256": _sha256(STORY_PACKAGE_SCHEMA),',
                          '            "storyRenderSchemaSHA256": _sha256(_story_schema_path(data)),')
    source = replace_once(source, '    schema_hash = _sha256(STORY_PACKAGE_SCHEMA)',
                          '    schema_hash = _sha256(_story_schema_path(validated.data))')
    source = replace_once(source, '        shutil.copy2(source, destination)', '''        if data["schemaVersion"] == "0.2":
            _copy_mixed_asset(validated, asset, destination)
        else:
            shutil.copy2(source, destination)''')
    source = source.replace('bool(audio) == bool(story.get("audio"))', 'bool(audio) == _story_has_audio(story)')
    source = source.replace('"expected": bool(story.get("audio"))', '"expected": _story_has_audio(story)')
    source = source.replace('if audio and story.get("audio"):', 'if audio and story.get("audio") and not _story_has_original_audio(story):')
    source = source.replace('"mute_audio": not bool(story.get("audio"))', '"mute_audio": not _story_has_audio(story)')
    source = replace_once(source, '    if audio and story.get("audio") and not _story_has_original_audio(story):', '''    if audio and _story_has_original_audio(story):
        audio_duration = float(audio.get("duration") or probe.get("format", {}).get("duration") or 0)
        checks.append({"name": "original_audio_duration", "passed": abs(audio_duration - expected_duration) <= max(0.1, 2 / expected_fps),
                       "expected": expected_duration, "actual": audio_duration})
    if audio and story.get("audio") and not _story_has_original_audio(story):''')
    source += RUNTIME_HELPERS
    # Compile before changing the destination, so anchor or syntax failures are atomic.
    compile(source, str(target), 'exec')
    target.write_text(source)
    for name in ('mixed_story_contract.py', 'mixed_story_assets.py', 'mixed_story_adapter.py'):
        module = (own/name).read_text().replace('from mixed_story_', 'from lib.mixed_story_')
        if name == 'mixed_story_contract.py':
            module = module.replace("Path(__file__).parent / 'schemas/story_render_package_v0_2.schema.json'",
                                    "Path(__file__).resolve().parents[1] / 'schemas/integrations/story_render_package_v0_2.schema.json'")
        (engine/'lib'/name).write_text(module)
    schema = json.loads((own/'schemas/story_render_package_v0_2.schema.json').read_text())
    shutil.copyfile(own/'schemas/story_render_package_v0_2.schema.json', engine/'schemas/integrations/story_render_package_v0_2.schema.json')
    artifact_path = engine/'schemas/artifacts/edit_decisions.schema.json'
    artifact = json.loads(artifact_path.read_text())
    story = artifact['properties']['story_render']
    story['properties']['schemaVersion'] = {'enum': ['0.1', '0.2']}
    shot = story['properties']['shots']['items']
    shot['properties']['kind']['enum'] = list(dict.fromkeys([*shot['properties']['kind']['enum'], 'video']))
    shot['properties']['videoClip'] = schema['properties']['chapters']['items']['properties']['shots']['items']['properties']['videoClip']
    shot['properties']['sourceHasAudio'] = {'type': 'boolean'}
    shot['allOf'] = [{'if': {'properties': {'kind': {'const': 'video'}}},
                      'then': {'required': ['assetID', 'src', 'fit', 'videoClip', 'sourceHasAudio'], 'not': {'required': ['motion']}},
                      'else': {'not': {'anyOf': [{'required': ['videoClip']}, {'required': ['sourceHasAudio']}]}}}]
    artifact_path.write_text(json.dumps(artifact, indent=2)+'\n')
    manifest_path = engine/'schemas/artifacts/asset_manifest.schema.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['properties']['assets']['items']['properties']['video'] = schema['properties']['assets']['items']['properties']['video']
    manifest_path.write_text(json.dumps(manifest, indent=2)+'\n')
    patch_renderer(engine/'remotion-composer')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('engine')
    apply(parser.parse_args().engine)
