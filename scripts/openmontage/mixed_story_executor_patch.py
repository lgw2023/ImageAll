"""Extend the task envelope and executor in a writable engine; no App activation."""
import hashlib
import json
from pathlib import Path
from mixed_story_engine_patch import apply as patch_engine, replace_once


def schema_identities(engine):
    directory = engine/'schemas/integrations'
    return {json.loads(path.read_text())['properties']['schemaVersion']['const']: (path, hashlib.sha256(path.read_bytes()).hexdigest())
            for path in (directory/'story_render_package_v0_1.schema.json', directory/'story_render_package_v0_2.schema.json')}


def apply(engine):
    engine = Path(engine).resolve()
    patch_engine(engine)  # Includes the read-only seed boundary.
    identities = schema_identities(engine)
    directory = engine/'schemas/integrations'
    path = directory/'story_executor_task_protocol_v1.schema.json'
    schema = json.loads(path.read_text())
    for name in ('task', 'completion'):
        package = schema['$defs'][name]['properties']['storyPackage']
        package['properties']['schemaVersion'] = {'enum': list(identities)}
        package['properties']['schemaSHA256'] = {'$ref': '#/$defs/sha256'}
        package['oneOf'] = [{'properties': {'schemaVersion': {'const': version}, 'schemaSHA256': {'const': digest}}}
                            for version, (_, digest) in identities.items()]
    advertised = schema['$defs']['capabilities']['properties']['storyPackageSchemas']['items']
    advertised['properties']['version'] = {'enum': list(identities)}
    advertised['oneOf'] = [{'properties': {'version': {'const': version}, 'sha256': {'const': digest}}}
                           for version, (_, digest) in identities.items()]
    schema_bytes = (json.dumps(schema, indent=2)+'\n').encode()
    protocol_hash = hashlib.sha256(schema_bytes).hexdigest()
    target = engine/'lib/story_task_executor.py'
    source = target.read_text()
    if 'def _supported_story_schemas()' not in source:
        source = replace_once(source, '''    actual_schema_hash = _sha256(STORY_SCHEMA_PATH)
    if task["storyPackage"]["schemaVersion"] != "0.1":
        raise ProtocolError("STORY_SCHEMA_UNSUPPORTED", "only StoryRenderPackage 0.1 is supported")''', '''    version = task["storyPackage"]["schemaVersion"]
    schemas = _supported_story_schemas()
    if version not in schemas:
        raise ProtocolError("STORY_SCHEMA_UNSUPPORTED", "unsupported story schema version")
    actual_schema_hash = _sha256(schemas[version])''')
        source = replace_once(source, '''    if story.get("schemaVersion") != "0.1":
        raise ProtocolError("STORY_SCHEMA_UNSUPPORTED", "story package schemaVersion is not 0.1")''', '''    if story.get("schemaVersion") != version:
        raise ProtocolError("STORY_SCHEMA_UNSUPPORTED", "story and envelope schema versions disagree")''')
        source = replace_once(source, '"storyPackageSchemas": [{"version": "0.1", "sha256": _sha256(STORY_SCHEMA_PATH)}],',
                              '"storyPackageSchemas": [{"version": version, "sha256": _sha256(path)} for version, path in _supported_story_schemas().items()],')
        source = replace_once(source, '    for command in ("ffmpeg", "ffprobe", "node"):', '''    for version, path in _supported_story_schemas().items():
        lock_path = path.with_name(path.name.replace(".schema.json", ".lock.json"))
        lock = _read_json(lock_path)
        add("story_package_schema_" + version, _sha256(path) == lock["sha256"], str(path.name))
    for command in ("ffmpeg", "ffprobe", "node"):''')
        source += '''

def _supported_story_schemas():
    paths = [STORY_SCHEMA_PATH, REPOSITORY_ROOT / "schemas/integrations/story_render_package_v0_2.schema.json"]
    return {_read_json(path)["properties"]["schemaVersion"]["const"]: path for path in paths}
'''
        compile(source, str(target), 'exec')
    # Only publish the new schema after all source anchors and syntax pass.
    target.write_text(source)
    path.write_bytes(schema_bytes)
    lock_path = directory/'story_executor_task_protocol_v1.lock.json'
    lock = json.loads(lock_path.read_text())
    lock.update(sha256=protocol_hash, byteLength=len(schema_bytes), lineCount=schema_bytes.count(b'\n'))
    lock_path.write_text(json.dumps(lock, indent=2)+'\n')
    for version, (story_path, digest) in identities.items():
        if story_path.name.endswith('v0_2.schema.json'):
            data = story_path.read_bytes()
            story_path.with_name(story_path.name.replace('.schema.json', '.lock.json')).write_text(json.dumps({
                'schemaVersion': version, 'sha256': digest, 'byteLength': len(data), 'lineCount': data.count(b'\n')}, indent=2)+'\n')
    return {'taskProtocolSHA256': protocol_hash, 'storyPackageSchemas': {v: digest for v, (_, digest) in identities.items()}}


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('engine')
    print(json.dumps(apply(parser.parse_args().engine), indent=2))
